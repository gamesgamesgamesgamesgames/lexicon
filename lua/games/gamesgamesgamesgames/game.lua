local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local INDEX_URL = env.MEILISEARCH_URL .. "/indexes/records/documents"

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function to_doc_id(s)
  local out = {}
  local i = 1
  while i <= #s do
    local a, b, c = string.byte(s, i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 65536 + b * 256 + c
    local remaining = #s - i + 1
    table.insert(out, string.sub(b64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
    table.insert(out, string.sub(b64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if remaining >= 2 then table.insert(out, string.sub(b64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)) end
    if remaining >= 3 then table.insert(out, string.sub(b64, n % 64 + 1, n % 64 + 1)) end
    i = i + 3
  end
  return table.concat(out)
end

-- Parse a releasedAt string into a numeric YYYYMMDD value for sorting.
-- Handles formats: "YYYY-MM-DD", "YYYY-MM", "YYYY-Q1".."YYYY-Q4", "YYYY".
-- Returns nil for "TBD" or unparseable values.
local Q_MONTH = { Q1 = 1, Q2 = 4, Q3 = 7, Q4 = 10 }
local function parse_release_date(s)
  if not s or s == "TBD" then return nil end

  -- YYYY-Qn
  local y, q = s:match("^(%d%d%d%d)%-?(Q%d)$")
  if y and Q_MONTH[q] then
    return tonumber(y) * 10000 + Q_MONTH[q] * 100 + 1
  end

  -- YYYY-MM-DD
  local y2, m2, d2 = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y2 then return tonumber(y2) * 10000 + tonumber(m2) * 100 + tonumber(d2) end

  -- YYYY-MM
  local y3, m3 = s:match("^(%d%d%d%d)%-(%d%d)$")
  if y3 then return tonumber(y3) * 10000 + tonumber(m3) * 100 + 1 end

  -- YYYY
  local y4 = s:match("^(%d%d%d%d)$")
  if y4 then return tonumber(y4) * 10000 + 101 end

  return nil
end

-- Find the earliest release date across all platforms/regions.
local function get_first_release_date(releases)
  if not releases then return nil end
  local earliest = nil
  for _, rel in ipairs(releases) do
    if rel.releaseDates then
      for _, rd in ipairs(rel.releaseDates) do
        local val = parse_release_date(rd.releasedAt)
        if val and (not earliest or val < earliest) then
          earliest = val
        end
      end
    end
  end
  return earliest
end

local APP_TYPE_RANK = {
  game = 1, remake = 1, remaster = 1,
  dlc = 2, expansion = 2,
  standaloneExpansion = 3, expandedGame = 3,
  episode = 4, season = 4,
  update = 5,
  port = 6,
  mod = 7,
  fork = 8,
  addon = 9, pack = 9, bundle = 9,
}

function handle()
  if action == "delete" then
    http.delete(INDEX_URL .. "/" .. to_doc_id(uri), { headers = HEADERS })
    return true
  end

  -- Extract just the name strings from alternativeNames objects
  local alt_names = {}
  if record.alternativeNames then
    for _, an in ipairs(record.alternativeNames) do
      if an.name then
        table.insert(alt_names, an.name)
      end
    end
  end

  -- Look up slug from the slugs table
  local slug = nil
  local slug_rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {uri})
  if slug_rows and #slug_rows > 0 then
    slug = slug_rows[1].slug
  end

  local doc = {
    id = to_doc_id(uri),
    type = "game",
    did = did,
    uri = uri,
    name = record.name,
    summary = record.summary,
    storyline = record.storyline,
    keywords = record.keywords,
    genres = record.genres,
    modes = record.modes,
    themes = record.themes,
    playerPerspectives = record.playerPerspectives,
    alternativeNames = alt_names,
    multiplayerModes = record.multiplayerModes,
    applicationType = record.applicationType,
    applicationTypeRank = APP_TYPE_RANK[record.applicationType] or 99,
    publishedAt = record.publishedAt,
    firstReleaseDate = get_first_release_date(record.releases),
    media = record.media,
    slug = slug
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })

  return record
end
