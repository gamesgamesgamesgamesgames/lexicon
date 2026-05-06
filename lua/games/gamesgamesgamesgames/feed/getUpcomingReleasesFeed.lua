local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  -- Use client-provided now (YYYYMMDD) if available, otherwise fall back to UTC
  local current_date
  if params.now and params.now:match("^%d%d%d%d%d%d%d%d$") then
    current_date = tonumber(params.now)
  else
    local y, m, d = now():match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    current_date = tonumber(y .. m .. d)
  end

  -- Calculate one week from now
  local y = math.floor(current_date / 10000)
  local m = math.floor((current_date % 10000) / 100)
  local d = current_date % 100
  local ts = os.time({ year = y, month = m, day = d + 7 })
  local next_week = os.date("%Y%m%d", ts)

  -- Fetch all releases in the next 7 days, then shuffle and trim to limit
  local body = {
    q = "",
    limit = 1000,
    filter = "type = \"game\" AND cancelled != true AND publishedAt IS NOT NULL AND firstReleaseDate > " .. current_date .. " AND firstReleaseDate <= " .. next_week,
    sort = toarray({ "firstReleaseDate:asc" }),
    attributesToRetrieve = toarray({ "uri", "name", "slug", "media", "firstReleaseDate" })
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

  local feed = {}
  for i = 1, math.min(#hits, limit) do
    local hit = hits[i]
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
