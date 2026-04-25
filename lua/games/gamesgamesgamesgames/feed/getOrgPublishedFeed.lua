local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local ROLE = "publisher"

function handle()
  local org_uri = params.org
  if not org_uri or org_uri == "" then
    return { error = "InvalidRequest", message = "org is required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local cursor = params.cursor
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  -- Collect org.credit records referencing this org via backlinks
  local all_credits = {}
  local bl_cursor = nil
  repeat
    local bl_opts = {
      collection = "games.gamesgamesgamesgames.org.credit",
      uri = org_uri,
      limit = 100,
    }
    if bl_cursor then
      bl_opts.cursor = bl_cursor
    end
    local backlinks = db.backlinks(bl_opts)
    if backlinks and backlinks.records then
      for _, credit in ipairs(backlinks.records) do
        table.insert(all_credits, credit)
      end
      bl_cursor = backlinks.cursor
    else
      bl_cursor = nil
    end
  until not bl_cursor

  -- Filter credits by role and extract unique game URIs
  local seen = {}
  local game_uris = {}
  for _, credit in ipairs(all_credits) do
    local has_role = false
    if credit.roles then
      for _, r in ipairs(credit.roles) do
        if r == ROLE then
          has_role = true
          break
        end
      end
    end
    if has_role then
      local game_uri = credit.game and credit.game.uri or nil
      if game_uri and not seen[game_uri] then
        seen[game_uri] = true
        table.insert(game_uris, game_uri)
      end
    end
  end

  -- Apply offset-based pagination
  local page_start = offset + 1
  local page_end = offset + limit
  local page_uris = {}

  for i = page_start, math.min(page_end, #game_uris) do
    table.insert(page_uris, game_uris[i])
  end

  if #page_uris == 0 then
    return { feed = toarray({}) }
  end

  -- Batch fetch game data from meilisearch
  local quoted_uris = {}
  for _, uri in ipairs(page_uris) do
    quoted_uris[#quoted_uris + 1] = '"' .. uri .. '"'
  end

  local body = {
    q = "",
    limit = #page_uris,
    filter = "uri IN [" .. table.concat(quoted_uris, ", ") .. "]",
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "applicationType", "summary", "genres", "themes", "releases" })
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

  -- Build feed in order
  local feed = {}
  for _, uri in ipairs(page_uris) do
    local hit = hits_by_uri[uri]
    if hit then
      feed[#feed + 1] = {
        game = {
          uri = hit.uri,
          name = hit.name,
          applicationType = hit.applicationType,
          summary = hit.summary,
          genres = hit.genres,
          themes = hit.themes,
          media = hit.media,
          releases = hit.releases,
          slug = hit.slug,
        }
      }
    end
  end

  local result = { feed = toarray(feed) }
  if page_end < #game_uris then
    result.cursor = tostring(page_end)
  end
  return result
end
