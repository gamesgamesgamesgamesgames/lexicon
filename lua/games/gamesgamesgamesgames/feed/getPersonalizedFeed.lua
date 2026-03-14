local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

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
    "SELECT record->>'subject' AS game_uri FROM records WHERE collection = $1 AND did = $2 LIMIT 50",
    {"games.gamesgamesgamesgames.graph.like", caller_did}
  )

  if not likes or #likes == 0 then
    return { feed = toarray({}) }
  end

  -- Collect genres and themes from liked games
  local terms = {}
  local liked_uris = {}
  for _, like in ipairs(likes) do
    liked_uris[like.game_uri] = true
    local game = db.get(like.game_uri)
    if game then
      if game.genres then
        for _, g in ipairs(game.genres) do table.insert(terms, g) end
      end
      if game.themes then
        for _, t in ipairs(game.themes) do table.insert(terms, t) end
      end
    end
  end

  if #terms == 0 then
    return { feed = toarray({}) }
  end

  -- Deduplicate and space-separate camelCase terms
  local seen = {}
  local query_terms = {}
  for _, term in ipairs(terms) do
    if not seen[term] then
      seen[term] = true
      local spaced = term:gsub("(%l)(%u)", "%1 %2")
      table.insert(query_terms, spaced)
    end
  end

  local body = {
    q = table.concat(query_terms, " "),
    limit = limit + #likes,
    offset = offset,
    filter = 'type = "game" AND applicationType = "game"',
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits = data.hits or {}

  -- Filter out already-liked games and build feed
  local feed = {}
  for _, hit in ipairs(hits) do
    if not liked_uris[hit.uri] then
      feed[#feed + 1] = {
        game = {
          uri = hit.uri,
          name = hit.name,
          slug = hit.slug,
          media = hit.media,
        }
      }
      if #feed >= limit then break end
    end
  end

  local result = { feed = toarray(feed) }
  if #feed >= limit then
    result.cursor = tostring(offset + limit)
  end
  return result
end
