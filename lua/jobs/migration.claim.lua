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

local REF_COLLECTIONS = {
  "games.gamesgamesgamesgames.org.credit",
  "games.gamesgamesgamesgames.actor.credit",
  "games.gamesgamesgamesgames.collection",
  "games.gamesgamesgamesgames.engine",
  "games.gamesgamesgamesgames.game",
}

function migrate_record(source_uri, collection, PENTARACT_DID)
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
            pcall(function()
              local loaded = Record.load(ref_record.uri)
              if loaded then
                loaded:set_repo(PENTARACT_DID)
                local encoded = json.encode(loaded)
                local updated = encoded:gsub(escaped_source, new_uri)
                if updated ~= encoded then
                  local updated_data = json.decode(updated)
                  for k, v in pairs(updated_data) do
                    loaded[k] = v
                  end
                  loaded:save()
                end
              end
            end)
          end
        end
        bl_cursor = backlinks.cursor
      else
        bl_cursor = nil
      end
    until not bl_cursor
  end

  pcall(function()
    local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
      sourceUri = source_uri,
      targetUri = new_uri,
      collection = collection,
      createdAt = now(),
    })
    redirect:set_repo(PENTARACT_DID)
    redirect:save()
  end)

  pcall(function()
    local to_delete = Record.load(source_uri)
    if to_delete then
      to_delete:set_repo(PENTARACT_DID)
      to_delete:delete()
    end
  end)

  return { status = "success", sourceUri = source_uri, newUri = new_uri }
end

function handle()
  local PENTARACT_DID = env.PENTARACT_DID
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

  if claim_type == "org" and org_uri and not progress.org_profile_done then
    local claimant_profile_uri = "at://" .. caller_did .. "/games.gamesgamesgamesgames.org.profile/self"
    local existing_profile = db.get(claimant_profile_uri)

    if not existing_profile and org_did then
      local source_profile_uri = "at://" .. org_did .. "/games.gamesgamesgamesgames.org.profile/self"
      local source_profile = db.get(source_profile_uri)
      if source_profile then
        pcall(function()
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

          local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
            sourceUri = source_profile_uri,
            targetUri = claimant_profile_uri,
            collection = "games.gamesgamesgamesgames.org.profile",
            createdAt = now(),
          })
          redirect:set_repo(PENTARACT_DID)
          redirect:save()

          local orig_profile = Record.load(source_profile_uri)
          if orig_profile then
            orig_profile:set_repo(PENTARACT_DID)
            orig_profile:delete()
          end
        end)
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

    local game_result = migrate_record(game_uri, "games.gamesgamesgamesgames.game", PENTARACT_DID)
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
                migrate_record(credit.uri, "games.gamesgamesgamesgames.org.credit", PENTARACT_DID)
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
