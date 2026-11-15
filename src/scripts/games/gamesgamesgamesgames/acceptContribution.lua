-- An owner's acceptance of a contribution to their own entity: the changes are
-- merged permanently into the record in their repo.
--
-- The input is the contribution, not a patch, because an owner may act before
-- any moderator has — reviewContribution only creates a patch on approval, so
-- requiring one meant an owner had nothing to act on until a moderator went
-- first.
--
-- The Pentaract branch is unchanged in spirit: a game in the shared repo has no
-- owner, so an admin accepts on its behalf through the linked-repo grant.

local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

-- >>> generated from src/shared/game_index.lua — do not edit
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
--   unofficial  unofficial ports, bootlegs, unlicensed games, forks (IGDB
--               type fork), Wikidata "unlicensed video game"
--   homebrew    homebrew releases
--   official    none of the above, and at least one positive signal: an
--               established publisher, an age rating, or a Wikidata item
-- A game with no signal either way has no origin. applicationType stays
-- IGDB's own type; origin sits beside it.
--
-- The IGDB type (mod, fork) and Wikidata's class are taken as given. Keywords
-- are weaker: IGDB uses some as genre or theme tags on commercial games
-- (a "bootleg" Prohibition story, a homebrew-style retro game with a real
-- publisher). So a keyword sets origin only when the game has no positive
-- signal: no age rating other than "rating pending", and no established
-- publisher.
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
-- "sonic rom hack") and the "fan translation - <language>" family.
-- Deliberately absent: "parody" (parodies are often real releases),
-- "fandisc" (an official product type), and "clone" / "<x> clone" (a genre
-- tag on commercial games, such as "doom clone", and a sci-fi theme).
local KEYWORD_ORIGIN = {
  ["fangame"] = "fan", ["fan game"] = "fan", ["fan-game"] = "fan",
  ["fanmade"] = "fan", ["fan made"] = "fan", ["fan-made"] = "fan",
  ["fan remake"] = "fan", ["fan translation"] = "fan",
  ["romhack"] = "fan", ["rom hack"] = "fan",
  ["demake"] = "fan", ["unofficial demake"] = "fan", ["unofficial remake"] = "fan",
  ["unofficial"] = "unofficial", ["unofficial port"] = "unofficial",
  ["bootleg"] = "unofficial", ["unlicensed"] = "unofficial", ["unlicensed game"] = "unofficial",
  ["homebrew"] = "homebrew",
}
local KEYWORD_SUFFIX_ORIGIN = {
  { " fangame", "fan" }, { " fan game", "fan" }, { " rom hack", "fan" },
  { " homebrew", "homebrew" },
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

  -- The IGDB type and Wikidata's class are absolute.
  local absolute = stronger(TYPE_ORIGIN[record.applicationType], wd and WIKIDATA_ORIGIN[wd.veto_class or ""] or nil)
  if absolute then
    return 0, popularity, absolute
  end

  local publisher = has_major_publisher(target_uri)
  local rated = has_age_rating(record)

  -- Keywords count only for a game with no positive signal.
  if not publisher and not rated then
    local from_keywords = keyword_origin(record.keywords)
    if from_keywords then
      return 0, popularity, from_keywords
    end
  end

  local score = 1
  if publisher then score = score + 1 end
  if rated then score = score + 1 end
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
-- <<< generated from src/shared/game_index.lua

-- >>> generated from src/shared/game_changes.lua — do not edit
-- Canonical merge logic for game contributions.
--
-- THIS FILE IS A SOURCE, NOT A HANDLER. `bun run generate:shared` inlines it
-- into every handler that marks a slot for it. Do not edit the copies.
--
-- Why generation: HappyView resolves `require` to built-in Rust modules and
-- installed library plugins only, so one deployed script cannot load another.
-- A library plugin would turn each call into an async JSON dispatch, which is
-- the wrong cost for a pure function on the index-write and getGame paths. The
-- same block therefore has to exist in several files, and a generator plus a CI
-- check is what keeps the copies honest.
--
-- To stay inlineable this file contains declarations only: no `return`, no
-- `function handle()`. It may read the handler globals `db`, `json` and `env`.

-- `changes` is an unknown-typed blob, and linked-repo writes are not validated
-- against the game lexicon, so only these fields may be copied onto a game.
local GAME_FIELDS = {
  "name", "summary", "applicationType", "genres", "modes", "themes",
  "playerPerspectives", "releases", "media", "parent", "storyline", "keywords",
  "websites", "videos", "alternativeNames", "timeToBeat", "ageRatings",
  "languageSupports", "multiplayerModes", "engines", "externalIds",
  "description", "descriptionFacets", "systemRequirements", "platformFeatures",
}

local PATCH_COLLECTION = "games.gamesgamesgamesgames.contributionPatch"

-- Whole-field replace, in place. Only a missing key means "no change": an empty
-- string is an edit that clears the field.
--
-- A table-valued field is assigned, not copied, so the result shares that table
-- with whatever owned `changes`. Safe as things stand: overlay_game deep-copies
-- its argument, the sharing runs changes->output and never output->argument, and
-- load_patches_by_subject decodes fresh tables per call. It stops being safe the
-- moment anything caches or reuses patches across records — if you add that,
-- copy on assignment here in the same change.
local function apply_changes(record, changes)
  for _, field in ipairs(GAME_FIELDS) do
    if changes[field] ~= nil then
      record[field] = changes[field]
    end
  end
  return record
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- Oldest first, so the newest patch wins per field. `uri` breaks ties, because
-- two patches written in the same second would otherwise sort unpredictably and
-- the public would see one version while the owner committed another.
local function order_patches(patches)
  table.sort(patches, function(a, b)
    local a_at, b_at = a.createdAt or "", b.createdAt or ""
    if a_at == b_at then
      return (a.uri or "") < (b.uri or "")
    end
    return a_at < b_at
  end)
  return patches
end

-- Whole-field replace means concurrent patches overwrite rather than conflict.
-- Patches on disjoint fields compose; patches on the same field resolve by
-- order. No conflict detection and no blocking, deliberately.
local function apply_patches(record, patches)
  for _, patch in ipairs(order_patches(patches)) do
    apply_changes(record, patch.changes or {})
  end
  return record
end

-- Live patches for the given game URIs, grouped by subject.
--
-- `did = PENTARACT_DID` is a security filter, not an optimisation.
-- happyview_records indexes every subscribed collection across the whole
-- network, so any account can publish a contributionPatch naming someone
-- else's game. Only a patch in the Pentaract repo was written by a moderator,
-- and only those may reach a public read.
local function load_patches_by_subject(uris)
  local by_subject = {}

  if not uris or #uris == 0 then
    return by_subject
  end

  -- Fail closed. An unconfigured instance overlays nothing rather than
  -- overlaying whatever the network happens to have published.
  local pentaract_did = env.PENTARACT_DID
  if not pentaract_did or pentaract_did == "" then
    return by_subject
  end

  local bind = { pentaract_did }
  local placeholders = {}
  for _, uri in ipairs(uris) do
    table.insert(bind, uri)
    table.insert(placeholders, "$" .. #bind)
  end

  local rows = db.raw(
    "SELECT uri, record FROM happyview_records " ..
    "WHERE collection = '" .. PATCH_COLLECTION .. "' AND did = $1 " ..
    "AND record::jsonb->>'subject' IN (" .. table.concat(placeholders, ", ") .. ")",
    bind
  )

  for _, row in ipairs(rows or {}) do
    local patch = json.decode(row.record)
    if patch and patch.subject then
      local list = by_subject[patch.subject]
      if not list then
        list = {}
        by_subject[patch.subject] = list
      end
      table.insert(list, {
        uri = row.uri,
        createdAt = patch.createdAt,
        changes = patch.changes,
      })
    end
  end

  return by_subject
end

-- The public view of one game: the stored record with every live patch applied.
--
-- Always a copy. A record handler's return value replaces what gets stored, so
-- an in-place overlay would write the provisional version into the index row
-- and the owner's decision would no longer mean anything.
--
-- `exclude_patch_uri` covers the reindex that happens while a patch is being
-- deleted: the record handler runs before the row goes away.
local function overlay_game(record, uri, exclude_patch_uri)
  local overlaid = deep_copy(record)
  local patches = load_patches_by_subject({ uri })[uri]

  if not patches then
    return overlaid
  end

  if exclude_patch_uri then
    local kept = {}
    for _, patch in ipairs(patches) do
      if patch.uri ~= exclude_patch_uri then
        table.insert(kept, patch)
      end
    end
    patches = kept
  end

  return apply_patches(overlaid, patches)
end
-- <<< generated from src/shared/game_changes.lua

-- >>> generated from src/shared/contribution_decision.lua — do not edit
-- Canonical owner-decision writes, shared by acceptContribution and
-- declineContribution.
--
-- THIS FILE IS A SOURCE, NOT A HANDLER. `bun run generate:shared` inlines it
-- into every handler that marks a slot for it. Do not edit the copies.
--
-- Slot order matters: this block calls `index_game` (src/shared/game_index.lua)
-- and `overlay_game` (src/shared/game_changes.lua), so both of those slots must
-- appear above it in a handler.
--
-- Declarations only: no `return`, no `function handle()`. Reads the handler
-- globals `db`, `json`, `env`, `now`, `log`, `caller_did`, `Record` and
-- `linked_repos`.

local OWNER_DECISION_COLLECTION = "games.gamesgamesgamesgames.contributionOwnerDecision"
local CONTRIBUTION_COLLECTION = "games.gamesgamesgamesgames.contribution"
local REVIEW_COLLECTION = "games.gamesgamesgamesgames.contributionReview"
local OVERLAY_PATCH_COLLECTION = "games.gamesgamesgamesgames.contributionPatch"

local function did_from_uri(target_uri)
  return target_uri:match("^at://([^/]+)/")
end

-- Patches live in the Pentaract repo, not the caller's, so touching them needs
-- a linked-repo grant over that account. HappyView can only write to a repo it
-- holds a session for.
local function pentaract_repo()
  local did = env.PENTARACT_DID
  if not did or did == "" then
    error("PENTARACT_DID is not configured")
  end
  local repo = linked_repos.get(did)
  if not repo then
    error("no linked repo grant for " .. did .. " — an admin must link that account")
  end
  return repo
end

local function load_contribution(contribution_uri)
  if not contribution_uri or contribution_uri == "" then
    error("contribution URI is required")
  end

  local rows = db.raw(
    "SELECT uri, cid, record FROM happyview_records " ..
    "WHERE uri = $1 AND collection = '" .. CONTRIBUTION_COLLECTION .. "' LIMIT 1",
    { contribution_uri }
  )

  if not rows or #rows == 0 then
    error("contribution not found: " .. contribution_uri)
  end

  return {
    uri = rows[1].uri,
    cid = rows[1].cid,
    record = json.decode(rows[1].record),
  }
end

-- The moderator's verdict, or nil if nobody has looked at it.
--
-- `did = PENTARACT_DID` is a security filter: reviews are only authoritative
-- from the Pentaract repo, and happyview_records holds the whole network.
local function moderator_status(contribution_uri)
  local rows = db.raw(
    "SELECT record FROM happyview_records WHERE collection = '" .. REVIEW_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  return json.decode(rows[1].record).status
end

-- The owner's own decision on this contribution, if they have made one.
--
-- `did = owner_did` is the same security filter: a decision is only the owner's
-- if it is in the owner's repo. Without it, anyone could publish a
-- contributionOwnerDecision naming someone else's contribution and lock that
-- owner out of deciding it.
local function existing_owner_decision(contribution_uri, owner_did)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = '" .. OWNER_DECISION_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { owner_did, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  return rows[1].uri
end

-- The three ways an owner's decision can be out of order, refused with the
-- reason rather than silently ignored.
local function assert_owner_may_decide(contribution_uri, subject)
  if not subject or subject == "" then
    error("a newGame contribution has no owner to decide it")
  end

  if did_from_uri(subject) ~= caller_did then
    error("unauthorized: you do not own the subject entity")
  end

  local decided = existing_owner_decision(contribution_uri, caller_did)
  if decided then
    error("you have already decided this contribution: " .. decided)
  end

  -- An owner may act before any moderator has, or after an approval. A denial
  -- or a revision request puts the ball elsewhere.
  local status = moderator_status(contribution_uri)
  if status and status ~= "approved" then
    error("this contribution is not available to decide: a moderator marked it " .. status)
  end
end

-- A reason is stored trimmed, or omitted when it is blank.
--
-- `type(reason) == "string"` rather than a bare `reason`: HappyView parses a
-- procedure's input schema but never enforces it, so a caller can send a number
-- here and `:match` would raise. Trimming on store as well as for the blankness
-- test keeps the two consistent — deciding on the trimmed value and storing the
-- padded one reads as a bug later.
local function clean_reason(reason)
  if type(reason) ~= "string" then
    return nil
  end

  local trimmed = reason:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local function record_owner_decision(contribution, status, reason)
  local decision = Record.new(OWNER_DECISION_COLLECTION, {
    contribution = { uri = contribution.uri, cid = contribution.cid },
    subject = contribution.record.subject,
    status = status,
    reason = clean_reason(reason),
    createdAt = now(),
  })
  decision:save()
  return decision._uri
end

-- The live overlay patch for a contribution, or nil. Same `did` filter as the
-- overlay itself: only a patch in the Pentaract repo is public.
local function live_patch(contribution_uri)
  local rows = db.raw(
    "SELECT uri, record FROM happyview_records WHERE collection = '" .. OVERLAY_PATCH_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  local patch = json.decode(rows[1].record) or {}
  return { uri = rows[1].uri, changes = patch.changes }
end

-- Remove the public overlay for a contribution, if one is live.
--
-- contributionPatch.lua reindexes the subject when the delete reaches the
-- firehose; the index write here means the public read is already correct
-- before that arrives, which matters most for a decline.
local function withdraw_patch(contribution_uri, subject)
  local patch = live_patch(contribution_uri)

  if not patch then
    return nil
  end

  local patch_uri = patch.uri

  local ok, err = pcall(function()
    pentaract_repo():delete_record({
      collection = OVERLAY_PATCH_COLLECTION,
      rkey = patch_uri:match("/([^/]+)$"),
    })
  end)
  if not ok then
    log("warning: failed to delete contributionPatch from the Pentaract repo: " .. tostring(err))
  end

  -- Drop it from the index regardless: the decision has been made and the
  -- patch must not resurface even if the PDS delete failed.
  pcall(function()
    db.raw("DELETE FROM happyview_records WHERE uri = $1", { patch_uri })
  end)

  -- The decision and any merge are already committed, so a failed reindex must
  -- not fail the call: the owner would see an error for something that
  -- happened, and a retry would be refused as already decided. The
  -- contributionPatch hook reindexes again when the delete reaches the
  -- firehose, and that one raises so HappyView retries it.
  if subject and subject ~= "" then
    local reindexed, reindex_err = pcall(function()
      local game = db.get(subject)
      if game then
        index_game(subject, did_from_uri(subject), overlay_game(game, subject, patch_uri))
      end
    end)
    if not reindexed then
      log("warning: withdrew " .. patch_uri .. " but could not reindex " .. subject .. ": " .. tostring(reindex_err))
    end
  end

  return patch_uri
end
-- <<< generated from src/shared/contribution_decision.lua

local GAME_COLLECTION = "games.gamesgamesgamesgames.game"

-- Accented Latin letters, grouped by the plain letter each one decomposes to
-- (its Unicode NFD form without the combining marks). Slugs fold them the
-- way the sync's old slugify did: "Löwenzahn" becomes "lowenzahn". The last
-- lines are letters with no decomposition, spelled out: "Straße" becomes
-- "strasse", "Łódź" becomes "lodz".
local ACCENT_FOLD = {}
for letter, accented in ([[
a ÀÁÂÃÄÅàáâãäåĀāĂăĄąǍǎǞǟǠǡǺǻȀȁȂȃȦȧḀḁẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặ
b ḂḃḄḅḆḇ
c ÇçĆćĈĉĊċČčḈḉ
d ĎďḊḋḌḍḎḏḐḑḒḓ
e ÈÉÊËèéêëĒēĔĕĖėĘęĚěȄȅȆȇȨȩḔḕḖḗḘḙḚḛḜḝẸẹẺẻẼẽẾếỀềỂểỄễỆệ
f Ḟḟ
g ĜĝĞğĠġĢģǦǧǴǵḠḡ
h ĤĥȞȟḢḣḤḥḦḧḨḩḪḫẖ
i ÌÍÎÏìíîïĨĩĪīĬĭĮįİǏǐȈȉȊȋḬḭḮḯỈỉỊị
j Ĵĵǰ
k ĶķǨǩḰḱḲḳḴḵ
l ĹĺĻļĽľḶḷḸḹḺḻḼḽ
m ḾḿṀṁṂṃ
n ÑñŃńŅņŇňǸǹṄṅṆṇṈṉṊṋ
o ÒÓÔÕÖòóôõöŌōŎŏŐőƠơǑǒǪǫǬǭȌȍȎȏȪȫȬȭȮȯȰȱṌṍṎṏṐṑṒṓỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợ
p ṔṕṖṗ
r ŔŕŖŗŘřȐȑȒȓṘṙṚṛṜṝṞṟ
s ŚśŜŝŞşŠšȘșṠṡṢṣṤṥṦṧṨṩ
t ŢţŤťȚțṪṫṬṭṮṯṰṱẗ
u ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲųƯưǓǔǕǖǗǘǙǚǛǜȔȕȖȗṲṳṴṵṶṷṸṹṺṻỤụỦủỨứỪừỬửỮữỰự
v ṼṽṾṿ
w ŴŵẀẁẂẃẄẅẆẇẈẉẘ
x ẊẋẌẍ
y ÝýÿŶŷŸȲȳẎẏẙỲỳỴỵỶỷỸỹ
z ŹźŻżŽžẐẑẒẓẔẕ
ae Ææ
d Đđ
l Łł
o Øø
oe Œœ
ss ß
th Þþ
]]):gmatch("(%a+) (%S+)") do
  for ch in accented:gmatch("[\xC2-\xF4][\x80-\xBF]*") do
    ACCENT_FOLD[ch] = letter
  end
end

-- Same rules as createGame's generate_slug.
local function generate_slug(str)
  if not str or str == "" then
    return nil
  end

  local slug = (str:gsub("[\xC2-\xF4][\x80-\xBF]*", ACCENT_FOLD)):lower()
  slug = slug:gsub("[^%w%s%-]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")

  if slug == "" then
    return nil
  end

  return slug
end

-- createGame lets its caller take over a slug that is already in use. A
-- community-submitted game must not repoint another game's slug, so a taken
-- slug gets a numeric suffix instead.
local function assign_slug(name, target_uri)
  local base = generate_slug(name)
  if not base then
    return
  end

  local slug, n = base, 1
  while true do
    local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", { slug })
    if not rows or #rows == 0 then
      break
    end
    -- game.lua's index hook assigns the same slug by the same rule, and may
    -- have got there first.
    if rows[1].uri == target_uri then
      return
    end
    n = n + 1
    slug = base .. "-" .. n
  end

  db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO NOTHING", { slug, target_uri })
end

-- Older clients send the patch rather than the contribution. Only a patch in
-- the Pentaract repo is resolved: any account can publish one naming any
-- contribution.
local function contribution_uri_from_input()
  if type(input.contribution) == "string" and input.contribution ~= "" then
    return input.contribution
  end

  if type(input.contributionPatch) == "string" and input.contributionPatch ~= "" then
    local rows = db.raw(
      "SELECT record FROM happyview_records WHERE uri = $1 AND did = $2 " ..
      "AND collection = 'games.gamesgamesgamesgames.contributionPatch' LIMIT 1",
      { input.contributionPatch, env.PENTARACT_DID }
    )
    if not rows or #rows == 0 then
      error("contributionPatch not found: " .. input.contributionPatch)
    end
    local patch = json.decode(rows[1].record) or {}
    local ref = patch.contribution or {}
    if type(ref.uri) ~= "string" or ref.uri == "" then
      error("contributionPatch names no contribution: " .. input.contributionPatch)
    end
    return ref.uri
  end

  return nil
end

function handle()
  local contribution = load_contribution(contribution_uri_from_input())
  local subject_uri = contribution.record.subject

  -- Where a moderator-approved patch is live, commit the patch's changes: that
  -- is what the public and the owner have been seeing. The contribution record
  -- lives in the contributor's repo and can be edited after the approval.
  local patch = live_patch(contribution.uri)
  local changes = (patch and patch.changes) or contribution.record.changes or {}
  local is_new_game = (subject_uri == nil or subject_uri == "")
  local entity_uri

  -- A new game and a game in the Pentaract repo have no owner to accept
  -- anything, so an admin does, through the linked-repo grant.
  local via_pentaract = is_new_game or did_from_uri(subject_uri) == env.PENTARACT_DID

  if via_pentaract then
    if not ADMIN_DIDS[caller_did] then
      error("unauthorized: only admins can accept contributions to games in the Pentaract repo")
    end

    local pentaract = pentaract_repo()

    if is_new_game then
      if not changes.name or changes.name == "" then
        error("newGame contribution must include a name in changes")
      end
      if not changes.applicationType or changes.applicationType == "" then
        error("newGame contribution must include an applicationType in changes")
      end

      local game = apply_changes({ ["$type"] = GAME_COLLECTION, createdAt = now() }, changes)
      entity_uri = pentaract:create_record({
        collection = GAME_COLLECTION,
        record = game,
      }).uri

      -- The game exists now, so a slug failure must not fail the acceptance:
      -- retrying would create the game a second time.
      local slug_ok, slug_err = pcall(assign_slug, changes.name, entity_uri)
      if not slug_ok then
        log("warning: failed to assign a slug to " .. entity_uri .. ": " .. tostring(slug_err))
      end
    else
      if subject_uri:match("^at://[^/]+/([^/]+)/") ~= GAME_COLLECTION then
        error("only game contributions can be applied to the Pentaract repo: " .. subject_uri)
      end

      local rows = db.raw(
        "SELECT cid, record FROM happyview_records WHERE uri = $1 LIMIT 1",
        { subject_uri }
      )
      if not rows or #rows == 0 then
        error("subject entity not found: " .. subject_uri)
      end

      local game = apply_changes(json.decode(rows[1].record), changes)
      game["$type"] = GAME_COLLECTION
      pentaract:put_record({
        collection = GAME_COLLECTION,
        rkey = subject_uri:match("/([^/]+)$"),
        record = game,
        swap_cid = rows[1].cid,
      })
      entity_uri = subject_uri
    end
  else
    assert_owner_may_decide(contribution.uri, subject_uri)

    local entity = Record.load(subject_uri)
    if not entity then
      error("subject entity not found: " .. subject_uri)
    end

    -- The same merge the overlay uses, from the same generated source: what the
    -- public has been seeing is exactly what gets committed.
    apply_changes(entity, changes)
    entity:save()
    entity_uri = entity._uri

    -- The merge above is the acceptance; the decision record only takes the
    -- contribution out of the queues. A session granted before
    -- contributionOwnerDecision joined the permission set cannot write it, and
    -- failing here would leave the change merged with the patch still live.
    local decided, decide_err = pcall(record_owner_decision, contribution, "accepted", nil)
    if not decided then
      log("warning: accepted " .. contribution.uri .. " but could not record the owner decision: " .. tostring(decide_err))
    end
  end

  -- Update contributionVerification: set acceptedBy to "both"
  local verification_rows = db.raw(
    "SELECT uri, record FROM happyview_records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution.uri }
  )

  if verification_rows and #verification_rows > 0 then
    local verification_uri = verification_rows[1].uri
    local verification = json.decode(verification_rows[1].record)
    verification["$type"] = "games.gamesgamesgamesgames.contributionVerification"
    -- Only an owner's acceptance counts towards ownerAccepted; an admin
    -- accepting on the Pentaract repo's behalf leaves it as a mod acceptance.
    if not via_pentaract then
      verification.acceptedBy = "both"
    end
    if is_new_game then
      verification.subject = entity_uri
    end

    pentaract_repo():put_record({
      collection = "games.gamesgamesgamesgames.contributionVerification",
      rkey = verification_uri:match("/([^/]+)$"),
      record = verification,
    })
  end

  -- The changes are in the record now, so the overlay has nothing left to add.
  withdraw_patch(contribution.uri, (not is_new_game) and subject_uri or nil)

  return { uri = entity_uri }
end
