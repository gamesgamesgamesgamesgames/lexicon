-- Canonical Meilisearch document builder for games.
--
-- THIS FILE IS A SOURCE, NOT A HANDLER. `bun run generate:shared` inlines it
-- into every handler that marks a slot for it. Do not edit the copies.
--
-- Why generation: HappyView's Lua cannot `require` one deployed script from
-- another, so the same block has to exist in each file that needs it, and a
-- generator plus a CI check keeps the copies honest.
--
-- `game.lua` writes a game's index document whenever the record changes. The
-- `search.reindex` job has to write the very same document for games whose
-- Meilisearch copy went missing or stale, and a contributionPatch create or
-- delete has to rebuild it from a game record nobody edited, so the builder
-- cannot live in one handler.
--
-- `record` is always what the public should see: callers pass the stored game
-- with its live patches overlaid (overlay_game in src/shared/game_changes.lua).
--
-- Declarations only: no `return`, no `function handle()`. Reads the handler
-- globals `db`, `json`, `env`, `http` and `toarray`.

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

local CANCELLED_DATE_SENTINEL = 10000101
local CANCELLED_STATUSES = { cancelled = true, offline = true }

-- Find the earliest release date and whether the game is cancelled.
local function get_release_info(releases)
  if not releases then return nil, false end
  local earliest = nil
  local has_any = false
  local all_cancelled = true
  for _, rel in ipairs(releases) do
    if rel.releaseDates then
      for _, rd in ipairs(rel.releaseDates) do
        has_any = true
        if not rd.status or not CANCELLED_STATUSES[rd.status] then
          all_cancelled = false
        end
        local val = parse_release_date(rd.releasedAt)
        if val and (not earliest or val < earliest) then
          earliest = val
        end
      end
    end
  end
  local cancelled = has_any and all_cancelled
  if cancelled then
    return CANCELLED_DATE_SENTINEL, true
  end
  return earliest, false
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

-- Rating-to-description mapping for embedder template.
-- Source of truth: docs/superpowers/specs/2026-03-22-semantic-search-design.md
-- meilisearch-backfill.ts carries an older copy. That script is superseded
-- by the search.reindex job and should not be rerun, so its copy is not kept
-- in step.
local RATING_DESCRIPTIONS = {
  ["esrb:RP"] = "ESRB rating pending (not yet rated, North America)",
  ["esrb:EC"] = "Rated ESRB EC for Early Childhood (ages 3+, North America)",
  ["esrb:E"] = "Rated ESRB E for Everyone (ages 0+, North America)",
  ["esrb:E10"] = "Rated ESRB E10+ for Everyone 10+ (ages 10+, North America)",
  ["esrb:T"] = "Rated ESRB T for Teen (ages 13+, North America)",
  ["esrb:M"] = "Rated ESRB M for Mature (ages 17+, North America)",
  ["esrb:AO"] = "Rated ESRB AO for Adults Only (ages 18+, North America)",
  ["pegi:Three"] = "Rated PEGI 3 (ages 3+, Europe)",
  ["pegi:Seven"] = "Rated PEGI 7 (ages 7+, Europe)",
  ["pegi:Twelve"] = "Rated PEGI 12 (ages 12+, Europe)",
  ["pegi:Sixteen"] = "Rated PEGI 16 (ages 16+, Europe)",
  ["pegi:Eighteen"] = "Rated PEGI 18 (ages 18+, Europe)",
  ["cero:A"] = "Rated CERO A for All Ages (ages 0+, Japan)",
  ["cero:B"] = "Rated CERO B (ages 12+, Japan)",
  ["cero:C"] = "Rated CERO C (ages 15+, Japan)",
  ["cero:D"] = "Rated CERO D (ages 17+, Japan)",
  ["cero:Z"] = "Rated CERO Z (ages 18+, Japan)",
  ["usk:0"] = "Rated USK 0 (ages 0+, Germany)",
  ["usk:6"] = "Rated USK 6 (ages 6+, Germany)",
  ["usk:12"] = "Rated USK 12 (ages 12+, Germany)",
  ["usk:16"] = "Rated USK 16 (ages 16+, Germany)",
  ["usk:18"] = "Rated USK 18 (ages 18+, Germany)",
  ["grac:All"] = "Rated GRAC All (ages 0+, South Korea)",
  ["gcrb:All"] = "Rated GRAC All (ages 0+, South Korea)",
  ["grac:Twelve"] = "Rated GRAC 12 (ages 12+, South Korea)",
  ["gcrb:Twelve"] = "Rated GRAC 12 (ages 12+, South Korea)",
  ["grac:Fifteen"] = "Rated GRAC 15 (ages 15+, South Korea)",
  ["gcrb:Fifteen"] = "Rated GRAC 15 (ages 15+, South Korea)",
  ["grac:Eighteen"] = "Rated GRAC 18 (ages 18+, South Korea)",
  ["gcrb:Eighteen"] = "Rated GRAC 18 (ages 18+, South Korea)",
  ["grac:Nineteen"] = "Rated GRAC 19 (ages 19+, South Korea)",
  ["gcrb:Nineteen"] = "Rated GRAC 19 (ages 19+, South Korea)",
  ["classInd:L"] = "Rated ClassInd L for General (ages 0+, Brazil)",
  ["classInd:10"] = "Rated ClassInd 10 (ages 10+, Brazil)",
  ["classInd:12"] = "Rated ClassInd 12 (ages 12+, Brazil)",
  ["classInd:14"] = "Rated ClassInd 14 (ages 14+, Brazil)",
  ["classInd:16"] = "Rated ClassInd 16 (ages 16+, Brazil)",
  ["classInd:18"] = "Rated ClassInd 18 (ages 18+, Brazil)",
  ["acb:G"] = "Rated ACB G for General (ages 0+, Australia)",
  ["acb:PG"] = "Rated ACB PG for Parental Guidance (ages 0+, Australia)",
  ["acb:M"] = "Rated ACB M for Mature (ages 15+, Australia)",
  ["acb:MA15"] = "Rated ACB MA15+ (ages 15+, Australia)",
  ["acb:R18"] = "Rated ACB R18+ (ages 18+, Australia)",
  ["acb:X18"] = "Rated ACB X18+ (ages 18+, Australia)",
}

local function build_age_rating_descriptions(age_rating_strings)
  if not age_rating_strings or #age_rating_strings == 0 then return nil end
  local parts = {}
  for _, key in ipairs(age_rating_strings) do
    local desc = RATING_DESCRIPTIONS[key]
    if desc then
      table.insert(parts, desc)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ". ") .. "."
end

local function derive_release_year(first_release_date)
  if not first_release_date then return nil end
  if first_release_date == CANCELLED_DATE_SENTINEL then return nil end
  return math.floor(first_release_date / 10000)
end

local function derive_release_decade(release_year)
  if not release_year then return nil end
  local decade_start = release_year - (release_year % 10)
  local decade_short
  if decade_start % 100 == 0 then
    -- Century boundary: 2000 -> "2000s", not "0s"
    decade_short = tostring(decade_start)
  else
    decade_short = tostring(decade_start % 100)
  end
  local year_in_decade = release_year % 10
  local position
  if year_in_decade <= 3 then
    position = "early"
  elseif year_in_decade <= 6 then
    position = "mid"
  else
    position = "late"
  end
  return "in the " .. position .. " " .. tostring(decade_start) .. "s (" .. decade_short .. "s)"
end

local GAME_COLLECTION_NSID = "games.gamesgamesgamesgames.collection"

-- Every external ID the record carries, as `<service>Id` document fields. All
-- of them are filterable; igdbId also backs the IGDB lookups.
local STORE_ID_FIELDS = {
  { "igdb", "igdbId" },
  { "steam", "steamId" },
  { "gog", "gogId" },
  { "epicGames", "epicGamesId" },
  { "humbleBundle", "humbleBundleId" },
  { "playStation", "playStationId" },
  { "xbox", "xboxId" },
  { "nintendoEshop", "nintendoEshopId" },
  { "appleAppStore", "appleAppStoreId" },
  { "googlePlay", "googlePlayId" },
}

-- The services written to the external_ids lookup table, in this order.
local EXTERNAL_ID_SERVICES = {
  "igdb", "steam", "gog", "epicGames", "humbleBundle", "playStation",
  "xbox", "nintendoEshop", "appleAppStore", "googlePlay", "twitch",
}

-- Collections that list this game, from the backlinks index. The search
-- collection boost reads this field, so a document without it drops out of
-- the boost.
local function game_collections(target_uri)
  local uris, cursor = {}, nil
  for _ = 1, 20 do
    local page = db.backlinks({ collection = GAME_COLLECTION_NSID, uri = target_uri, limit = 100, cursor = cursor })
    if not page or not page.records then break end
    for _, coll in ipairs(page.records) do
      table.insert(uris, coll.uri)
    end
    cursor = page.cursor
    if not cursor or #page.records < 100 then break end
  end
  return uris
end

-- Upsert the record's external IDs into the external_ids lookup table. A row
-- that already points at this URI is left alone, so a full reindex does not
-- rewrite (and bloat) every row in the table.
local function upsert_external_ids(target_uri, record)
  local ids = record.externalIds
  if type(ids) ~= "table" then return end
  for _, service in ipairs(EXTERNAL_ID_SERVICES) do
    local value = ids[service]
    if value and value ~= "" then
      db.raw(
        "INSERT INTO external_ids (service, external_id, uri) VALUES ($1, $2, $3) ON CONFLICT (service, external_id) DO UPDATE SET uri = $3 WHERE external_ids.uri IS DISTINCT FROM EXCLUDED.uri",
        { service, value, target_uri }
      )
    end
  end
end

-- Official, origin and popularity signals ---------------------------------
--
-- These signals apply to catalogue games only: documents for games from any
-- other repo get officialScore 0, popularityBucket 0 and no origin.
--
-- origin says where a game comes from:
--   fan         fan games, ROM hacks, fan translations, demakes, fan remakes,
--               mods (IGDB type mod), Wikidata mod / fan game classes
--   unofficial  unofficial ports, bootlegs, unlicensed games, clones,
--               forks (IGDB type fork), Wikidata "unlicensed video game"
--   homebrew    homebrew releases
--   official    none of the above, and at least one positive signal: an
--               established publisher, an age rating, or a Wikidata item
-- A game with no signal either way has no origin. applicationType stays
-- IGDB's own type; origin sits beside it.
--
-- officialScore (0 to 4) ranks real releases above fan works that share
-- their names. It is 0 when origin is fan, unofficial or homebrew. Otherwise
-- it starts at 1 and gains a point for each of:
--   * a publisher credit from an organization that publishes at least
--     MIN_PUBLISHED_GAMES catalogue games (fan teams publish one or two);
--   * an age rating (other than ESRB's "rating pending");
--   * a Wikidata item with at least one sitelink or a publisher.
--
-- popularityBucket (0 to 10) is floor(log2(1 + 5 * sitelinks)), from Wikidata
-- sitelinks for now; IGDB rating counts join it later. It is bucketed so the
-- ranking rules after it (application type, then release date) still decide
-- between games of similar popularity.

local CREDIT_NSID = "games.gamesgamesgamesgames.org.credit"
local MIN_PUBLISHED_GAMES = 10

local TYPE_ORIGIN = { mod = "fan", fork = "unofficial" }

local WIKIDATA_ORIGIN = {
  Q865493 = "fan",          -- video game mod
  Q61456428 = "fan",        -- total conversion mod
  Q1395577 = "fan",         -- fan game
  Q123012190 = "unofficial", -- unlicensed video game
}

-- Keywords as IGDB spells them, lowercased. Exact matches, plus the suffix
-- forms IGDB uses for franchise-specific tags ("pokemon fangame",
-- "sonic rom hack", "tetris clone") and the "fan translation - <language>"
-- family. Deliberately absent: "parody" (parodies are often real releases)
-- and "fandisc" (an official product type).
local KEYWORD_ORIGIN = {
  ["fangame"] = "fan", ["fan game"] = "fan", ["fan-game"] = "fan",
  ["fanmade"] = "fan", ["fan made"] = "fan", ["fan-made"] = "fan",
  ["fan remake"] = "fan", ["fan translation"] = "fan",
  ["romhack"] = "fan", ["rom hack"] = "fan",
  ["demake"] = "fan", ["unofficial demake"] = "fan", ["unofficial remake"] = "fan",
  ["unofficial"] = "unofficial", ["unofficial port"] = "unofficial",
  ["bootleg"] = "unofficial", ["unlicensed"] = "unofficial", ["unlicensed game"] = "unofficial",
  ["clone"] = "unofficial",
  ["homebrew"] = "homebrew",
}
local KEYWORD_SUFFIX_ORIGIN = {
  { " fangame", "fan" }, { " fan game", "fan" }, { " rom hack", "fan" },
  { " clone", "unofficial" }, { " homebrew", "homebrew" },
}
local KEYWORD_PREFIX_ORIGIN = {
  { "fan translation", "fan" },
}

-- When signals disagree, the strongest claim wins.
local ORIGIN_RANK = { fan = 3, unofficial = 2, homebrew = 1 }

local function stronger(a, b)
  if not a then return b end
  if not b then return a end
  return ORIGIN_RANK[b] > ORIGIN_RANK[a] and b or a
end

local function keyword_origin(keywords)
  if type(keywords) ~= "table" then return nil end
  local found
  for _, k in ipairs(keywords) do
    local lower = type(k) == "string" and k:lower() or ""
    found = stronger(found, KEYWORD_ORIGIN[lower])
    for _, pair in ipairs(KEYWORD_SUFFIX_ORIGIN) do
      if #lower > #pair[1] and lower:sub(-#pair[1]) == pair[1] then found = stronger(found, pair[2]) end
    end
    for _, pair in ipairs(KEYWORD_PREFIX_ORIGIN) do
      if lower:sub(1, #pair[1]) == pair[1] then found = stronger(found, pair[2]) end
    end
  end
  return found
end

local function has_age_rating(record)
  if type(record.ageRatings) ~= "table" then return false end
  for _, ar in ipairs(record.ageRatings) do
    if ar.organization and ar.rating and not (ar.organization == "esrb" and ar.rating == "RP") then
      return true
    end
  end
  return false
end

-- db.raw for a table a separate DDL step creates. Until the table exists the
-- lookup reports nothing, so this builder can ship before it; any other
-- database error is raised as usual.
local function optional_table_raw(tbl, sql, binds)
  local ok, rows = pcall(db.raw, sql, binds)
  if not ok then
    local msg = tostring(rows)
    if msg:find(tbl, 1, true) and msg:find("does not exist", 1, true) then
      return {}
    end
    error(rows, 0)
  end
  return rows or {}
end

local function did_of_uri(u)
  return type(u) == "string" and u:match("^at://([^/]+)/") or nil
end

-- True when a catalogue publisher credit on this game names an organization
-- that publishes at least MIN_PUBLISHED_GAMES games, per publisher_counts.
local function has_major_publisher(target_uri)
  local orgs, cursor = {}, nil
  for _ = 1, 5 do
    local page = db.backlinks({ collection = CREDIT_NSID, uri = target_uri, limit = 100, cursor = cursor })
    if not page or not page.records then break end
    for _, credit in ipairs(page.records) do
      local org = type(credit.org) == "table" and credit.org.uri
      local game = type(credit.game) == "table" and credit.game.uri
      if org and game == target_uri and did_of_uri(credit.uri) == env.PENTARACT_DID and type(credit.roles) == "table" then
        for _, role in ipairs(credit.roles) do
          if role == "publisher" then table.insert(orgs, org); break end
        end
      end
    end
    cursor = page.cursor
    if not cursor or #page.records < 100 then break end
  end
  if #orgs == 0 then return false end
  local marks, binds = {}, { MIN_PUBLISHED_GAMES }
  for i, org in ipairs(orgs) do marks[i] = "$" .. (i + 1); binds[i + 1] = org end
  local rows = optional_table_raw("publisher_counts",
    "SELECT 1 AS ok FROM publisher_counts WHERE games >= $1 AND org_uri IN (" .. table.concat(marks, ", ") .. ") LIMIT 1",
    binds)
  return #rows > 0
end

-- The game's wikidata_games row, or nil.
local function wikidata_row(record)
  local igdb = type(record.externalIds) == "table" and record.externalIds.igdb
  if not igdb or igdb == "" then return nil end
  local rows = optional_table_raw("wikidata_games",
    "SELECT sitelinks, has_publisher, veto_class FROM wikidata_games WHERE igdb_id = $1 LIMIT 1",
    { tostring(igdb) })
  return rows[1]
end

local function popularity_bucket(sitelinks)
  local n = tonumber(sitelinks) or 0
  if n <= 0 then return 0 end
  return math.min(10, math.floor(math.log(1 + 5 * n, 2)))
end

-- Returns officialScore, popularityBucket, origin (nil when unknown).
local function official_signals(target_uri, target_did, record)
  if not env.PENTARACT_DID or target_did ~= env.PENTARACT_DID then
    return 0, 0, nil
  end
  local wd = wikidata_row(record)
  local popularity = popularity_bucket(wd and wd.sitelinks)
  local origin = stronger(stronger(TYPE_ORIGIN[record.applicationType], keyword_origin(record.keywords)),
    wd and WIKIDATA_ORIGIN[wd.veto_class or ""] or nil)
  if origin then
    return 0, popularity, origin
  end
  local score = 1
  if has_major_publisher(target_uri) then score = score + 1 end
  if has_age_rating(record) then score = score + 1 end
  if wd and ((tonumber(wd.sitelinks) or 0) > 0 or (tonumber(wd.has_publisher) or 0) > 0) then score = score + 1 end
  return score, popularity, score > 1 and "official" or nil
end

-- Build the index document for one game, without writing anything.
--
-- `record` is the game record to index. The builder never looks the record up
-- itself, so callers cannot disagree about which version is being indexed.
local function build_game_doc(target_uri, target_did, record)
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
  local slug_rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 ORDER BY length(slug), slug LIMIT 1", { target_uri })
  if slug_rows and #slug_rows > 0 then
    slug = slug_rows[1].slug
  end

  local first_release_date, cancelled = get_release_info(record.releases)

  local doc = {
    id = to_doc_id(target_uri),
    type = "game",
    did = target_did,
    uri = target_uri,
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
    cancelled = cancelled,
    publishedAt = record.publishedAt,
    firstReleaseDate = first_release_date,
    media = record.media,
    slug = slug,
    collections = toarray(game_collections(target_uri)),
    ageRatings = {}
  }

  doc.officialScore, doc.popularityBucket, doc.origin = official_signals(target_uri, target_did, record)

  if type(record.externalIds) == "table" then
    for _, pair in ipairs(STORE_ID_FIELDS) do
      local value = record.externalIds[pair[1]]
      if value and value ~= "" then
        doc[pair[2]] = value
      end
    end
  end

  -- Flatten age ratings into "organization:rating" strings for filtering
  if record.ageRatings then
    for _, ar in ipairs(record.ageRatings) do
      if ar.organization and ar.rating then
        table.insert(doc.ageRatings, ar.organization .. ":" .. ar.rating)
      end
    end
  end
  doc.ageRatings = toarray(doc.ageRatings)

  -- Enriched fields for embedder template (not searchable/filterable)
  local age_desc = build_age_rating_descriptions(doc.ageRatings)
  if age_desc then
    doc.ageRatingDescriptions = age_desc
  end

  local release_year = derive_release_year(first_release_date)
  if release_year then
    doc.releaseYear = release_year
    doc.releaseDecade = derive_release_decade(release_year)
  end

  return doc
end

-- Meilisearch answers 202 when it has queued the write. Anything else means
-- the document was not queued, so raise: HappyView retries a failed record
-- hook and dead-letters it once the retries run out, where it can be replayed.
local function check_meili(resp, what)
  local status = resp and resp.status or 0
  if status < 200 or status >= 300 then
    local body = resp and resp.body or ""
    error(what .. " failed: Meilisearch answered " .. tostring(status) .. " " .. string.sub(body, 1, 300))
  end
end

-- Send already-built documents to Meilisearch as full replacements.
local function push_game_docs(docs)
  local resp = http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray(docs))
  })
  check_meili(resp, "indexing " .. #docs .. " game document(s)")
end

-- Build and upsert the index document for one game, and refresh its
-- external_ids rows. Returns the document.
local function index_game(target_uri, target_did, record)
  upsert_external_ids(target_uri, record)
  local doc = build_game_doc(target_uri, target_did, record)
  push_game_docs({ doc })
  return doc
end

local function delete_game_index(target_uri)
  local resp = http.delete(INDEX_URL .. "/" .. to_doc_id(target_uri), { headers = HEADERS })
  check_meili(resp, "deleting the index document for " .. target_uri)
end
