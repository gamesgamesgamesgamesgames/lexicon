local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local genre = params.genre
  if not genre or genre == "" then
    return { error = "InvalidRequest", message = "genre parameter is required" }
  end

  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  local safe_genre = genre:gsub('"', '')

  local body = {
    q = "",
    limit = limit,
    offset = offset,
    filter = 'genres = "' .. safe_genre .. '" AND publishedAt IS NOT NULL',
    sort = toarray({ "firstReleaseDate:desc" }),
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "genres" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local feed = {}
  for _, hit in ipairs(data.hits or {}) do
    feed[#feed + 1] = {
      game = {
        uri = hit.uri,
        name = hit.name,
        slug = hit.slug,
        media = hit.media,
        genres = hit.genres or toarray({})
      }
    }
  end

  local result = { feed = toarray(feed) }
  local total = data.estimatedTotalHits or 0
  local next_offset = offset + limit
  if next_offset < total then
    result.cursor = tostring(next_offset)
  end
  return result
end
