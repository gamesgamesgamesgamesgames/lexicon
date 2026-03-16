-- Generic game feed hydrator, modeled after app.bsky.feed.getFeed.
-- Takes a feed URI, resolves the algorithm, fetches a skeleton, and
-- hydrates each item into a full game view.
--
-- Individual feed algorithms also have their own standalone XRPC
-- endpoints (e.g. getHotGamesFeed, getUpcomingReleasesFeed) for
-- direct consumption.

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
    "SELECT COUNT(*) AS count FROM records WHERE collection = $1 AND record->>'subject' = $2",
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
    "SELECT uri FROM records WHERE collection = $1 AND did = $2 AND record->>'subject' = $3 LIMIT 1",
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

-- ============================================================
-- Skeleton algorithms
-- Each returns { items, cursor } where items is an array of
-- { game = uri } tables.
-- ============================================================

local function skeleton_likes(limit, cursor)
  if not caller_did or caller_did == "" then
    return nil, nil, "Authentication required"
  end

  local offset = 0
  if cursor then offset = tonumber(cursor) or 0 end

  local likes = db.raw(
    "SELECT record, uri AS like_uri FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.graph.like", caller_did, limit + 1, offset}
  )

  if not likes then return {}, nil end

  local has_more = #likes > limit
  local items = {}
  for i = 1, math.min(#likes, limit) do
    items[#items + 1] = { game = likes[i].record.subject }
  end

  local next_cursor = nil
  if has_more then next_cursor = tostring(offset + limit) end
  return items, next_cursor
end

local function skeleton_upcoming(limit, cursor)
  local offset = 0
  if cursor then offset = tonumber(cursor) or 0 end

  local y, m, d = now():match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  local now_int = tonumber(y .. m .. d)

  local rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = $1 AND record->>'applicationType' = 'game' ORDER BY indexed_at DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.game", limit * 3, offset}
  )

  if not rows then return {}, nil end

  local items = {}
  for _, row in ipairs(rows) do
    local game = row.record
    if game and game.releases then
      local is_upcoming = false
      for _, release in ipairs(game.releases) do
        if release.releaseDates then
          for _, rd in ipairs(release.releaseDates) do
            if rd.releasedAt and rd.releasedAtFormat == "YYYY-MM-DD" then
              local date_int = tonumber(rd.releasedAt:gsub("-", ""))
              if date_int and date_int > now_int then is_upcoming = true; break end
            elseif rd.releasedAtFormat == "TBD" then
              is_upcoming = true; break
            end
          end
        end
        if is_upcoming then break end
      end
      if is_upcoming then
        items[#items + 1] = { game = row.uri }
        if #items >= limit then break end
      end
    end
  end

  local next_cursor = nil
  if #items >= limit then next_cursor = tostring(offset + limit * 3) end
  return items, next_cursor
end

local function skeleton_recently_updated(limit, cursor)
  local offset = 0
  if cursor then offset = tonumber(cursor) or 0 end

  local rows = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND record->>'applicationType' = 'game' ORDER BY indexed_at DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.game", limit + 1, offset}
  )

  if not rows then return {}, nil end

  local has_more = #rows > limit
  local items = {}
  for i = 1, math.min(#rows, limit) do
    items[#items + 1] = { game = rows[i].uri }
  end

  local next_cursor = nil
  if has_more then next_cursor = tostring(offset + limit) end
  return items, next_cursor
end

local function skeleton_hot(limit, cursor)
  local offset = 0
  if cursor then offset = tonumber(cursor) or 0 end

  local rows = db.raw(
    "SELECT record->>'subject' AS game_uri, COUNT(*) AS like_count FROM records WHERE collection = $1 AND indexed_at > NOW() - INTERVAL '7 days' GROUP BY record->>'subject' ORDER BY like_count DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.graph.like", limit + 1, offset}
  )

  if not rows then return {}, nil end

  local has_more = #rows > limit
  local items = {}
  for i = 1, math.min(#rows, limit) do
    items[#items + 1] = { game = rows[i].game_uri }
  end

  local next_cursor = nil
  if has_more then next_cursor = tostring(offset + limit) end
  return items, next_cursor
end

local function skeleton_personalized(limit, cursor)
  if not caller_did or caller_did == "" then
    return nil, nil, "Authentication required"
  end

  local offset = 0
  if cursor then offset = tonumber(cursor) or 0 end

  local likes = db.raw(
    "SELECT record->>'subject' AS game_uri FROM records WHERE collection = $1 AND did = $2 LIMIT 50",
    {"games.gamesgamesgamesgames.graph.like", caller_did}
  )

  if not likes or #likes == 0 then return {}, nil end

  local terms = {}
  local liked_uris = {}
  for _, like in ipairs(likes) do
    liked_uris[like.game_uri] = true
    local game = db.get(like.game_uri)
    if game then
      if game.genres then for _, g in ipairs(game.genres) do table.insert(terms, g) end end
      if game.themes then for _, t in ipairs(game.themes) do table.insert(terms, t) end end
    end
  end

  if #terms == 0 then return {}, nil end

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
    attributesToRetrieve = toarray({ "uri" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)
  local hits = data.hits or {}

  local items = {}
  for _, hit in ipairs(hits) do
    if not liked_uris[hit.uri] then
      items[#items + 1] = { game = hit.uri }
      if #items >= limit then break end
    end
  end

  local next_cursor = nil
  if #items >= limit then next_cursor = tostring(offset + limit) end
  return items, next_cursor
end

-- Algorithm dispatch table
local algorithms = {
  likes = skeleton_likes,
  upcoming = skeleton_upcoming,
  ["recently-updated"] = skeleton_recently_updated,
  hot = skeleton_hot,
  personalized = skeleton_personalized,
}

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

  local skeleton, next_cursor, err

  if feed_did == env.SERVICE_DID then
    -- Internal feed: use local skeleton algorithm
    local algo = algorithms[rkey]
    if not algo then
      return { error = "UnknownFeed" }
    end
    skeleton, next_cursor, err = algo(limit, params.cursor)
  else
    -- External feed: resolve DID and call remote getFeedSkeleton
    local service_url = atproto.resolve_service_endpoint(feed_did)
    if not service_url then
      return { error = "UnknownFeed", message = "Could not resolve feed generator DID" }
    end

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

    skeleton = {}
    for _, item in ipairs(data.feed) do
      skeleton[#skeleton + 1] = { game = item.game }
    end
    next_cursor = data.cursor
  end

  if err then
    return { error = err }
  end

  if not skeleton or #skeleton == 0 then
    return { feed = toarray({}) }
  end

  -- Hydrate each skeleton item into a full game view
  local feed_items = {}
  for _, item in ipairs(skeleton) do
    local game_view = hydrate_game(item.game, item.slug)
    if game_view then
      feed_items[#feed_items + 1] = {
        game = game_view,
        feedContext = item.feedContext,
      }
    end
  end

  local result = { feed = toarray(feed_items) }
  if next_cursor then
    result.cursor = next_cursor
  end
  return result
end
