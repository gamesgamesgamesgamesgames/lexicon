local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local GAME_ATTRIBUTES = toarray({
  "uri", "name", "slug", "media", "applicationType", "genres", "themes", "releases", "firstReleaseDate"
})

function handle()
  local list_uri = params.listUri
  if not list_uri or list_uri == "" then
    return { error = "InvalidRequest", message = "listUri is required" }
  end

  local limit = tonumber(params.limit) or 30
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then
    offset = tonumber(params.cursor) or 0
  end

  -- Extract DID from list URI for scoping
  local list_did = list_uri:match("^at://([^/]+)/")
  if not list_did then
    return { error = "InvalidRequest", message = "Could not parse DID from listUri" }
  end

  -- Fetch listItem records for this list
  local rows = db.raw(
    "SELECT uri, record, indexed_at FROM records WHERE collection = $1 AND did = $2 AND record::jsonb->>'listUri' = $3 ORDER BY record::jsonb->>'addedAt' DESC LIMIT $4 OFFSET $5",
    {"games.gamesgamesgamesgames.feed.listItem", list_did, list_uri, limit + 1, offset}
  )

  local has_more = rows and #rows > limit
  if has_more then
    table.remove(rows, #rows)
  end

  if not rows or #rows == 0 then
    return { items = toarray({}) }
  end

  -- Collect game URIs for batch Meilisearch fetch
  local game_uris = {}
  local uri_set = {}
  for _, row in ipairs(rows) do
    local rec = json.decode(row.record)
    if rec.gameUri and not uri_set[rec.gameUri] then
      uri_set[rec.gameUri] = true
      game_uris[#game_uris + 1] = '"' .. rec.gameUri .. '"'
    end
  end

  -- Batch resolve games from Meilisearch
  local games_by_uri = {}
  if #game_uris > 0 then
    local body = {
      q = "",
      limit = #game_uris,
      filter = "uri IN [" .. table.concat(game_uris, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = GAME_ATTRIBUTES
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        games_by_uri[hit.uri] = hit
      end
    end
  end

  -- Build list item views
  local items = {}
  for _, row in ipairs(rows) do
    local rec = json.decode(row.record)
    local game = games_by_uri[rec.gameUri]
    if game then
      table.insert(items, {
        uri = row.uri,
        addedAt = rec.addedAt or row.indexed_at,
        game = game
      })
    end
  end

  local result = { items = toarray(items) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
