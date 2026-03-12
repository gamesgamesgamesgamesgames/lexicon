-- Deprecated: use getGameFeed with the 'similar' feed URI instead.

local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local game_uri = params.uri
  local limit = tonumber(params.limit) or 5
  if limit < 1 then limit = 1 end
  if limit > 10 then limit = 10 end

  local source = db.get(game_uri)
  if not source then
    return { feed = toarray({}) }
  end

  -- Build search query from game attributes
  local terms = {}
  if source.genres then for _, g in ipairs(source.genres) do table.insert(terms, g) end end
  if source.themes then for _, t in ipairs(source.themes) do table.insert(terms, t) end end
  if source.modes then for _, m in ipairs(source.modes) do table.insert(terms, m) end end
  if source.playerPerspectives then for _, p in ipairs(source.playerPerspectives) do table.insert(terms, p) end end
  if source.keywords then
    for i, k in ipairs(source.keywords) do
      if i > 5 then break end
      table.insert(terms, k)
    end
  end

  if #terms == 0 then
    return { feed = toarray({}) }
  end

  local query_terms = {}
  for _, term in ipairs(terms) do
    local spaced = term:gsub("(%l)(%u)", "%1 %2")
    table.insert(query_terms, spaced)
  end
  local q = table.concat(query_terms, " ")

  local body = {
    q = q,
    limit = limit + 1,
    filter = 'type = "game" AND applicationType = "game"',
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

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
