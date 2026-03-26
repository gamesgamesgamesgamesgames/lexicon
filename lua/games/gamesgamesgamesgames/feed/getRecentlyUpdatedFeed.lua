local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  -- Get games ordered by most recently indexed
  local rows = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND record::jsonb->>'applicationType' = 'game' ORDER BY indexed_at DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.game", limit + 1, offset}
  )

  if not rows or #rows == 0 then
    return { feed = toarray({}) }
  end

  local has_more = #rows > limit

  -- Collect URIs for batch lookup
  local uris = {}
  for i = 1, math.min(#rows, limit) do
    uris[#uris + 1] = '"' .. rows[i].uri .. '"'
  end

  -- Batch fetch game data from Meilisearch
  local body = {
    q = "",
    limit = #uris,
    filter = "uri IN [" .. table.concat(uris, ", ") .. "]",
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  -- Index hits by URI for ordered lookup
  local hits_by_uri = {}
  for _, hit in ipairs(data.hits or {}) do
    hits_by_uri[hit.uri] = hit
  end

  -- Build feed in indexed_at order
  local feed = {}
  for i = 1, math.min(#rows, limit) do
    local hit = hits_by_uri[rows[i].uri]
    if hit then
      feed[#feed + 1] = {
        game = {
          uri = hit.uri,
          name = hit.name,
          slug = hit.slug,
          media = hit.media,
        }
      }
    end
  end

  local result = { feed = toarray(feed) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
