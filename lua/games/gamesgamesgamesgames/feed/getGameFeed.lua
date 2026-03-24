-- Generic game feed hydrator, modeled after app.bsky.feed.getFeed.
-- Takes a feed URI, resolves the generator, fetches a skeleton, and
-- hydrates each item into a full game view.

local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

-- Parse the rkey from a feed AT-URI (at://did/collection/rkey)
local function parse_rkey(uri)
  return uri:match("[^/]+$")
end

-- Get like count for a game URI
local function get_like_count(game_uri)
  local result = db.raw(
    "SELECT COUNT(*) AS count FROM records WHERE collection = $1 AND json_extract(record, '$.subject') = $2",
    {"games.gamesgamesgamesgames.graph.like", game_uri}
  )
  if result and result[1] then
    return tonumber(result[1].count) or 0
  end
  return 0
end

-- Get viewer's like URI for a game (nil if not liked or not authenticated)
local function get_viewer_like(game_uri)
  if not caller_did or caller_did == "" then
    return nil
  end
  local result = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND did = $2 AND json_extract(record, '$.subject') = $3 LIMIT 1",
    {"games.gamesgamesgamesgames.graph.like", caller_did, game_uri}
  )
  if result and result[1] then
    return result[1].uri
  end
  return nil
end

-- Look up slug from the slugs table
local function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

-- Hydrate a game URI into a full gameView with like counts and viewer state
local function hydrate_game(game_uri, slug)
  local game = db.get(game_uri)
  if not game then
    return nil
  end

  local like_count = get_like_count(game_uri)
  local viewer_like = get_viewer_like(game_uri)

  local view = {
    uri = game_uri,
    name = game.name,
    applicationType = game.applicationType,
    summary = game.summary,
    genres = game.genres,
    themes = game.themes,
    media = game.media,
    releases = game.releases,
    slug = slug or find_slug(game_uri),
    likeCount = like_count,
  }

  if viewer_like then
    view.viewer = { like = viewer_like }
  end

  return view
end

-- Parse the DID from a feed AT-URI (at://did/collection/rkey)
local function parse_did(uri)
  return uri:match("^at://([^/]+)/")
end

function handle()
  local feed_uri = params.feed
  if not feed_uri or feed_uri == "" then
    return { error = "UnknownFeed" }
  end

  local feed_did = parse_did(feed_uri)
  if not feed_did then
    return { error = "UnknownFeed" }
  end

  local rkey = parse_rkey(feed_uri)
  if not rkey then
    return { error = "UnknownFeed" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  -- Resolve the feed generator's service endpoint
  local service_url
  if feed_did == env.SERVICE_DID then
    service_url = env.SELF_URL or ""
  else
    service_url = atproto.resolve_service_endpoint(feed_did)
  end

  if not service_url or service_url == "" then
    return { error = "UnknownFeed", message = "Could not resolve feed generator DID" }
  end

  -- Fetch skeleton from the feed generator
  local qs = "feed=" .. feed_uri .. "&limit=" .. limit
  if params.cursor then
    qs = qs .. "&cursor=" .. params.cursor
  end

  local resp = http.get(
    service_url .. "/xrpc/games.gamesgamesgamesgames.feed.getFeedSkeleton?" .. qs
  )

  if resp.status ~= 200 then
    return { error = "UnknownFeed", message = "Feed generator returned status " .. resp.status }
  end

  local data = json.decode(resp.body)
  if not data or not data.feed then
    return { error = "UnknownFeed", message = "Invalid skeleton response" }
  end

  -- Hydrate each skeleton item into a full game view
  local feed_items = {}
  for _, item in ipairs(data.feed) do
    local game_view = hydrate_game(item.game, item.slug)
    if game_view then
      feed_items[#feed_items + 1] = {
        game = game_view,
        feedContext = item.feedContext,
      }
    end
  end

  local result = { feed = toarray(feed_items) }
  if data.cursor then
    result.cursor = data.cursor
  end
  return result
end
