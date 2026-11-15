-- Gives games with no slug one, and puts the slug on their search document.
-- Queued by backfillGameSlugs.
--
-- Feeds link a game by the slug on its search document, so a game without one
-- links nowhere. Games written straight to a PDS (the IGDB sync, a
-- developer's own repo) never got a slugs row: only procedures assign them.
--
-- For each game the job:
--   1. keeps the slug the game already has, or, for a game in the catalogue
--      repo or a verified developer's repo, assigns one by createGame's
--      generate_slug rule. A slug another game holds gets a numeric suffix
--      (-2, -3, ...); no existing slug is ever changed or repointed.
--   2. reads the game's search document and, if its slug differs, sends just
--      { id, slug } as a partial update (PUT, which merges). Only documents
--      that exist and still have their `type` are touched: a partial write to
--      a missing or gutted document would leave a document with nothing but a
--      slug. Those are counted as notInSearch, with samples, for search.reindex
--      to rebuild from the slugs table.
--
-- Input:
--   uris      optional: only these game URIs (at most 5000). Without it the job
--             walks every game that has no slugs row, in URI order.
--   after     scan position, set by the job when it chains
--   maxGames  optional: stop after this many games across the whole chain
--   dryRun    assign and push nothing; report what would be written. Slugs
--             are chosen as the real run would, except that two slugless games
--             with the same name in different chunks can both be reported
--             with the same slug.
--   delay     seconds to wait between chunks (default 1)
--   totals    running totals, carried from job to job in the chain

local GAME_NSID = "games.gamesgamesgamesgames.game"
local CHUNK = 200
local SAMPLE_CAP = 25
local MAX_SLUG_SUFFIX = 1000

local function meili()
  local url, key = env.MEILISEARCH_URL, env.MEILISEARCH_API_KEY
  if not url or url == "" or not key or key == "" then
    error("MEILISEARCH_URL and MEILISEARCH_API_KEY must be configured")
  end
  return url .. "/indexes/records/documents", {
    ["Authorization"] = "Bearer " .. key,
    ["content-type"] = "application/json",
  }
end

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

local function own_slug(uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 ORDER BY length(slug), slug LIMIT 1", { uri })
  return rows and rows[1] and rows[1].slug or nil
end

local function slug_owner(slug)
  local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", { slug })
  return rows and rows[1] and rows[1].uri or nil
end

-- The slug this game gets. `planned` holds slugs a dry run has already handed
-- out in this job, so two games in one chunk don't get the same answer.
local function choose_slug(uri, name, dry_run, planned)
  local base = generate_slug(name)
  if not base then
    return nil
  end
  local slug, n = base, 1
  while n <= MAX_SLUG_SUFFIX do
    local owner = slug_owner(slug)
    if dry_run then
      if (not owner or owner == uri) and not planned[slug] then
        planned[slug] = true
        return slug
      end
    else
      if not owner then
        db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO NOTHING", { slug, uri })
        owner = slug_owner(slug)
      end
      -- game.lua's index hook assigns by the same rule and may have got here
      -- first; a slug this game already owns is the answer.
      if owner == uri then
        return slug
      end
    end
    n = n + 1
    slug = base .. "-" .. n
  end
  error("no free slug for " .. uri .. " after " .. base .. "-" .. MAX_SLUG_SUFFIX)
end

-- The same eligibility as game.lua's index hook: the catalogue repo, and the
-- repos of developers verified by VERIFIER_DID. Other accounts' games are
-- counted as notEligible and left without a slug. Cached per job.
local function eligibility()
  local cache = {}
  return function(target_did)
    if cache[target_did] ~= nil then
      return cache[target_did]
    end
    local ok = false
    local catalogue = env.PENTARACT_DID
    if catalogue and catalogue ~= "" and target_did == catalogue then
      ok = true
    elseif env.VERIFIER_DID and env.VERIFIER_DID ~= "" and target_did then
      local rows = db.raw(
        "SELECT uri FROM happyview_records WHERE collection = 'dev.cartridge.graph.verification' AND did = $1 AND record::jsonb->>'subject' = $2 LIMIT 1",
        { env.VERIFIER_DID, target_did }
      )
      ok = rows ~= nil and #rows > 0
    end
    cache[target_did] = ok
    return ok
  end
end

-- URIs go into a Meilisearch filter between double quotes.
local function filter_safe(uri)
  return type(uri) == "string" and uri:match("^at://[%w%.:%%_~%-]+/[%w%._~%-]+/[%w%._:~%-]+$") ~= nil
end

local function valid_game_uri(uri)
  return filter_safe(uri) and uri:match("^at://[^/]+/([^/]+)/") == GAME_NSID
end

local function new_totals()
  return {
    counts = {
      assigned = 0, wouldAssign = 0, hadSlug = 0, noName = 0, notEligible = 0, notAGame = 0, invalid = 0,
      pushed = 0, wouldPush = 0, searchCurrent = 0, notInSearch = 0, failed = 0,
    },
    processed = 0,
    samples = { assigned = {}, notInSearch = {}, failed = {} },
  }
end

local function sample(totals, kind, value)
  local list = totals.samples[kind]
  if #list < SAMPLE_CAP then
    table.insert(list, value)
  end
end

local function bump(totals, key)
  totals.counts[key] = totals.counts[key] + 1
end

-- The next chunk of games, as { uri, name } rows, and how far it got.
local function next_chunk(input, budget)
  local limit = math.min(CHUNK, budget)
  if type(input.uris) == "table" then
    local rows = {}
    for i = 1, math.min(#input.uris, limit) do
      local uri = input.uris[i]
      local row = { uri = uri }
      if valid_game_uri(uri) then
        local found = db.raw(
          "SELECT record::jsonb->>'name' AS name FROM happyview_records WHERE uri = $1 AND collection = $2 LIMIT 1",
          { uri, GAME_NSID }
        )
        row.found = found and #found > 0
        row.name = row.found and found[1].name or nil
      else
        row.invalid = true
      end
      table.insert(rows, row)
    end
    return rows
  end
  local rows = db.raw(
    "SELECT r.uri, r.record::jsonb->>'name' AS name FROM happyview_records r " ..
    "WHERE r.collection = $1 AND r.uri > $2 " ..
    "AND NOT EXISTS (SELECT 1 FROM slugs s WHERE s.uri = r.uri) " ..
    "ORDER BY r.uri LIMIT " .. tostring(math.floor(limit)),
    { GAME_NSID, input.after or "" }
  ) or {}
  for _, row in ipairs(rows) do
    row.found = true
  end
  return rows
end

-- Meilisearch's documents for these URIs, keyed by URI. Gutted documents have
-- no `uri`, so they are absent here just like missing ones.
local function fetch_docs(index_url, headers, uris)
  local quoted = {}
  for _, uri in ipairs(uris) do
    table.insert(quoted, '"' .. uri .. '"')
  end
  local resp = http.post(index_url .. "/fetch", {
    headers = headers,
    body = json.encode({
      filter = "uri IN [" .. table.concat(quoted, ", ") .. "]",
      fields = toarray({ "id", "uri", "type", "slug" }),
      limit = #uris + 10,
    }),
  })
  if not resp or resp.status ~= 200 then
    error("fetching search documents failed: " .. tostring(resp and resp.status) .. " " .. tostring(resp and resp.body))
  end
  local body = json.decode(resp.body) or {}
  local by_uri = {}
  for _, doc in ipairs(body.results or {}) do
    if doc.uri then
      by_uri[doc.uri] = doc
    end
  end
  return by_uri
end

local function push_slugs(index_url, headers, updates)
  local resp = http.put(index_url, { headers = headers, body = json.encode(toarray(updates)) })
  if not resp or (resp.status ~= 200 and resp.status ~= 202) then
    error("search update failed: " .. tostring(resp and resp.status) .. " " .. tostring(resp and resp.body))
  end
end

function handle()
  local input = job.input or {}
  local dry_run = input.dryRun == true
  local delay = tonumber(input.delay) or 1
  local totals = type(input.totals) == "table" and input.totals or new_totals()
  local max_games = tonumber(input.maxGames)

  if input.uris ~= nil and (type(input.uris) ~= "table" or #input.uris == 0) then
    error("uris, when given, must be a non-empty list")
  end

  -- Checked first, so a missing config fails the job before anything is written.
  local index_url, headers = meili()

  local budget = CHUNK
  if max_games then
    budget = math.max(0, max_games - totals.processed)
  end
  if budget == 0 or job.should_stop() then
    job.progress(totals)
    return { totals = totals, stopped = budget ~= 0, next = nil }
  end

  local rows = next_chunk(input, budget)
  local planned = {}
  local to_check = {}
  local eligible = eligibility()

  for _, row in ipairs(rows) do
    totals.processed = totals.processed + 1
    if row.invalid then
      bump(totals, "invalid")
      job.warn("skipping " .. tostring(row.uri) .. ": not a game URI")
    elseif not row.found then
      bump(totals, "notAGame")
    else
      local existing = own_slug(row.uri)
      if existing then
        bump(totals, "hadSlug")
        table.insert(to_check, { uri = row.uri, slug = existing })
      elseif not eligible(row.uri:match("^at://([^/]+)/")) then
        bump(totals, "notEligible")
      else
        local ok, slug = pcall(choose_slug, row.uri, row.name, dry_run, planned)
        if not ok then
          bump(totals, "failed")
          sample(totals, "failed", { uri = row.uri, error = tostring(slug) })
          job.warn("failed " .. row.uri .. ": " .. tostring(slug))
        elseif not slug then
          bump(totals, "noName")
        else
          bump(totals, dry_run and "wouldAssign" or "assigned")
          sample(totals, "assigned", { uri = row.uri, name = row.name, slug = slug })
          table.insert(to_check, { uri = row.uri, slug = slug })
        end
      end
    end
  end

  if #to_check > 0 then
    local uris = {}
    for _, item in ipairs(to_check) do
      table.insert(uris, item.uri)
    end
    local docs = fetch_docs(index_url, headers, uris)
    local updates = {}
    for _, item in ipairs(to_check) do
      local doc = docs[item.uri]
      if not doc or not doc.type then
        bump(totals, "notInSearch")
        sample(totals, "notInSearch", item.uri)
      elseif doc.slug == item.slug then
        bump(totals, "searchCurrent")
      elseif dry_run then
        bump(totals, "wouldPush")
      else
        table.insert(updates, { id = doc.id, slug = item.slug })
      end
    end
    if #updates > 0 then
      push_slugs(index_url, headers, updates)
      totals.counts.pushed = totals.counts.pushed + #updates
    end
  end

  -- Chain while there may be more.
  local next_job
  local more
  local next_input = { dryRun = dry_run, delay = delay, totals = totals, maxGames = input.maxGames }
  if type(input.uris) == "table" then
    more = #input.uris > #rows
    if more then
      local rest = {}
      for i = #rows + 1, #input.uris do
        table.insert(rest, input.uris[i])
      end
      next_input.uris = rest
    end
  else
    more = #rows == math.min(CHUNK, budget) and #rows > 0
    next_input.after = rows[#rows] and rows[#rows].uri or input.after
  end
  if more and max_games and totals.processed >= max_games then
    more = false
  end

  local stopped = false
  if more then
    if job.should_stop() then
      stopped = true
    else
      if delay > 0 then
        job.wait(delay)
      end
      next_job = jobs.create("slugs.backfill", next_input)
    end
  end

  job.progress(totals)
  log("slugs.backfill: " .. json.encode(totals.counts) .. (next_job and (" next=" .. next_job) or " done"))
  return { totals = totals, stopped = stopped, next = next_job }
end
