local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

-- Parse the rkey from a feed AT-URI (at://did/collection/rkey)
local function parse_rkey(uri)
  return uri:match("[^/]+$")
end

-- Likes: user's liked games ordered by most recently liked (requires auth)
local function algo_likes(limit, cursor)
  if not caller_did or caller_did == "" then
    return { error = "Authentication required" }
  end

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
  local items = {}
  for i = 1, math.min(#likes, limit) do
    items[#items + 1] = { game = likes[i].record.subject }
  end

  local result = { feed = toarray(items) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end

-- Similar: games similar to a given game (feedContext carries source game URI)
local function algo_similar(limit, cursor, feed_context)
  local source_uri = feed_context
  if not source_uri or source_uri == "" then
    return { feed = toarray({}) }
  end

  local game = db.get(source_uri)
  if not game then
    return { feed = toarray({}) }
  end

  local terms = {}
  if game.genres then
    for _, g in ipairs(game.genres) do table.insert(terms, g) end
  end
  if game.themes then
    for _, t in ipairs(game.themes) do table.insert(terms, t) end
  end
  if game.modes then
    for _, m in ipairs(game.modes) do table.insert(terms, m) end
  end
  if game.playerPerspectives then
    for _, p in ipairs(game.playerPerspectives) do table.insert(terms, p) end
  end
  if game.keywords then
    for i, k in ipairs(game.keywords) do
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

  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode(body)
  })

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  local items = {}
  for _, hit in ipairs(hits) do
    if hit.uri ~= source_uri then
      items[#items + 1] = { game = hit.uri, feedContext = source_uri }
      if #items >= limit then break end
    end
  end

  return { feed = toarray(items) }
end

-- Upcoming: games with future release dates
local function algo_upcoming(limit, cursor)
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  -- Get current date as YYYYMMDD integer for comparison
  local now = os.date("!%Y%m%d")
  local now_int = tonumber(now)

  local rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = $1 AND record->>'applicationType' = 'game' ORDER BY indexed_at DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.game", limit * 3, offset}
  )

  if not rows then
    return { feed = toarray({}) }
  end

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
              if date_int and date_int > now_int then
                is_upcoming = true
                break
              end
            elseif rd.releasedAtFormat == "TBD" then
              is_upcoming = true
              break
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

  local result = { feed = toarray(items) }
  if #items >= limit then
    result.cursor = tostring(offset + limit * 3)
  end
  return result
end

-- Recently updated: games ordered by most recent indexedAt
local function algo_recently_updated(limit, cursor)
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  local rows = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND record->>'applicationType' = 'game' ORDER BY indexed_at DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.game", limit + 1, offset}
  )

  if not rows then
    return { feed = toarray({}) }
  end

  local has_more = #rows > limit
  local items = {}
  for i = 1, math.min(#rows, limit) do
    items[#items + 1] = { game = rows[i].uri }
  end

  local result = { feed = toarray(items) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end

-- Hot: games with the most likes in the last 7 days
local function algo_hot(limit, cursor)
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  local rows = db.raw(
    "SELECT record->>'subject' AS game_uri, COUNT(*) AS like_count FROM records WHERE collection = $1 AND indexed_at > NOW() - INTERVAL '7 days' GROUP BY record->>'subject' ORDER BY like_count DESC LIMIT $2 OFFSET $3",
    {"games.gamesgamesgamesgames.graph.like", limit + 1, offset}
  )

  if not rows then
    return { feed = toarray({}) }
  end

  local has_more = #rows > limit
  local items = {}
  for i = 1, math.min(#rows, limit) do
    items[#items + 1] = { game = rows[i].game_uri }
  end

  local result = { feed = toarray(items) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end

-- Personalized: games matching the user's liked genres/themes (requires auth)
local function algo_personalized(limit, cursor)
  if not caller_did or caller_did == "" then
    return { error = "Authentication required" }
  end

  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

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
  local q = table.concat(query_terms, " ")

  local body = {
    q = q,
    limit = limit + #likes,
    offset = offset,
    filter = 'type = "game" AND applicationType = "game"',
    attributesToRetrieve = toarray({ "uri" })
  }

  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode(body)
  })

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  -- Filter out already-liked games
  local items = {}
  for _, hit in ipairs(hits) do
    if not liked_uris[hit.uri] then
      items[#items + 1] = { game = hit.uri }
      if #items >= limit then break end
    end
  end

  local result = { feed = toarray(items) }
  if #items >= limit then
    result.cursor = tostring(offset + limit)
  end
  return result
end

-- Algorithm dispatch table
local algorithms = {
  likes = algo_likes,
  similar = algo_similar,
  upcoming = algo_upcoming,
  ["recently-updated"] = algo_recently_updated,
  hot = algo_hot,
  personalized = algo_personalized,
}

function handle()
  local feed_uri = params.feed
  if not feed_uri or feed_uri == "" then
    return { error = "UnknownFeed" }
  end

  local rkey = parse_rkey(feed_uri)
  if not rkey then
    return { error = "UnknownFeed" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local algo = algorithms[rkey]
  if not algo then
    return { error = "UnknownFeed" }
  end

  -- For similar feed, pass feedContext from params if available
  if rkey == "similar" then
    return algo(limit, params.cursor, params.feedContext)
  end

  return algo(limit, params.cursor)
end
