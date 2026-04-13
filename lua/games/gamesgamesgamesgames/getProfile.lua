function handle()
  local handle_param = params.handle
  local did
  local resolved_handle

  if handle_param and handle_param ~= "" then
    -- Handle parameter provided: resolve to DID
    resolved_handle = handle_param
    if string.find(handle_param, "^did:") then
      did = handle_param
      -- Resolve handle from DID doc
      local did_doc_url
      if string.find(did, "^did:web:") then
        local domain = did:sub(9)
        did_doc_url = "https://" .. domain .. "/.well-known/did.json"
      else
        did_doc_url = "https://plc.directory/" .. did
      end
      local resp = http.get(did_doc_url)
      if resp and resp.body and resp.body ~= "" then
        local doc = json.decode(resp.body)
        if doc and doc.alsoKnownAs then
          for _, aka in ipairs(doc.alsoKnownAs) do
            local h = aka:match("^at://(.+)")
            if h then
              resolved_handle = h
              break
            end
          end
        end
      end
    else
      -- Resolve handle to DID via com.atproto.identity.resolveHandle (supports both DNS and HTTP resolution)
      local resp = xrpc.query("com.atproto.identity.resolveHandle", { handle = handle_param })
      if not resp or resp.status ~= 200 or not resp.body or resp.body == "" then
        return { profile = nil, profileType = nil, handle = handle_param }
      end
      local resolve_result = json.decode(resp.body)
      if not resolve_result or not resolve_result.did then
        return { profile = nil, profileType = nil, handle = handle_param }
      end
      did = resolve_result.did
    end
  elseif caller_did and caller_did ~= "" then
    -- Authenticated flow: use caller_did
    did = caller_did
    resolved_handle = nil
  else
    return { profile = nil, profileType = nil }
  end

  local actor_results = db.query({
    collection = "games.gamesgamesgamesgames.actor.profile",
    did = did,
    limit = 1
  })

  if actor_results.records and #actor_results.records > 0 then
    local record = actor_results.records[1]
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#actorProfileDetailView",
      uri = record.uri,
      did = did,
      displayName = record.displayName,
      description = record.description,
      descriptionFacets = record.descriptionFacets,
      pronouns = record.pronouns,
      websites = record.websites,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile, profileType = "actor", handle = resolved_handle }
  end

  local org_results = db.query({
    collection = "games.gamesgamesgamesgames.org.profile",
    did = did,
    limit = 1
  })

  if org_results.records and #org_results.records > 0 then
    local record = org_results.records[1]
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#orgProfileDetailView",
      uri = record.uri,
      did = did,
      displayName = record.displayName,
      description = record.description,
      descriptionFacets = record.descriptionFacets,
      country = record.country,
      status = record.status,
      parent = record.parent,
      foundedAt = record.foundedAt,
      websites = record.websites,
      media = record.media,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile, profileType = "org", handle = resolved_handle }
  end

  return { profile = nil, profileType = nil, handle = resolved_handle }
end
