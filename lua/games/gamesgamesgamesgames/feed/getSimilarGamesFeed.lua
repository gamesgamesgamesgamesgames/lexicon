local SIMILAR_URL = env.MEILISEARCH_URL .. "/indexes/records/similar"

local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

-- Base64url-encode an AT URI into a Meilisearch document ID.
-- Must match the encoding in game.lua and meilisearch-backfill.ts.
local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function to_doc_id(s)
  local out = {}
  local i = 1
  while i <= #s do
    local a, b, c = string.byte(s, i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 65536 + b * 256 + c
    local remaining = #s - i + 1
    table.insert(out, string.sub(b64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
    table.insert(out, string.sub(b64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if remaining >= 2 then table.insert(out, string.sub(b64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)) end
    if remaining >= 3 then table.insert(out, string.sub(b64, n % 64 + 1, n % 64 + 1)) end
    i = i + 3
  end
  return table.concat(out)
end

function handle()
  local game_uri = params.uri
  local limit = tonumber(params.limit) or 5
  if limit < 1 then limit = 1 end
  if limit > 10 then limit = 10 end

  local body = {
    id = to_doc_id(game_uri),
    embedder = "game-similarity",
    limit = limit + 1,
    filter = 'type = "game" AND applicationType = "game" AND publishedAt IS NOT NULL',
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
  }

  local resp = http.post(SIMILAR_URL, { headers = HEADERS, body = json.encode(body) })

  if resp.status ~= 200 then
    local data = json.decode(resp.body)
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  local feed = {}
  for _, hit in ipairs(hits) do
    if hit.uri ~= game_uri then
      feed[#feed + 1] = {
        game = {
          uri = hit.uri,
          name = hit.name,
          slug = hit.slug,
          media = hit.media,
        },
        feedContext = game_uri,
      }
      if #feed >= limit then break end
    end
  end

  return { feed = toarray(feed) }
end
