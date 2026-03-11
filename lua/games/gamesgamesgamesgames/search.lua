local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"
local MULTI_SEARCH_URL = env.MEILISEARCH_URL .. "/multi-search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function parse_types(types)
  if not types then return nil end
  if type(types) == "table" then
    if #types == 0 then return nil end
    local set = {}
    for _, t in ipairs(types) do
      set[t] = true
    end
    return set
  end
  if type(types) == "string" and types ~= "" then
    local set = {}
    for t in string.gmatch(types, "[^,]+") do
      set[t:match("^%s*(.-)%s*$")] = true
    end
    return set
  end
  return nil
end

function map_hit(hit)
  local t = hit.type

  if t == "game" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#gameSummaryView",
      uri = hit.uri,
      name = hit.name,
      summary = hit.summary,
      media = hit.media,
      slug = hit.slug,
      applicationType = hit.applicationType,
      firstReleaseDate = hit.firstReleaseDate
    }
  end

  if t == "profile" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#profileSummaryView",
      uri = hit.uri,
      did = hit.did,
      profileType = hit.profileType,
      displayName = hit.displayName,
      avatar = hit.avatar
    }
  end

  if t == "platform" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#platformSummaryView",
      uri = hit.uri,
      name = hit.name,
      abbreviation = hit.abbreviation,
      category = hit.category,
      slug = hit.slug
    }
  end

  if t == "collection" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#collectionSummaryView",
      uri = hit.uri,
      name = hit.name,
      type = hit.collectionType,
      slug = hit.slug
    }
  end

  if t == "engine" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#engineSummaryView",
      uri = hit.uri,
      name = hit.name,
      slug = hit.slug
    }
  end

  return nil
end

function handle()
  local q = params.q
  local limit = tonumber(params.limit) or 20
  local offset = tonumber(params.cursor) or 0
  local types_set = parse_types(params.types)
  local sort_by = params.sort

  local app_types_set = parse_types(params.applicationTypes)
  local genres_set = parse_types(params.genres)
  local themes_set = parse_types(params.themes)
  local modes_set = parse_types(params.modes)
  local perspectives_set = parse_types(params.playerPerspectives)
  local include_cancelled = params.includeCancelled == true or params.includeCancelled == "true"

  -- Build Meilisearch filter from types and applicationTypes params
  local filter_parts = {}

  if not include_cancelled then
    table.insert(filter_parts, "cancelled != true")
  end

  if types_set then
    local parts = {}
    for t, _ in pairs(types_set) do
      table.insert(parts, 'type = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  if app_types_set then
    local parts = {}
    for t, _ in pairs(app_types_set) do
      table.insert(parts, 'applicationType = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  if genres_set then
    local parts = {}
    for t, _ in pairs(genres_set) do
      table.insert(parts, 'genres = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  if themes_set then
    local parts = {}
    for t, _ in pairs(themes_set) do
      table.insert(parts, 'themes = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  if modes_set then
    local parts = {}
    for t, _ in pairs(modes_set) do
      table.insert(parts, 'modes = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  if perspectives_set then
    local parts = {}
    for t, _ in pairs(perspectives_set) do
      table.insert(parts, 'playerPerspectives = "' .. t .. '"')
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  local filter = nil
  if #filter_parts > 0 then
    filter = table.concat(filter_parts, " AND ")
  end

  -- Build sort array
  local sort = nil
  if sort_by == "name_asc" then
    sort = toarray({ "name:asc" })
  elseif sort_by == "name_desc" then
    sort = toarray({ "name:desc" })
  elseif sort_by == "published_asc" then
    sort = toarray({ "publishedAt:asc" })
  elseif sort_by == "published_desc" then
    sort = toarray({ "publishedAt:desc" })
  end

  -- Only the fields map_hit actually uses, plus collections for re-ranking
  local main_fields = toarray({
    "type", "uri", "did", "name", "summary", "media", "slug",
    "applicationType", "firstReleaseDate", "profileType", "displayName",
    "avatar", "abbreviation", "category", "collectionType", "collections"
  })

  -- Build search body
  local body = {
    q = q,
    limit = limit,
    offset = offset,
    attributesToRetrieve = main_fields,
    rankingScoreThreshold = 0.7
  }
  if filter then body.filter = filter end
  if sort then body.sort = sort end

  -- Check if game results are possible (collection boost only matters for games)
  local needs_collection_boost = not types_set or types_set["game"]

  local data, hits, matched_collections

  if needs_collection_boost then
    -- Multi-search: run the main query and a collection query in parallel
    local coll_query = {
      indexUid = "records",
      q = q,
      limit = 5,
      filter = 'type = "collection"',
      attributesToRetrieve = toarray({ "uri" }),
      rankingScoreThreshold = 0.7
    }

    body.indexUid = "records"

    local multi_resp = http.post(MULTI_SEARCH_URL, {
      headers = SEARCH_HEADERS,
      body = json.encode({ queries = toarray({ body, coll_query }) })
    })

    local multi_data = json.decode(multi_resp.body)
    local results_list = multi_data.results or {}

    data = results_list[1] or {}
    hits = data.hits or {}

    -- Build set of matched collection URIs
    matched_collections = {}
    local coll_data = results_list[2] or {}
    local coll_hits = coll_data.hits or {}
    for _, coll in ipairs(coll_hits) do
      matched_collections[coll.uri] = true
    end
  else
    -- Single search — no collection boost needed
    local resp = http.post(SEARCH_URL, {
      headers = SEARCH_HEADERS,
      body = json.encode(body)
    })
    data = json.decode(resp.body)
    hits = data.hits or {}
    matched_collections = {}
  end

  -- Collection-aware re-ranking: if we found matching collections,
  -- check each game's `collections` array (already on the Meilisearch doc)
  -- to see if it belongs to a matched collection. Boost those games by
  -- sorting them by recency, then append the rest.
  if #hits > 1 and next(matched_collections) then
    local boosted = {}
    local others = {}

    for _, hit in ipairs(hits) do
      local is_boosted = false
      if hit.type == "game" and hit.collections then
        for _, c in ipairs(hit.collections) do
          if matched_collections[c] then
            is_boosted = true
            break
          end
        end
      end

      if is_boosted then
        table.insert(boosted, hit)
      else
        table.insert(others, hit)
      end
    end

    if #boosted > 0 then
      -- Sort boosted games by firstReleaseDate descending (newest first)
      table.sort(boosted, function(a, b)
        local a_date = a.firstReleaseDate or 0
        local b_date = b.firstReleaseDate or 0
        return a_date > b_date
      end)

      -- Reassemble: boosted by recency, then others
      hits = {}
      for _, s in ipairs(boosted) do
        table.insert(hits, s)
      end
      for _, o in ipairs(others) do
        table.insert(hits, o)
      end
    end
  end

  -- Map hits to our view types, deduplicating by URI
  local results = {}
  local seen_uris = {}
  for _, hit in ipairs(hits) do
    if not seen_uris[hit.uri] then
      seen_uris[hit.uri] = true
      local mapped = map_hit(hit)
      if mapped then
        table.insert(results, mapped)
      end
    end
  end

  local total = data.estimatedTotalHits or 0
  local response = {
    results = toarray(results),
    totalResults = total
  }

  -- Offset-based cursor for pagination
  local next_offset = offset + limit
  if next_offset < total then
    response.cursor = tostring(next_offset)
  end

  return response
end
