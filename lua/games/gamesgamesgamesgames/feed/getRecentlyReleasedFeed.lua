local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  -- now() returns ISO 8601 e.g. "2026-03-12T..."
  local y, m, d = now():match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  local today = tonumber(y .. m .. d)

  -- Calculate 7 days ago
  local ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) - 7 })
  local week_ago = tonumber(os.date("%Y%m%d", ts))

  -- Fetch games released in the past 7 days (up to and including today)
  local body = {
    q = "",
    limit = 1000,
    filter = "type = \"game\" AND cancelled != true AND firstReleaseDate >= " .. week_ago .. " AND firstReleaseDate <= " .. today,
    sort = toarray({ "firstReleaseDate:desc" }),
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "firstReleaseDate" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  local data = json.decode(resp.body)

  if resp.status ~= 200 then
    return { error = "MeilisearchError", message = data.message or resp.body }
  end

  local hits = data.hits or {}

  -- Shuffle games within the same release date
  -- Group by date first
  local by_date = {}
  local dates = {}
  for _, hit in ipairs(hits) do
    local d = hit.firstReleaseDate or 0
    if not by_date[d] then
      by_date[d] = {}
      dates[#dates + 1] = d
    end
    by_date[d][#by_date[d] + 1] = hit
  end

  -- Sort dates descending (most recent first)
  table.sort(dates, function(a, b) return a > b end)

  -- Shuffle within each date group, then flatten
  local shuffled = {}
  for _, date in ipairs(dates) do
    local group = by_date[date]
    for i = #group, 2, -1 do
      local j = math.random(i)
      group[i], group[j] = group[j], group[i]
    end
    for _, hit in ipairs(group) do
      shuffled[#shuffled + 1] = hit
    end
  end

  local feed = {}
  for i = 1, math.min(#shuffled, limit) do
    local hit = shuffled[i]
    -- Convert firstReleaseDate integer (20260321) to "2026-03-21"
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
    }
  end

  return { feed = toarray(feed) }
end
