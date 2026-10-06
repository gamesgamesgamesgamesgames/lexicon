-- An owner's refusal of a contribution to their own entity.
--
-- A moderator's approval is a provisional publication: the patch is overlaid on
-- every read path, but the owner has the final say over their own listing. This
-- verb withdraws that overlay and takes the contribution out of the owner's
-- queue, without writing anything to the entity.

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
-- Duplicate exists in: meilisearch-backfill/meilisearch-backfill.ts
local RATING_DESCRIPTIONS = {
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

-- Remove the public overlay for a contribution, if one is live.
--
-- contributionPatch.lua reindexes the subject when the delete reaches the
-- firehose; the index write here means the public read is already correct
-- before that arrives, which matters most for a decline.
local function withdraw_patch(contribution_uri, subject)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = '" .. OVERLAY_PATCH_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  local patch_uri = rows[1].uri

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

  if subject and subject ~= "" then
    local game = db.get(subject)
    if game then
      index_game(subject, did_from_uri(subject), overlay_game(game, subject, patch_uri))
    end
  end

  return patch_uri
end
-- <<< generated from src/shared/contribution_decision.lua

function handle()
  local contribution = load_contribution(input.contribution)
  local subject = contribution.record.subject

  assert_owner_may_decide(contribution.uri, subject)

  -- The decision is written first: if the patch delete fails the contribution
  -- is still out of the queue, which is the state the owner asked for. The
  -- reverse order would leave a withdrawn patch with nothing explaining why.
  local decision_uri = record_owner_decision(contribution, "declined", input.reason)

  withdraw_patch(contribution.uri, subject)

  return { uri = decision_uri }
end
