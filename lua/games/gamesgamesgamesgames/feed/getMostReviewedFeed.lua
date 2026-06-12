local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  local rows = db.raw(
    "SELECT record::jsonb->>'subject' AS game_uri, COUNT(*) AS review_count FROM records WHERE collection = $1 GROUP BY record::jsonb->>'subject' ORDER BY review_count DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.feed.review", limit + 1, offset}
  )

  if not rows or #rows == 0 then
    return { feed = toarray({}) }
  end

  local has_more = #rows > limit

  local uris = {}
  local counts_by_uri = {}
  for i = 1, math.min(#rows, limit) do
    local uri = rows[i].game_uri
    uris[#uris + 1] = '"' .. uri .. '"'
    counts_by_uri[uri] = tonumber(rows[i].review_count) or 0
  end

  local uri_filter = "uri IN [" .. table.concat(uris, ", ") .. "]"
  local body = {
    q = "",
    limit = #uris,
    filter = uri_filter .. " AND publishedAt IS NOT NULL",
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "genres" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits_by_uri = {}
  for _, hit in ipairs(data.hits or {}) do
    hits_by_uri[hit.uri] = hit
  end

  local feed = {}
  for i = 1, math.min(#rows, limit) do
    local uri = rows[i].game_uri
    local hit = hits_by_uri[uri]
    if hit then
      feed[#feed + 1] = {
        game = {
          uri = hit.uri,
          name = hit.name,
          slug = hit.slug,
          media = hit.media,
          genres = hit.genres or toarray({}),
          reviewCount = counts_by_uri[uri] or 0,
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
