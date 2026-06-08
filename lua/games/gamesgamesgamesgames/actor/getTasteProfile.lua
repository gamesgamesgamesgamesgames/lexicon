local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local GAME_ATTRIBUTES = toarray({
  "uri", "name", "slug", "media", "applicationType", "genres", "themes", "releases"
})

function handle()
  local did = params.did
  if not did or did == "" then
    return { error = "InvalidRequest", message = "did is required" }
  end

  local genre_limit = tonumber(params.genreLimit) or 5
  if genre_limit < 1 then genre_limit = 1 end
  if genre_limit > 20 then genre_limit = 20 end

  local favorite_limit = tonumber(params.favoriteLimit) or 6
  if favorite_limit < 1 then favorite_limit = 1 end
  if favorite_limit > 12 then favorite_limit = 12 end

  -- Fetch likes (up to 500 most recent)
  local like_rows = db.raw(
    "SELECT record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT 500",
    {"games.gamesgamesgamesgames.graph.like", did}
  )

  -- Fetch reviews (up to 500 most recent)
  local review_rows = db.raw(
    "SELECT record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT 500",
    {"social.popfeed.feed.review", did}
  )

  -- Collect game URIs from likes and IGDB IDs from reviews
  local like_uris = {}
  local like_timestamps = {}
  for _, row in ipairs(like_rows or {}) do
    local rec = json.decode(row.record)
    if rec.subject then
      like_uris[rec.subject] = true
      like_timestamps[rec.subject] = row.indexed_at
    end
  end

  local review_igdb_ids = {}
  local review_timestamps = {}
  for _, row in ipairs(review_rows or {}) do
    local rec = json.decode(row.record)
    local igdb_id = rec.identifiers and rec.identifiers.igdbId
    if igdb_id then
      review_igdb_ids[igdb_id] = true
      review_timestamps[igdb_id] = row.indexed_at
    end
  end

  -- Batch fetch games from Meilisearch
  local games_by_uri = {}

  -- Fetch liked games by URI
  local uri_list = {}
  for uri, _ in pairs(like_uris) do
    uri_list[#uri_list + 1] = '"' .. uri .. '"'
  end

  if #uri_list > 0 then
    local body = {
      q = "",
      limit = #uri_list,
      filter = "uri IN [" .. table.concat(uri_list, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = GAME_ATTRIBUTES
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        games_by_uri[hit.uri] = hit
      end
    end
  end

  -- Fetch reviewed games by IGDB ID
  local igdb_list = {}
  for igdb_id, _ in pairs(review_igdb_ids) do
    igdb_list[#igdb_list + 1] = igdb_id
  end

  if #igdb_list > 0 then
    local body = {
      q = "",
      limit = #igdb_list,
      filter = "externalIds.igdb IN [" .. table.concat(igdb_list, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = GAME_ATTRIBUTES
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        games_by_uri[hit.uri] = hit
      end
    end
  end

  -- Build a map of IGDB ID -> game URI for cross-referencing
  local igdb_to_uri = {}
  for _, game in pairs(games_by_uri) do
    if game.externalIds and game.externalIds.igdb then
      igdb_to_uri[game.externalIds.igdb] = game.uri
    end
  end

  -- Score each game: like = 1pt, review = 3pt, both = 4pt
  -- Track genre weights: like = 1x, review = 2x, both = review weight only (2x)
  local game_scores = {}
  local genre_weights = {}
  local game_timestamps = {}

  for uri, _ in pairs(like_uris) do
    if games_by_uri[uri] then
      game_scores[uri] = (game_scores[uri] or 0) + 1
      game_timestamps[uri] = like_timestamps[uri]

      local game = games_by_uri[uri]
      if game.genres then
        for _, genre in ipairs(game.genres) do
          genre_weights[genre] = (genre_weights[genre] or 0) + 1
        end
      end
    end
  end

  for igdb_id, _ in pairs(review_igdb_ids) do
    local uri = igdb_to_uri[igdb_id]
    if uri and games_by_uri[uri] then
      game_scores[uri] = (game_scores[uri] or 0) + 3

      if review_timestamps[igdb_id] then
        local existing = game_timestamps[uri]
        if not existing or review_timestamps[igdb_id] > existing then
          game_timestamps[uri] = review_timestamps[igdb_id]
        end
      end

      local game = games_by_uri[uri]
      if game.genres then
        for _, genre in ipairs(game.genres) do
          if like_uris[uri] then
            -- Already counted 1x from like; upgrade to 2x total (add 1 more)
            genre_weights[genre] = (genre_weights[genre] or 0) + 1
          else
            -- Review only: count 2x
            genre_weights[genre] = (genre_weights[genre] or 0) + 2
          end
        end
      end
    end
  end

  -- Build genre preferences sorted by weight
  local genre_entries = {}
  local total_weight = 0
  for genre, weight in pairs(genre_weights) do
    genre_entries[#genre_entries + 1] = { genre = genre, weight = weight }
    total_weight = total_weight + weight
  end

  table.sort(genre_entries, function(a, b) return a.weight > b.weight end)

  local genres = {}
  for i = 1, math.min(#genre_entries, genre_limit) do
    local entry = genre_entries[i]
    genres[#genres + 1] = {
      genre = entry.genre,
      count = entry.weight,
      percentage = math.floor((entry.weight / total_weight) * 100 + 0.5),
    }
  end

  -- Build favorites sorted by score, then by most recent interaction
  local favorite_entries = {}
  for uri, score in pairs(game_scores) do
    favorite_entries[#favorite_entries + 1] = {
      uri = uri,
      score = score,
      timestamp = game_timestamps[uri] or "",
    }
  end

  table.sort(favorite_entries, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.timestamp > b.timestamp
  end)

  local favorites = {}
  for i = 1, math.min(#favorite_entries, favorite_limit) do
    local game = games_by_uri[favorite_entries[i].uri]
    if game then
      favorites[#favorites + 1] = {
        uri = game.uri,
        name = game.name,
        slug = game.slug,
        media = game.media,
        applicationType = game.applicationType,
        genres = game.genres or toarray({}),
        themes = game.themes,
        releases = game.releases,
      }
    end
  end

  return {
    genres = toarray(genres),
    favorites = toarray(favorites),
  }
end
