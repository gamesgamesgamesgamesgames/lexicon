function create_pentaract_session(PENTARACT_DID)
  local pds_endpoint = atproto.resolve_service_endpoint(PENTARACT_DID)
  if not pds_endpoint then
    error("failed to resolve PDS for PENTARACT_DID: " .. PENTARACT_DID)
  end

  local handle = env.PENTARACT_HANDLE
  local app_password = env.PENTARACT_APP_PASSWORD
  if not handle or not app_password then
    error("PENTARACT_HANDLE and PENTARACT_APP_PASSWORD env vars are required for migration")
  end

  local body = json.encode({ identifier = handle, password = app_password })
  local resp = http.post(pds_endpoint .. "/xrpc/com.atproto.server.createSession", {
    body = body,
    headers = { ["content-type"] = "application/json" },
  })

  if resp.status ~= 200 then
    error("failed to create session for PENTARACT_DID: " .. resp.body)
  end

  local session = json.decode(resp.body)
  return {
    endpoint = pds_endpoint,
    access_jwt = session.accessJwt,
    did = session.did,
  }
end

function pds_create_record(session, collection, rkey, record)
  local body = {
    repo = session.did,
    collection = collection,
    record = record,
  }
  if rkey then
    body.rkey = rkey
  end
  local resp = http.post(session.endpoint .. "/xrpc/com.atproto.repo.createRecord", {
    body = json.encode(body),
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. session.access_jwt,
    },
  })

  if resp.status ~= 200 then
    error("PDS createRecord failed (" .. resp.status .. "): " .. resp.body)
  end

  return json.decode(resp.body)
end

function pds_put_record(session, collection, rkey, record)
  local body = {
    repo = session.did,
    collection = collection,
    rkey = rkey,
    record = record,
  }
  local resp = http.post(session.endpoint .. "/xrpc/com.atproto.repo.putRecord", {
    body = json.encode(body),
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. session.access_jwt,
    },
  })

  if resp.status ~= 200 then
    error("PDS putRecord failed (" .. resp.status .. "): " .. resp.body)
  end

  return json.decode(resp.body)
end

function pds_delete_record(session, collection, rkey)
  local body = {
    repo = session.did,
    collection = collection,
    rkey = rkey,
  }
  local resp = http.post(session.endpoint .. "/xrpc/com.atproto.repo.deleteRecord", {
    body = json.encode(body),
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. session.access_jwt,
    },
  })

  if resp.status ~= 200 then
    error("PDS deleteRecord failed (" .. resp.status .. "): " .. resp.body)
  end
end

function migrate_blobs(data, source_did)
  if type(data) ~= "table" then
    return 0
  end

  local count = 0

  if data["$type"] == "blob" and data.ref and data.ref["$link"] then
    local old_cid = data.ref["$link"]
    local downloaded = atproto.blob_download(source_did, old_cid)

    local uploaded
    local retries = 0
    while retries < 10 do
      local ok, result = pcall(function()
        return atproto.blob_upload(downloaded.handle, downloaded.mimeType)
      end)
      if ok then
        uploaded = result
        break
      end

      local err_str = tostring(result)
      if err_str:find("429") or err_str:find("rate") or err_str:find("RateLimit") then
        retries = retries + 1
        local wait_time = math.min(30 * retries, 300)
        log("rate limited on blob upload, waiting " .. wait_time .. "s (attempt " .. retries .. "/10)")
        job.wait(wait_time)

        if job.should_stop() then
          error("job stopped during rate limit backoff")
        end
      else
        error("blob upload failed: " .. err_str)
      end
    end

    if not uploaded then
      error("blob upload failed after 10 retries for cid=" .. old_cid)
    end

    if uploaded and uploaded.blob then
      local new_blob = uploaded.blob
      if new_blob.ref and new_blob.ref["$link"] then
        data.ref["$link"] = new_blob.ref["$link"]
      end
      if new_blob.mimeType then
        data.mimeType = new_blob.mimeType
      end
      if new_blob.size then
        data.size = new_blob.size
      end
    end

    return 1
  end

  for k, v in pairs(data) do
    if type(v) == "table" then
      count = count + migrate_blobs(v, source_did)
    end
  end

  return count
end

function escape_pattern(str)
  return str:gsub("([%.%^%$%(%)%%%[%]%*%+%-%?])", "%%%1")
end

function rkey_from_uri(uri)
  return uri:match("[^/]+$")
end

function collection_from_uri(uri)
  return uri:match("^at://[^/]+/([^/]+)/")
end

local REF_COLLECTIONS = {
  "games.gamesgamesgamesgames.org.credit",
  "games.gamesgamesgamesgames.actor.credit",
  "games.gamesgamesgamesgames.collection",
  "games.gamesgamesgamesgames.engine",
  "games.gamesgamesgamesgames.game",
}

function migrate_record(source_uri, collection, PENTARACT_DID, pentaract_session)
  local existing = db.raw(
    "SELECT uri, record FROM happyview_records WHERE collection = 'games.gamesgamesgamesgames.redirect' AND record::jsonb->>'sourceUri' = $1 LIMIT 1",
    { source_uri }
  )
  if existing and #existing > 0 then
    local rec = json.decode(existing[1].record)
    return { status = "skipped", sourceUri = source_uri, newUri = rec.targetUri }
  end

  local original = db.get(source_uri)
  if not original then
    return { status = "failed", sourceUri = source_uri, error = "source record not found" }
  end

  local new_data = {}
  for k, v in pairs(original) do
    if k ~= "uri" and k ~= "cid" and k ~= "$type" then
      new_data[k] = v
    end
  end

  local source_did = source_uri:match("^at://([^/]+)/")
  if source_did and source_did ~= caller_did then
    local migrated = migrate_blobs(new_data, source_did)
    if migrated > 0 then
      log("migrated " .. migrated .. " blob(s) from " .. source_did .. " for " .. source_uri)
    end
  end

  local ok, new_record_or_err = pcall(function()
    local rec = Record.new(collection, new_data)
    rec:save()
    return rec
  end)

  if not ok then
    return { status = "failed", sourceUri = source_uri, error = "failed to create: " .. tostring(new_record_or_err) }
  end

  local new_record = new_record_or_err
  local new_uri = new_record._uri

  local verify = db.get(new_uri)
  if not verify then
    return { status = "failed", sourceUri = source_uri, error = "verification failed" }
  end

  local escaped_source = escape_pattern(source_uri)
  for _, ref_collection in ipairs(REF_COLLECTIONS) do
    local bl_cursor = nil
    repeat
      local bl_opts = {
        collection = ref_collection,
        uri = source_uri,
        limit = 100,
      }
      if bl_cursor then
        bl_opts.cursor = bl_cursor
      end
      local backlinks = db.backlinks(bl_opts)
      if backlinks and backlinks.records then
        for _, ref_record in ipairs(backlinks.records) do
          local ref_did = ref_record.uri:match("^at://([^/]+)/")
          if ref_did == PENTARACT_DID then
            local bl_ok, bl_err = pcall(function()
              local loaded = Record.load(ref_record.uri)
              if loaded then
                local encoded = json.encode(loaded)
                local updated = encoded:gsub(escaped_source, new_uri)
                if updated ~= encoded then
                  local updated_data = json.decode(updated)
                  for k, v in pairs(updated_data) do
                    loaded[k] = v
                  end
                  local ref_rkey = rkey_from_uri(ref_record.uri)
                  local ref_col = collection_from_uri(ref_record.uri)
                  local record_data = {}
                  for k, v in pairs(loaded) do
                    if type(k) == "string" and k:sub(1,1) ~= "_" then
                      record_data[k] = v
                    end
                  end
                  record_data["$type"] = ref_col
                  pds_put_record(pentaract_session, ref_col, ref_rkey, record_data)
                  loaded:set_repo(PENTARACT_DID)
                  loaded:save_local()
                end
              end
            end)
            if not bl_ok then
              log("warning: failed to update backlink " .. ref_record.uri .. ": " .. tostring(bl_err))
            end
          end
        end
        bl_cursor = backlinks.cursor
      else
        bl_cursor = nil
      end
    until not bl_cursor
  end

  local redir_ok, redir_err = pcall(function()
    local redirect_data = {
      ["$type"] = "games.gamesgamesgamesgames.redirect",
      sourceUri = source_uri,
      targetUri = new_uri,
      collection = collection,
      createdAt = now(),
    }
    local pds_result = pds_create_record(pentaract_session, "games.gamesgamesgamesgames.redirect", nil, redirect_data)

    local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
      sourceUri = source_uri,
      targetUri = new_uri,
      collection = collection,
      createdAt = redirect_data.createdAt,
    })
    redirect:set_repo(PENTARACT_DID)
    redirect._uri = pds_result.uri
    redirect._cid = pds_result.cid
    redirect:save_local()
  end)
  if not redir_ok then
    log("warning: failed to create redirect for " .. source_uri .. ": " .. tostring(redir_err))
  end

  local del_ok, del_err = pcall(function()
    local source_rkey = rkey_from_uri(source_uri)
    pds_delete_record(pentaract_session, collection, source_rkey)

    local to_delete = Record.load(source_uri)
    if to_delete then
      to_delete:delete_local()
    end
  end)
  if not del_ok then
    log("warning: failed to delete old record " .. source_uri .. ": " .. tostring(del_err))
  end

  return { status = "success", sourceUri = source_uri, newUri = new_uri }
end

function handle()
  local PENTARACT_DID = env.PENTARACT_DID
  local pentaract_session = create_pentaract_session(PENTARACT_DID)
  log("authenticated to PENTARACT PDS at " .. pentaract_session.endpoint)

  local claim_type = job.input.claim_type
  local approved_games = job.input.approved_games or {}
  local org_uri = job.input.org_uri
  local org_did = job.input.org_did

  local progress = job.input.progress or {}
  local completed_games = progress.completed_games or {}
  local completed_set = {}
  for _, uri in ipairs(completed_games) do
    completed_set[uri] = true
  end

  local results = {}
  local total = #approved_games
  local processed = #completed_games

  job.progress({
    total = total,
    processed = processed,
    completed_games = completed_games,
  })

  if claim_type == "org" and org_uri and not progress.org_profile_done then
    local claimant_profile_uri = "at://" .. caller_did .. "/games.gamesgamesgamesgames.org.profile/self"
    local existing_profile = db.get(claimant_profile_uri)

    if not existing_profile and org_did then
      local source_profile_uri = "at://" .. org_did .. "/games.gamesgamesgamesgames.org.profile/self"
      local source_profile = db.get(source_profile_uri)
      if source_profile then
        local prof_ok, prof_err = pcall(function()
          local profile_data = {}
          for k, v in pairs(source_profile) do
            if k ~= "uri" and k ~= "cid" and k ~= "$type" then
              profile_data[k] = v
            end
          end

          if org_did ~= caller_did then
            migrate_blobs(profile_data, org_did)
          end

          local new_profile = Record.new("games.gamesgamesgamesgames.org.profile", profile_data)
          new_profile:set_key_type("literal:self")
          new_profile:set_rkey("self")
          new_profile:save()

          local redirect_data = {
            ["$type"] = "games.gamesgamesgamesgames.redirect",
            sourceUri = source_profile_uri,
            targetUri = claimant_profile_uri,
            collection = "games.gamesgamesgamesgames.org.profile",
            createdAt = now(),
          }
          local pds_result = pds_create_record(pentaract_session, "games.gamesgamesgamesgames.redirect", nil, redirect_data)

          local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
            sourceUri = source_profile_uri,
            targetUri = claimant_profile_uri,
            collection = "games.gamesgamesgamesgames.org.profile",
            createdAt = redirect_data.createdAt,
          })
          redirect:set_repo(PENTARACT_DID)
          redirect._uri = pds_result.uri
          redirect._cid = pds_result.cid
          redirect:save_local()

          local source_rkey = "self"
          pds_delete_record(pentaract_session, "games.gamesgamesgamesgames.org.profile", source_rkey)

          local orig_profile = Record.load(source_profile_uri)
          if orig_profile then
            orig_profile:delete_local()
          end
        end)
        if not prof_ok then
          log("warning: failed to migrate org profile: " .. tostring(prof_err))
        end
      end
    end

    job.progress({
      org_profile_done = true,
      completed_games = completed_games,
      total = total,
      processed = processed,
    })
  end

  for i, game_uri in ipairs(approved_games) do
    if job.should_stop() then
      log("job stopped at game " .. i .. "/" .. total)
      job.progress({
        org_profile_done = true,
        completed_games = completed_games,
        total = total,
        processed = processed,
      })
      return { status = "stopped", results = toarray(results) }
    end

    if completed_set[game_uri] then
      goto continue
    end

    log("migrating game " .. i .. "/" .. total .. ": " .. game_uri)

    local game_result = migrate_record(game_uri, "games.gamesgamesgamesgames.game", PENTARACT_DID, pentaract_session)
    table.insert(results, {
      gameUri = game_uri,
      status = game_result.status,
      newUri = game_result.newUri,
      error = game_result.error,
    })

    if claim_type == "org" and org_uri and game_result.status == "success" then
      local bl_cursor = nil
      repeat
        local bl_opts = {
          collection = "games.gamesgamesgamesgames.org.credit",
          uri = game_uri,
          limit = 100,
        }
        if bl_cursor then
          bl_opts.cursor = bl_cursor
        end
        local backlinks = db.backlinks(bl_opts)
        if backlinks and backlinks.records then
          for _, credit in ipairs(backlinks.records) do
            local credit_did = credit.uri:match("^at://([^/]+)/")
            if credit_did == PENTARACT_DID then
              local credit_org_uri = credit.org and credit.org.uri or nil
              if credit_org_uri == org_uri then
                migrate_record(credit.uri, "games.gamesgamesgamesgames.org.credit", PENTARACT_DID, pentaract_session)
              end
            end
          end
          bl_cursor = backlinks.cursor
        else
          bl_cursor = nil
        end
      until not bl_cursor
    end

    table.insert(completed_games, game_uri)
    processed = processed + 1
    job.progress({
      org_profile_done = true,
      completed_games = completed_games,
      total = total,
      processed = processed,
    })

    ::continue::
  end

  return { status = "completed", results = toarray(results) }
end
