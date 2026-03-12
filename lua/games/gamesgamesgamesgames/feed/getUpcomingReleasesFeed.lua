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

  -- now() returns ISO 8601 e.g. "2026-03-12T..."
  local y, m, d = now():match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  local today = tonumber(y .. m .. d)

  local body = {
    q = "",
    limit = limit + 1,
    offset = offset,
    filter = "type = \"game\" AND cancelled != true AND firstReleaseDate > " .. today,
    sort = toarray({ "firstReleaseDate:asc" }),
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits = data.hits or {}
  local has_more = #hits > limit

  local feed = {}
  for i = 1, math.min(#hits, limit) do
    local hit = hits[i]
    feed[#feed + 1] = {
      game = {
        uri = hit.uri,
        name = hit.name,
        slug = hit.slug,
        media = hit.media,
      }
    }
  end

  local result = { feed = toarray(feed) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
