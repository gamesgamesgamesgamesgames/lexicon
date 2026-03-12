-- Deprecated: use getGameFeed with the 'similar' feed URI instead.

local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

-- Get like count for a game URI
local function get_like_count(game_uri)
  local result = db.raw(
    "SELECT COUNT(*) AS count FROM records WHERE collection = $1 AND record->>'subject' = $2",
    {"games.gamesgamesgamesgames.graph.like", game_uri}
  )
  if result and result[1] then
    return tonumber(result[1].count) or 0
  end
  return 0
end

-- Get viewer's like URI for a game
local function get_viewer_like(game_uri)
  if not caller_did or caller_did == "" then return nil end
  local result = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND did = $2 AND record->>'subject' = $3 LIMIT 1",
    {"games.gamesgamesgamesgames.graph.like", caller_did, game_uri}
  )
  if result and result[1] then return result[1].uri end
  return nil
end

-- Hydrate a game URI into a gameView
local function hydrate_game(game_uri)
  local game = db.get(game_uri)
  if not game then return nil end

  local view = {
    uri = game_uri,
    name = game.name,
    applicationType = game.applicationType,
    summary = game.summary,
    genres = game.genres,
    themes = game.themes,
    media = game.media,
    releases = game.releases,
    slug = game.slug,
    likeCount = get_like_count(game_uri),
  }

  local viewer_like = get_viewer_like(game_uri)
  if viewer_like then
    view.viewer = { like = viewer_like }
  end

  return view
end

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
    attributesToRetrieve = toarray({ "uri" })
  }

  local encoded_body = json.encode(body)
  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = encoded_body
  })

  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits = data.hits or {}

  -- Hydrate each hit, skipping the source game
  local feed = {}
  for _, hit in ipairs(hits) do
    if hit.uri ~= game_uri then
      local game_view = hydrate_game(hit.uri)
      if game_view then
        feed[#feed + 1] = { game = game_view, feedContext = game_uri }
        if #feed >= limit then break end
      end
    end
  end

  return { feed = toarray(feed) }
end
