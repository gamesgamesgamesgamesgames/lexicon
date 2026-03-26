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

  -- Compute the cutoff timestamp (7 days ago) using os.time/os.date
  local t = os.time() - 7 * 24 * 3600
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", t)

  -- Get games with the most likes in the last 7 days
  local rows = db.raw(
    "SELECT record::jsonb->>'subject' AS game_uri, COUNT(*) AS like_count FROM records WHERE collection = $1 AND indexed_at > $2 GROUP BY record::jsonb->>'subject' ORDER BY like_count DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.graph.like", cutoff, limit + 1, offset}
  )

  if not rows or #rows == 0 then
    return { feed = toarray({}) }
  end

  local has_more = #rows > limit

  -- Collect URIs for batch lookup
  local uris = {}
  for i = 1, math.min(#rows, limit) do
    uris[#uris + 1] = '"' .. rows[i].game_uri .. '"'
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

  -- Build feed in like-count order
  local feed = {}
  for i = 1, math.min(#rows, limit) do
    local hit = hits_by_uri[rows[i].game_uri]
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
