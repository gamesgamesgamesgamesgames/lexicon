local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local did = params.did
  if not did or did == "" then
    return { error = "InvalidRequest", message = "did is required" }
  end

  local limit = tonumber(params.limit) or 30
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local cursor = params.cursor
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  -- Fetch enough raw items to fill one page after deduplication.
  -- We grab extra to account for games that may not exist in meilisearch.
  local fetch_limit = limit + offset + 20

  -- Get likes with timestamps
  local like_rows = db.raw(
    "SELECT record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3",
    {"games.gamesgamesgamesgames.graph.like", did, fetch_limit}
  )

  -- Get reviews with timestamps
  local review_rows = db.raw(
    "SELECT uri, record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3",
    {"social.popfeed.feed.review", did, fetch_limit}
  )

  -- Build unified activity list
  local activities = {}

  for _, row in ipairs(like_rows or {}) do
    local rec = json.decode(row.record)
    local ts = rec.createdAt or row.indexed_at
    table.insert(activities, {
      type = "like",
      created_at = ts,
      game_uri = rec.subject,
    })
  end

  for _, row in ipairs(review_rows or {}) do
    local rec = json.decode(row.record)
    local ts = rec.createdAt or row.indexed_at

    -- Reviews reference games by IGDB ID; we need to resolve the game URI.
    -- Store the review data and igdb_id for later resolution.
    local igdb_id = rec.identifiers and rec.identifiers.igdbId
    if igdb_id then
      table.insert(activities, {
        type = "review",
        created_at = ts,
        igdb_id = igdb_id,
        review_uri = row.uri,
        review = {
          rating = rec.rating,
          text = rec.text,
          title = rec.title,
          tags = rec.tags,
          containsSpoilers = rec.containsSpoilers,
          createdAt = rec.createdAt,
        },
      })
    end
  end

  -- Sort by created_at descending
  table.sort(activities, function(a, b)
    return a.created_at > b.created_at
  end)

  -- Apply pagination
  local page_start = offset + 1
  local page_end = offset + limit
  local page_items = {}
  for i = page_start, math.min(page_end, #activities) do
    table.insert(page_items, activities[i])
  end

  if #page_items == 0 then
    return { feed = toarray({}) }
  end

  -- Collect game URIs (from likes) and IGDB IDs (from reviews) for batch lookup
  local game_uris = {}
  local igdb_ids = {}
  local seen_uris = {}
  local seen_igdb = {}

  for _, item in ipairs(page_items) do
    if item.type == "like" and item.game_uri and not seen_uris[item.game_uri] then
      seen_uris[item.game_uri] = true
      game_uris[#game_uris + 1] = '"' .. item.game_uri .. '"'
    elseif item.type == "review" and item.igdb_id and not seen_igdb[item.igdb_id] then
      seen_igdb[item.igdb_id] = true
      igdb_ids[#igdb_ids + 1] = '"' .. item.igdb_id .. '"'
    end
  end

  -- Batch fetch games by URI
  local hits_by_uri = {}
  if #game_uris > 0 then
    local body = {
      q = "",
      limit = #game_uris,
      filter = "uri IN [" .. table.concat(game_uris, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "applicationType", "genres", "themes", "releases" })
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        hits_by_uri[hit.uri] = hit
      end
    end
  end

  -- Batch fetch games by IGDB ID for reviews
  local hits_by_igdb = {}
  if #igdb_ids > 0 then
    local body = {
      q = "",
      limit = #igdb_ids,
      filter = "externalIds.igdb IN [" .. table.concat(igdb_ids, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "applicationType", "genres", "themes", "releases", "externalIds" })
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        if hit.externalIds and hit.externalIds.igdb then
          hits_by_igdb[hit.externalIds.igdb] = hit
        end
      end
    end
  end

  -- Build feed
  local feed = {}
  for _, item in ipairs(page_items) do
    local game_hit = nil

    if item.type == "like" then
      game_hit = hits_by_uri[item.game_uri]
    elseif item.type == "review" then
      game_hit = hits_by_igdb[item.igdb_id]
    end

    if game_hit then
      local entry = {
        type = item.type,
        createdAt = item.created_at,
        game = {
          uri = game_hit.uri,
          name = game_hit.name,
          slug = game_hit.slug,
          media = game_hit.media,
          applicationType = game_hit.applicationType,
          genres = game_hit.genres,
          themes = game_hit.themes,
          releases = game_hit.releases,
        },
      }

      if item.type == "review" and item.review then
        entry.review = {
          ["$type"] = "games.gamesgamesgamesgames.defs#activityReviewView",
          uri = item.review_uri,
          rating = item.review.rating,
          text = item.review.text,
          title = item.review.title,
          tags = item.review.tags,
          containsSpoilers = item.review.containsSpoilers,
          createdAt = item.review.createdAt,
        }
      end

      feed[#feed + 1] = entry
    end
  end

  local result = { feed = toarray(feed) }
  if page_end < #activities then
    result.cursor = tostring(page_end)
  end
  return result
end
