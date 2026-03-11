local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

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

  -- Build Meilisearch filter from types and applicationTypes params
  local filter_parts = {}

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

  -- Build search body
  local body = {
    q = q,
    limit = limit,
    offset = offset,
    attributesToRetrieve = toarray({ "*" })
  }
  if filter then body.filter = filter end
  if sort then body.sort = sort end

  -- Pre-search: find collections matching the query.
  -- If we get strong collection matches, we'll boost their member games.
  local boosted_games = {}  -- uri → true
  if q then
    local coll_body = {
      q = q,
      limit = 5,
      filter = 'type = "collection"',
      attributesToRetrieve = toarray({ "uri", "name" })
    }
    local coll_resp = http.post(SEARCH_URL, {
      headers = SEARCH_HEADERS,
      body = json.encode(coll_body)
    })
    local coll_data = json.decode(coll_resp.body)
    local coll_hits = coll_data.hits or {}

    if #coll_hits > 0 then
      -- For each matched collection, look up its games via backlinks
      for _, coll in ipairs(coll_hits) do
        local backlinks = db.backlinks({
          collection = "games.gamesgamesgamesgames.game",
          uri = coll.uri,
          path = "collections",
          limit = 200
        })
        -- Backlinks may not work for this — games don't reference collections.
        -- Instead, load the collection record to get its games array.
        local coll_record = db.get(coll.uri)
        if coll_record and coll_record.games then
          for _, game_uri in ipairs(coll_record.games) do
            boosted_games[game_uri] = true
          end
        end
      end
    end
  end

  -- Query Meilisearch
  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode(body)
  })

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  -- Collection-aware re-ranking: if we found matching collections,
  -- partition games into boosted (in a matching collection) vs others,
  -- sort boosted by recency, then append the rest.
  if #hits > 1 and next(boosted_games) then
    local boosted = {}
    local others = {}

    for _, hit in ipairs(hits) do
      if hit.type == "game" and boosted_games[hit.uri] then
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

  -- Map hits to our view types
  local results = {}
  for _, hit in ipairs(hits) do
    local mapped = map_hit(hit)
    if mapped then
      table.insert(results, mapped)
    end
  end

  local response = { results = toarray(results) }

  -- Meilisearch returns estimatedTotalHits; use offset-based cursor
  local total = data.estimatedTotalHits or 0
  local next_offset = offset + limit
  if next_offset < total then
    response.cursor = tostring(next_offset)
  end

  return response
end
