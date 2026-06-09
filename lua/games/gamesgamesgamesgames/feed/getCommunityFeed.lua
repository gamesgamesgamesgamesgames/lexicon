local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  local fetch_limit = limit + offset + 20

  -- Get recent likes across all users
  local like_rows = db.raw(
    "SELECT did, record, indexed_at FROM records WHERE collection = $1 ORDER BY indexed_at DESC LIMIT $2",
    {"games.gamesgamesgamesgames.graph.like", fetch_limit}
  )

  -- Get recent reviews across all users
  local review_rows = db.raw(
    "SELECT did, uri, record, indexed_at FROM records WHERE collection = $1 ORDER BY indexed_at DESC LIMIT $2",
    {"social.popfeed.feed.review", fetch_limit}
  )

  -- Get recent list item additions across all users
  local list_item_rows = db.raw(
    "SELECT did, uri, record, indexed_at FROM records WHERE collection = $1 ORDER BY indexed_at DESC LIMIT $2",
    {"games.gamesgamesgamesgames.feed.listItem", fetch_limit}
  )

  -- Build unified activity list
  local activities = {}

  for _, row in ipairs(like_rows or {}) do
    local rec = json.decode(row.record)
    local ts = rec.createdAt or row.indexed_at
    table.insert(activities, {
      type = "like",
      created_at = ts,
      did = row.did,
      game_uri = rec.subject,
    })
  end

  for _, row in ipairs(review_rows or {}) do
    local rec = json.decode(row.record)
    local ts = rec.createdAt or row.indexed_at
    local igdb_id = rec.identifiers and rec.identifiers.igdbId
    if igdb_id then
      table.insert(activities, {
        type = "review",
        created_at = ts,
        did = row.did,
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

  for _, row in ipairs(list_item_rows or {}) do
    local rec = json.decode(row.record)
    local ts = rec.addedAt or row.indexed_at
    if rec.gameUri then
      local list_name = nil
      if rec.listUri then
        local list_rec = db.get(rec.listUri)
        if list_rec then
          list_name = list_rec.name
        end
      end

      table.insert(activities, {
        type = "listAddGame",
        created_at = ts,
        did = row.did,
        game_uri = rec.gameUri,
        list_uri = rec.listUri,
        list_name = list_name,
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

  -- Collect unique DIDs for actor profile lookup
  local unique_dids = {}
  local seen_dids = {}
  for _, item in ipairs(page_items) do
    if item.did and not seen_dids[item.did] then
      seen_dids[item.did] = true
      unique_dids[#unique_dids + 1] = item.did
    end
  end

  -- Batch fetch actor profiles
  local profiles_by_did = {}
  if #unique_dids > 0 then
    local placeholders = {}
    for i, _ in ipairs(unique_dids) do
      placeholders[i] = "$" .. (i + 1)
    end
    local sql = "SELECT did, record FROM records WHERE collection = $1 AND did IN (" .. table.concat(placeholders, ", ") .. ")"
    local sql_params = {"games.gamesgamesgamesgames.actor.profile"}
    for _, d in ipairs(unique_dids) do
      sql_params[#sql_params + 1] = d
    end
    local profile_rows = db.raw(sql, sql_params)
    for _, row in ipairs(profile_rows or {}) do
      local rec = json.decode(row.record)
      profiles_by_did[row.did] = {
        did = row.did,
        displayName = rec.displayName,
      }
    end
  end

  -- Collect game URIs and IGDB IDs for batch lookup
  local game_uris = {}
  local igdb_ids = {}
  local seen_uris = {}
  local seen_igdb = {}

  for _, item in ipairs(page_items) do
    if (item.type == "like" or item.type == "listAddGame") and item.game_uri and not seen_uris[item.game_uri] then
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
    local actor = profiles_by_did[item.did] or { did = item.did }
    actor["$type"] = "games.gamesgamesgamesgames.defs#communityFeedActorView"

    if item.type == "listCreate" then
      feed[#feed + 1] = {
        type = item.type,
        createdAt = item.created_at,
        actor = actor,
        list = {
          ["$type"] = "games.gamesgamesgamesgames.defs#activityListView",
          uri = item.list_uri,
          name = item.list_name or "Unnamed list",
          createdAt = item.created_at,
        },
      }
    else
      local game_hit = nil
      if item.type == "like" or item.type == "listAddGame" then
        game_hit = hits_by_uri[item.game_uri]
      elseif item.type == "review" then
        game_hit = hits_by_igdb[item.igdb_id]
      end

      if game_hit then
        local entry = {
          type = item.type,
          createdAt = item.created_at,
          actor = actor,
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

        if item.type == "listAddGame" then
          entry.list = {
            ["$type"] = "games.gamesgamesgamesgames.defs#activityListView",
            uri = item.list_uri,
            name = item.list_name or "Unnamed list",
            createdAt = item.created_at,
          }
        end

        feed[#feed + 1] = entry
      end
    end
  end

  local result = { feed = toarray(feed) }
  if page_end < #activities then
    result.cursor = tostring(page_end)
  end
  return result
end
