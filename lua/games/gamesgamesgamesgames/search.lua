local SEARCH_URL = env.ALGOLIA_BASE_URL .. "/query"

local SEARCH_HEADERS = {
  ["X-Algolia-Application-Id"] = env.ALGOLIA_APP_ID,
  ["X-Algolia-API-Key"] = env.ALGOLIA_SEARCH_KEY,
  ["content-type"] = "application/json"
}

function find_slug_for(did, coll)
  local slugs = db.query({
    collection = "games.gamesgamesgamesgames.slug",
    did = did,
    limit = 50
  })
  if slugs.records then
    for _, s in ipairs(slugs.records) do
      if s.ref and string.find(s.ref, coll, 1, true) then
        return s.slug
      end
    end
  end
  return nil
end

function find_slug_by_ref(did, target_uri)
  local slugs = db.query({
    collection = "games.gamesgamesgamesgames.slug",
    did = did,
    limit = 50
  })
  if slugs.records then
    for _, s in ipairs(slugs.records) do
      if s.ref == target_uri then
        return s.slug
      end
    end
  end
  return nil
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
      slug = find_slug_by_ref(hit.did, hit.uri)
    }
  end

  if t == "profile" then
    local coll
    if hit.profileType == "actor" then
      coll = "games.gamesgamesgamesgames.actor.profile"
    else
      coll = "games.gamesgamesgamesgames.org.profile"
    end
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#profileSummaryView",
      uri = hit.uri,
      did = hit.did,
      profileType = hit.profileType,
      displayName = hit.displayName,
      slug = find_slug_for(hit.did, coll),
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
      slug = find_slug_by_ref(hit.did, hit.uri)
    }
  end

  if t == "collection" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#collectionSummaryView",
      uri = hit.uri,
      name = hit.name,
      type = hit.collectionType,
      slug = find_slug_by_ref(hit.did, hit.uri)
    }
  end

  if t == "engine" then
    return {
      ["$type"] = "games.gamesgamesgamesgames.defs#engineSummaryView",
      uri = hit.uri,
      name = hit.name,
      slug = find_slug_by_ref(hit.did, hit.uri)
    }
  end

  return nil
end

function handle()
  local q = params.q
  local limit = tonumber(params.limit) or 20
  local page = tonumber(params.cursor) or 0
  local types_set = parse_types(params.types)

  -- Build Algolia facet filters from types param
  local filters = ""
  if types_set then
    local parts = {}
    for t, _ in pairs(types_set) do
      table.insert(parts, "type:" .. t)
    end
    filters = table.concat(parts, " OR ")
  end

  -- Query Algolia
  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode({
      query = q,
      hitsPerPage = limit,
      page = page,
      filters = filters,
      attributesToRetrieve = {"*"}
    })
  })

  local data = json.decode(resp.body)

  -- Map Algolia hits to our view types
  local results = {}
  for _, hit in ipairs(data.hits or {}) do
    local mapped = map_hit(hit)
    if mapped then
      table.insert(results, mapped)
    end
  end

  local response = { results = toarray(results) }
  if data.page < data.nbPages - 1 then
    response.cursor = tostring(data.page + 1)
  end
  return response
end
