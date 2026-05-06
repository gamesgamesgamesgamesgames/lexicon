local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"
local MULTI_SEARCH_URL = env.MEILISEARCH_URL .. "/multi-search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

-- Age-to-rating filter mapping. For a given age, all ratings at or below the
-- ceiling are acceptable. Built from the ceiling table in the spec.
-- Source of truth: docs/superpowers/specs/2026-03-22-semantic-search-design.md

-- Ordered list of ratings per org, from youngest to oldest.
local RATING_ORDER = {
  esrb = { "E", "E10", "T", "M", "AO" },
  pegi = { "Three", "Seven", "Twelve", "Sixteen", "Eighteen" },
  cero = { "A", "B", "C", "D", "Z" },
  usk = { "0", "6", "12", "16", "18" },
  grac = { "All", "Twelve", "Fifteen", "Eighteen" },
  gcrb = { "All", "Twelve", "Fifteen", "Eighteen" },
  classInd = { "L", "10", "12", "14", "16", "18" },
  acb = { "G", "PG", "M", "MA15", "R18", "X18" },
}

-- Age thresholds for each rating (the minimum age to access that rating)
local RATING_MIN_AGE = {
  esrb = { E = 0, E10 = 10, T = 13, M = 17, AO = 18 },
  pegi = { Three = 3, Seven = 7, Twelve = 12, Sixteen = 16, Eighteen = 18 },
  cero = { A = 0, B = 12, C = 15, D = 17, Z = 18 },
  usk = { ["0"] = 0, ["6"] = 6, ["12"] = 12, ["16"] = 16, ["18"] = 18 },
  grac = { All = 0, Twelve = 12, Fifteen = 15, Eighteen = 18 },
  gcrb = { All = 0, Twelve = 12, Fifteen = 15, Eighteen = 18 },
  classInd = { L = 0, ["10"] = 10, ["12"] = 12, ["14"] = 14, ["16"] = 16, ["18"] = 18 },
  acb = { G = 0, PG = 0, M = 15, MA15 = 15, R18 = 18, X18 = 18 },
}

-- Given an age, returns all acceptable "org:rating" strings across all orgs.
local function get_acceptable_ratings(age)
  local acceptable = {}
  for org, order in pairs(RATING_ORDER) do
    local min_ages = RATING_MIN_AGE[org]
    for _, rating in ipairs(order) do
      if min_ages[rating] <= age then
        table.insert(acceptable, org .. ":" .. rating)
      end
    end
  end
  return acceptable
end

-- Extract an age hint from the query string. Returns age (number) or nil.
local function extract_age(q)
  -- "14yo", "14 yo", "14y/o", "14 y/o"
  local age = q:match("(%d+)%s*y/?o")
  if age then return tonumber(age) end

  -- "14 year old", "14 years old", "14 year-old"
  age = q:match("(%d+)%s*year")
  if age then return tonumber(age) end

  -- Named age groups
  if q:match("for%s+kids") or q:match("for%s+children") then return 7 end
  if q:match("kid%s*friendly") or q:match("child%s*friendly") then return 7 end
  if q:match("family%s*friendly") then return 10 end
  if q:match("for%s+teens") or q:match("for%s+teenagers") then return 13 end
  if q:match("for%s+adults") then return 18 end

  return nil
end

-- Detect region hints in the query. Returns true if any region term found.
local REGION_PATTERNS = {
  "australia", "australian", "american", "european", "japanese",
  "german", "korean", "brazilian", "japan", "europe", "america",
  "germany", "korea", "brazil"
}

local function has_region_hint(q)
  local lower = q:lower()
  for _, pat in ipairs(REGION_PATTERNS) do
    if lower:find(pat, 1, true) then return true end
  end
  return false
end

-- Compute semantic ratio based on query characteristics
local function compute_semantic_ratio(q, has_age, has_region)
  local word_count = 0
  for _ in q:gmatch("%S+") do
    word_count = word_count + 1
  end

  if word_count >= 6 then return 0.7 end
  if word_count >= 3 or has_age or has_region then return 0.5 end
  return 0.3
end

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
  local age_ratings_set = parse_types(params.ageRatings)
  local include_unrated = params.includeUnrated == true or params.includeUnrated == "true"
  local include_cancelled = params.includeCancelled == true or params.includeCancelled == "true"

  -- Semantic search: extract age/region hints and compute hybrid ratio
  local extracted_age = nil
  local region_hint = false
  local semantic_ratio = 0.3
  if q and q ~= "" then
    extracted_age = extract_age(q)
    region_hint = has_region_hint(q)
    semantic_ratio = compute_semantic_ratio(q, extracted_age ~= nil, region_hint)
  end

  -- Build Meilisearch filter from types and applicationTypes params
  local filter_parts = {}

  if not include_cancelled then
    table.insert(filter_parts, "cancelled != true")
  end

  table.insert(filter_parts, "publishedAt IS NOT NULL")

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

  if age_ratings_set then
    local parts = {}
    for t, _ in pairs(age_ratings_set) do
      table.insert(parts, 'ageRatings = "' .. t .. '"')
    end
    if include_unrated then
      table.insert(parts, "ageRatings IS EMPTY")
    end
    table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
  end

  -- Age filter from heuristic extraction (separate from explicit ageRatings param)
  if extracted_age and not age_ratings_set then
    local acceptable = get_acceptable_ratings(extracted_age)
    if #acceptable > 0 then
      local parts = {}
      for _, ar in ipairs(acceptable) do
        table.insert(parts, 'ageRatings = "' .. ar .. '"')
      end
      -- Include games with no age ratings (they haven't been rated, not necessarily inappropriate)
      table.insert(parts, "ageRatings IS EMPTY")
      table.insert(filter_parts, "(" .. table.concat(parts, " OR ") .. ")")
    end
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
    sort = toarray({ "firstReleaseDate:asc" })
  elseif sort_by == "published_desc" then
    sort = toarray({ "firstReleaseDate:desc" })
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

  -- Hybrid semantic search (only when game results are possible, since the
  -- embedder is configured for game documents only)
  if not types_set or types_set["game"] then
    body.hybrid = {
      semanticRatio = semantic_ratio,
      embedder = "game-similarity"
    }
  end

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

    if multi_resp.status ~= 200 then
      return { error = "MeilisearchError", message = multi_data.message or multi_resp.body }
    end

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

    if resp.status ~= 200 then
      return { error = "MeilisearchError", message = data.message or resp.body }
    end

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
