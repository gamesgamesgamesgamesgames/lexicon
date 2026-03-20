function handle()
  local PENTARACT_DID = env.PENTARACT_DID

  local claim_uri = input.claim
  local review_uri = input.claimReview

  if not claim_uri or claim_uri == "" then
    error("claim URI is required")
  end
  if not review_uri or review_uri == "" then
    error("claimReview URI is required")
  end

  -- Verify claim belongs to caller
  local claim_did = claim_uri:match("^at://([^/]+)/")
  if claim_did ~= caller_did then
    error("unauthorized: claim does not belong to caller")
  end

  -- Load the claim
  local claim_record = db.get(claim_uri)
  if not claim_record then
    error("claim not found")
  end

  -- Load the review and verify
  local review_record = db.get(review_uri)
  if not review_record then
    error("claimReview not found")
  end

  if review_record.status ~= "approved" then
    error("claim review is not approved")
  end

  if not review_record.claim or review_record.claim.uri ~= claim_uri then
    error("claimReview does not match the provided claim")
  end

  -- Reference collections that may contain URIs to update
  local REF_COLLECTIONS = {
    "games.gamesgamesgamesgames.org.credit",
    "games.gamesgamesgamesgames.actor.credit",
    "games.gamesgamesgamesgames.collection",
    "games.gamesgamesgamesgames.engine",
    "games.gamesgamesgamesgames.game",
  }

  -- Helper: check if a redirect already exists for a source URI
  function resolve_redirect(source_uri)
    local rows = db.raw(
      "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.redirect' AND json_extract(record, '$.sourceUri') = $1 LIMIT 1",
      { source_uri }
    )
    if rows and #rows > 0 then
      local rec = json.decode(rows[1].record)
      return rec.targetUri
    end
    return nil
  end

  -- Helper: escape a string for use in Lua gsub patterns
  function escape_pattern(str)
    return str:gsub("([%.%^%$%(%)%%%[%]%*%+%-%?])", "%%%1")
  end

  -- Core migration function
  function migrate_record(source_uri, collection)
    -- Skip if redirect already exists
    local existing_target = resolve_redirect(source_uri)
    if existing_target then
      return { status = "skipped", sourceUri = source_uri, newUri = existing_target }
    end

    -- Read original record
    local original = db.get(source_uri)
    if not original then
      return { status = "failed", sourceUri = source_uri, error = "source record not found" }
    end

    -- Build new record data (strip metadata fields)
    local new_data = {}
    for k, v in pairs(original) do
      if k ~= "uri" and k ~= "cid" and k ~= "$type" then
        new_data[k] = v
      end
    end

    -- Create in caller's repo
    local ok, new_record_or_err = pcall(function()
      local rec = Record.new(collection, new_data)
      rec:save()
      return rec
    end)

    if not ok then
      return { status = "failed", sourceUri = source_uri, error = "failed to create new record: " .. tostring(new_record_or_err) }
    end

    local new_record = new_record_or_err
    local new_uri = new_record._uri

    -- Verify the new record was saved
    local verify = db.get(new_uri)
    if not verify then
      return { status = "failed", sourceUri = source_uri, error = "verification failed: new record not found after save" }
    end

    -- Update pentaract-owned references that point to source_uri
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
            -- Only update pentaract-owned records
            local ref_did = ref_record.uri:match("^at://([^/]+)/")
            if ref_did == PENTARACT_DID then
              local update_ok, update_err = pcall(function()
                local loaded = Record.load(ref_record.uri)
                if loaded then
                  loaded:set_repo(PENTARACT_DID)
                  -- Serialize to JSON, replace URI, deserialize back
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
              if not update_ok then
                -- Log but don't fail the whole migration
              end
            end
          end
          bl_cursor = backlinks.cursor
        else
          bl_cursor = nil
        end
      until not bl_cursor
    end

    -- Create redirect in pentaract's repo
    local redirect_ok, redirect_err = pcall(function()
      local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
        sourceUri = source_uri,
        targetUri = new_uri,
        collection = collection,
        createdAt = now(),
      })
      redirect:set_repo(PENTARACT_DID)
      redirect:save()
    end)

    if not redirect_ok then
      return { status = "failed", sourceUri = source_uri, newUri = new_uri, error = "failed to create redirect: " .. tostring(redirect_err) }
    end

    -- Delete original from pentaract's repo
    local delete_ok, delete_err = pcall(function()
      local to_delete = Record.load(source_uri)
      if to_delete then
        to_delete:set_repo(PENTARACT_DID)
        to_delete:delete()
      end
    end)

    if not delete_ok then
      -- Redirect exists so record is still reachable; don't fail
    end

    return { status = "success", sourceUri = source_uri, newUri = new_uri }
  end

  local results = {}

  if claim_record.type == "game" then
    -- Migrate each approved game
    local approved_games = review_record.approvedGames or {}
    for _, game_uri in ipairs(approved_games) do
      local result = migrate_record(game_uri, "games.gamesgamesgamesgames.game")
      table.insert(results, {
        gameUri = game_uri,
        status = result.status,
        newUri = result.newUri,
        error = result.error,
      })
    end

  elseif claim_record.type == "org" then
    local org_uri = claim_record.org
    if not org_uri then
      error("org claim has no org URI")
    end

    -- Migrate org.profile if claimant doesn't already have one
    local claimant_profile_uri = "at://" .. caller_did .. "/games.gamesgamesgamesgames.org.profile/self"
    local existing_profile = db.get(claimant_profile_uri)

    if not existing_profile then
      -- Find the org's profile in pentaract's repo
      local org_did = org_uri:match("^at://([^/]+)/")
      if org_did then
        local source_profile_uri = "at://" .. org_did .. "/games.gamesgamesgamesgames.org.profile/self"
        local source_profile = db.get(source_profile_uri)
        if source_profile then
          local profile_ok, profile_err = pcall(function()
            local profile_data = {}
            for k, v in pairs(source_profile) do
              if k ~= "uri" and k ~= "cid" and k ~= "$type" then
                profile_data[k] = v
              end
            end
            local new_profile = Record.new("games.gamesgamesgamesgames.org.profile", profile_data)
            new_profile:set_key_type("literal:self")
            new_profile:set_rkey("self")
            new_profile:save()

            -- Create redirect for org profile
            local redirect = Record.new("games.gamesgamesgamesgames.redirect", {
              sourceUri = source_profile_uri,
              targetUri = claimant_profile_uri,
              collection = "games.gamesgamesgamesgames.org.profile",
              createdAt = now()
            })
            redirect:set_repo(PENTARACT_DID)
            redirect:save()

            -- Delete original org profile from pentaract
            local orig_profile = Record.load(source_profile_uri)
            if orig_profile then
              orig_profile:set_repo(PENTARACT_DID)
              orig_profile:delete()
            end
          end)
          -- Profile migration is best-effort
        end
      end
    end

    -- Migrate org.credit records for approved games
    local approved_games = review_record.approvedGames or {}
    for _, game_uri in ipairs(approved_games) do
      -- Migrate the game record itself
      local game_result = migrate_record(game_uri, "games.gamesgamesgamesgames.game")
      table.insert(results, {
        gameUri = game_uri,
        status = game_result.status,
        newUri = game_result.newUri,
        error = game_result.error,
      })

      -- Find and migrate org.credit records for this game that belong to pentaract
      local new_game_uri = game_result.newUri or game_uri
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
              -- Check if the credit references the org being claimed
              local credit_org_uri = credit.org and credit.org.uri or nil
              if credit_org_uri == org_uri then
                local credit_result = migrate_record(credit.uri, "games.gamesgamesgamesgames.org.credit")
                -- credit migration is secondary, don't add to results
              end
            end
          end
          bl_cursor = backlinks.cursor
        else
          bl_cursor = nil
        end
      until not bl_cursor
    end
  end

  return { results = toarray(results) }
end
