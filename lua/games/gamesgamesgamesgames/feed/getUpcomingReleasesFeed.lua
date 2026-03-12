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
    attributesToRetrieve = toarray({ "uri" })
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
    local game_view = hydrate_game(hits[i].uri)
    if game_view then
      feed[#feed + 1] = { game = game_view }
    end
  end

  local result = { feed = toarray(feed) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
