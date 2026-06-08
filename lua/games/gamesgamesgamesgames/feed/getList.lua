function handle()
  local uri = params.uri
  if not uri or uri == "" then
    return { error = "InvalidRequest", message = "uri is required" }
  end

  -- Fetch the list record by URI
  local list_record = db.get(uri)
  if not list_record then
    return { error = "NotFound", message = "List not found" }
  end

  -- Extract creator DID from the AT-URI
  local creator_did = uri:match("^at://([^/]+)/")
  if not creator_did then
    return { error = "InvalidRequest", message = "Could not parse DID from URI" }
  end

  -- Count items in this list
  local count_rows = db.raw(
    "SELECT COUNT(*)::int AS count FROM records WHERE collection = $1 AND did = $2 AND record::jsonb->>'listUri' = $3",
    {"games.gamesgamesgamesgames.feed.listItem", creator_did, uri}
  )
  local item_count = 0
  if count_rows and #count_rows > 0 then
    item_count = count_rows[1].count or 0
  end

  -- Resolve creator profile
  local creator = { did = creator_did, handle = creator_did }

  local actor_results = db.query({
    collection = "games.gamesgamesgamesgames.actor.profile",
    did = creator_did,
    limit = 1
  })

  if actor_results.records and #actor_results.records > 0 then
    local profile = actor_results.records[1]
    creator.displayName = profile.displayName
    creator.avatar = profile.avatar
  end

  -- Resolve handle from DID doc
  local did_doc_url
  if string.find(creator_did, "^did:web:") then
    local domain = creator_did:sub(9)
    did_doc_url = "https://" .. domain .. "/.well-known/did.json"
  else
    did_doc_url = "https://plc.directory/" .. creator_did
  end

  local resp = http.get(did_doc_url)
  if resp and resp.body and resp.body ~= "" then
    local doc = json.decode(resp.body)
    if doc and doc.alsoKnownAs then
      for _, aka in ipairs(doc.alsoKnownAs) do
        local h = aka:match("^at://(.+)")
        if h then
          creator.handle = h
          break
        end
      end
    end
  end

  return {
    list = {
      uri = uri,
      name = list_record.name,
      description = list_record.description,
      itemCount = item_count,
      createdAt = list_record.createdAt,
      creator = creator
    }
  }
end
