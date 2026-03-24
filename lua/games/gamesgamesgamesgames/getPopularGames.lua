local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  -- Scan game_popularity (small) and look up URIs via external_ids index table
  local rows = db.raw(
    "SELECT eid.uri FROM game_popularity gp JOIN external_ids eid ON eid.service = 'steam' AND eid.external_id = gp.steam_id ORDER BY gp.ccu DESC LIMIT $1",
    { limit }
  )

  if not rows or #rows == 0 then
    return { games = toarray({}) }
  end

  -- Collect URIs for batch Meilisearch lookup
  local uris = {}
  for _, row in ipairs(rows) do
    uris[#uris + 1] = '"' .. row.uri .. '"'
  end

  -- Batch fetch game data from Meilisearch
  local body = {
    q = "",
    limit = #uris,
    filter = "uri IN [" .. table.concat(uris, ", ") .. "]",
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "applicationType" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  -- Index hits by URI for ordered lookup
  local hits_by_uri = {}
  for _, hit in ipairs(data.hits or {}) do
    hits_by_uri[hit.uri] = hit
  end

  -- Build games list in popularity order (matching SQL ORDER BY ccu DESC)
  local games = {}
  for _, row in ipairs(rows) do
    local hit = hits_by_uri[row.uri]
    if hit then
      games[#games + 1] = {
        uri = hit.uri,
        name = hit.name,
        slug = hit.slug,
        media = hit.media,
        applicationType = hit.applicationType,
      }
    end
  end

  return { games = toarray(games) }
end
