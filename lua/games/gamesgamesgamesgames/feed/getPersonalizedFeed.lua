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
  if not caller_did or caller_did == "" then
    return { error = "AuthRequired", message = "Authentication required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  -- Get user's liked game URIs
  local likes = db.raw(
    "SELECT json_extract(record, '$.subject') AS game_uri FROM records WHERE collection = $1 AND did = $2 LIMIT 50",
    {"games.gamesgamesgamesgames.graph.like", caller_did}
  )

  if not likes or #likes == 0 then
    return { feed = toarray({}) }
  end

  local liked_uris = {}
  for _, like in ipairs(likes) do
    liked_uris[like.game_uri] = true
  end

  -- Fetch similar games for each liked game via vector embeddings
  local scores = {}  -- uri -> { score, game }
  local per_like_limit = math.ceil(limit / #likes) + 1

  for _, like in ipairs(likes) do
    local body = {
      id = to_doc_id(like.game_uri),
      embedder = "game-similarity",
      limit = per_like_limit,
      filter = 'type = "game" AND applicationType = "game"',
      attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
    }

    local resp = http.post(SIMILAR_URL, { headers = HEADERS, body = json.encode(body) })

    if resp.status == 200 then
      local data = json.decode(resp.body)
      local hits = data.hits or {}

      for rank, hit in ipairs(hits) do
        if not liked_uris[hit.uri] then
          -- Accumulate a relevance score: higher-ranked hits from more liked
          -- games score higher. 1/rank gives diminishing returns per result.
          local contribution = 1 / rank
          if scores[hit.uri] then
            scores[hit.uri].score = scores[hit.uri].score + contribution
          else
            scores[hit.uri] = {
              score = contribution,
              game = {
                uri = hit.uri,
                name = hit.name,
                slug = hit.slug,
                media = hit.media,
              }
            }
          end
        end
      end
    end
  end

  -- Sort by accumulated score descending
  local sorted = {}
  for _, entry in pairs(scores) do
    sorted[#sorted + 1] = entry
  end
  table.sort(sorted, function(a, b) return a.score > b.score end)

  -- Apply pagination
  local feed = {}
  for i = offset + 1, math.min(offset + limit, #sorted) do
    feed[#feed + 1] = { game = sorted[i].game }
  end

  local result = { feed = toarray(feed) }
  if offset + limit < #sorted then
    result.cursor = tostring(offset + limit)
  end
  return result
end
