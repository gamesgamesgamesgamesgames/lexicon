local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local function get_like_counts(uris)
  if #uris == 0 then return {} end

  local placeholders = {}
  local query_params = {"games.gamesgamesgamesgames.graph.like"}
  for i, uri in ipairs(uris) do
    placeholders[i] = "$" .. (i + 1)
    query_params[i + 1] = uri
  end

  local query = "SELECT record::jsonb->>'subject' AS subject, COUNT(*) AS count FROM records WHERE collection = $1 AND record::jsonb->>'subject' IN (" .. table.concat(placeholders, ",") .. ") GROUP BY record::jsonb->>'subject'"

  local result = db.raw(query, query_params)
  local counts = {}
  if result then
    for _, row in ipairs(result) do
      counts[row.subject] = tonumber(row.count) or 0
    end
  end
  return counts
end

function handle()
  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local shuffle = params.shuffle == true or params.shuffle == "true"

  -- Use client-provided now (YYYYMMDD) if available, otherwise fall back to UTC
  local current_date
  if params.now and params.now:match("^%d%d%d%d%d%d%d%d$") then
    current_date = tonumber(params.now)
  else
    local y, m, d = now():match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    current_date = tonumber(y .. m .. d)
  end

  local app_type_filter = "applicationType IN [\"dlc\", \"episode\", \"expansion\", \"game\", \"remake\", \"remaster\", \"season\", \"standaloneExpansion\"]"

  if shuffle then
    -- Shuffled mode: fetch releases in the next 7 days, shuffle, trim to limit
    local y = math.floor(current_date / 10000)
    local m = math.floor((current_date % 10000) / 100)
    local d = current_date % 100
    local ts = os.time({ year = y, month = m, day = d + 7 })
    local next_week = os.date("%Y%m%d", ts)

    local body = {
      q = "",
      limit = 1000,
      filter = "type = \"game\" AND cancelled != true AND publishedAt IS NOT NULL AND firstReleaseDate > " .. current_date .. " AND firstReleaseDate <= " .. next_week .. " AND " .. app_type_filter,
      sort = toarray({ "firstReleaseDate:asc" }),
      attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "firstReleaseDate", "genres", "applicationType" })
    }

    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    local data = json.decode(resp.body)

    if resp.status ~= 200 then
      return { error = "MeilisearchError", message = data.message or resp.body }
    end

    local hits = data.hits or {}

    -- Fisher-Yates shuffle
    for i = #hits, 2, -1 do
      local j = math.random(i)
      hits[i], hits[j] = hits[j], hits[i]
    end

    local trimmed = math.min(#hits, limit)
    local uris = {}
    for i = 1, trimmed do
      uris[i] = hits[i].uri
    end
    local like_counts = get_like_counts(uris)

    local feed = {}
    for i = 1, trimmed do
      local hit = hits[i]
      local release_date_str = nil
      if hit.firstReleaseDate then
        local ds = tostring(hit.firstReleaseDate)
        release_date_str = ds:sub(1, 4) .. "-" .. ds:sub(5, 6) .. "-" .. ds:sub(7, 8)
      end

      feed[#feed + 1] = {
        uri = hit.uri,
        name = hit.name,
        slug = hit.slug,
        media = hit.media,
        firstReleaseDate = release_date_str,
        genres = hit.genres or toarray({}),
        applicationType = hit.applicationType,
        likeCount = like_counts[hit.uri] or 0,
      }
    end

    return { feed = toarray(feed) }
  end

  -- Chronological mode: all upcoming releases sorted by date, with cursor pagination
  local offset = 0
  if params.cursor then offset = tonumber(params.cursor) or 0 end

  local from_date = current_date
  if params["from"] and params["from"]:match("^%d%d%d%d%d%d%d%d$") then
    from_date = tonumber(params["from"])
  end

  local to_clause = ""
  if params["to"] and params["to"]:match("^%d%d%d%d%d%d%d%d$") then
    to_clause = " AND firstReleaseDate <= " .. tonumber(params["to"])
  end

  local body = {
    q = "",
    limit = limit + 1,
    offset = offset,
    filter = "type = \"game\" AND cancelled != true AND publishedAt IS NOT NULL AND firstReleaseDate > " .. from_date .. to_clause .. " AND " .. app_type_filter,
    sort = toarray({ "firstReleaseDate:asc" }),
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "firstReleaseDate", "genres", "applicationType" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits = data.hits or {}
  local has_more = #hits > limit
  local trimmed = math.min(#hits, limit)

  local uris = {}
  for i = 1, trimmed do
    uris[i] = hits[i].uri
  end
  local like_counts = get_like_counts(uris)

  local feed = {}
  for i = 1, trimmed do
    local hit = hits[i]
    local release_date_str = nil
    if hit.firstReleaseDate then
      local ds = tostring(hit.firstReleaseDate)
      release_date_str = ds:sub(1, 4) .. "-" .. ds:sub(5, 6) .. "-" .. ds:sub(7, 8)
    end

    feed[#feed + 1] = {
      uri = hit.uri,
      name = hit.name,
      slug = hit.slug,
      media = hit.media,
      firstReleaseDate = release_date_str,
      genres = hit.genres or toarray({}),
      applicationType = hit.applicationType,
      likeCount = like_counts[hit.uri] or 0,
    }
  end

  local result = { feed = toarray(feed) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
