-- Deprecated: use getGameFeed with the 'likes' feed URI instead.

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
  if not caller_did or caller_did == "" then
    return { error = "Authentication required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local cursor = params.cursor
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  local likes = db.raw(
    "SELECT record, uri AS like_uri FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.graph.like", caller_did, limit + 1, offset}
  )

  if not likes then
    return { feed = toarray({}) }
  end

  local has_more = #likes > limit

  local feed = {}
  for i = 1, math.min(#likes, limit) do
    local game_view = hydrate_game(likes[i].record.subject)
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
