local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local did = params.did
  if not did or did == "" then
    return { error = "InvalidRequest", message = "did is required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local cursor = params.cursor
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  -- Get liked game URIs from Postgres (likes aren't indexed in meilisearch)
  local likes = db.raw(
    "SELECT record FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.graph.like", did, limit + 1, offset}
  )

  if not likes or #likes == 0 then
    return { feed = toarray({}) }
  end

  local has_more = #likes > limit

  -- Collect URIs for meilisearch batch lookup
  local uris = {}
  for i = 1, math.min(#likes, limit) do
    local rec = json.decode(likes[i].record)
    uris[#uris + 1] = '"' .. rec.subject .. '"'
  end

  -- Batch fetch game data from meilisearch
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

  -- Build feed in like order
  local feed = {}
  for i = 1, math.min(#likes, limit) do
    local like_rec = json.decode(likes[i].record)
    local game_uri = like_rec.subject
    local hit = hits_by_uri[game_uri]
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
