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
      slug = hit.slug
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

  -- Query Meilisearch
  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode(body)
  })

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  -- Collection-aware re-ranking: if the top game result is an exact name
  -- match, find all games sharing a collection and sort them by recency
  -- (the exact match is included in the sort, not pinned to the top).
  if #hits > 1 and q then
    local query_lower = string.lower(q)
    local top = hits[1]

    if top.type == "game" and top.name and string.lower(top.name) == query_lower then
      -- Build a set of the exact match's collections
      local top_collections = {}
      local has_collections = false
      if top.collections then
        for _, c in ipairs(top.collections) do
          top_collections[c] = true
          has_collections = true
        end
      end

      if has_collections then
        -- Partition: siblings (share a collection, including the exact match) vs others
        local siblings = {}
        local others = {}

        for i = 1, #hits do
          local hit = hits[i]
          local is_sibling = false

          if hit.type == "game" and hit.collections then
            for _, c in ipairs(hit.collections) do
              if top_collections[c] then
                is_sibling = true
                break
              end
            end
          end

          if is_sibling then
            table.insert(siblings, hit)
          else
            table.insert(others, hit)
          end
        end

        -- Sort siblings by firstReleaseDate descending (newest first)
        if #siblings > 1 then
          table.sort(siblings, function(a, b)
            local a_date = a.firstReleaseDate or 0
            local b_date = b.firstReleaseDate or 0
            return a_date > b_date
          end)

          -- Reassemble: siblings by recency, then others
          hits = {}
          for _, s in ipairs(siblings) do
            table.insert(hits, s)
          end
          for _, o in ipairs(others) do
            table.insert(hits, o)
          end
        end
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
