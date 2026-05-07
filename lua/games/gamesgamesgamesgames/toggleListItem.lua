local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local list_uri = input.listUri
  local game_uri = input.gameUri

  -- Resolve game URI to IGDB ID and title via Meilisearch
  local body = {
    q = "",
    limit = 1,
    filter = "uri = \"" .. game_uri .. "\"",
    attributesToRetrieve = toarray({ "externalIds", "name" })
  }
  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  if resp.status ~= 200 then
    return { error = "InternalError", message = "Failed to look up game" }
  end

  local data = json.decode(resp.body)
  if not data.hits or #data.hits == 0 then
    return { error = "NotFound", message = "Game not found" }
  end

  local game = data.hits[1]
  local igdb_id = game.externalIds and game.externalIds.igdb
  if not igdb_id then
    return { error = "InvalidRequest", message = "Game has no IGDB ID" }
  end

  local game_title = game.name

  -- Check if the user already has a listItem for this game in this list
  local results = db.query({
    collection = "social.popfeed.feed.listItem",
    did = caller_did,
    limit = 1000
  })

  local existing = nil
  if results.records then
    for _, rec in ipairs(results.records) do
      if rec.listUri == list_uri
        and rec.identifiers
        and rec.identifiers.igdbId == igdb_id
        and rec.creativeWorkType == "video_game" then
        existing = rec
        break
      end
    end
  end

  if existing then
    local r = Record.load(existing.uri)
    if r then r:delete() end
    return { action = "removed" }
  else
    local item = Record.new("social.popfeed.feed.listItem", {
      listUri = list_uri,
      identifiers = { igdbId = igdb_id },
      creativeWorkType = "video_game",
      title = game_title,
      addedAt = now()
    })
    item:save()
    return { uri = item._uri, cid = item._cid, action = "added" }
  end
end
