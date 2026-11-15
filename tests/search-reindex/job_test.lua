-- Standalone tests for src/jobs/search.reindex.lua against a stub of the
-- HappyView globals and an in-memory Meilisearch.
-- Run: lua tests/search-reindex/job_test.lua src/jobs/search.reindex.lua
local JOB = arg[1]
local F = dofile("tests/search-reindex/fake.lua")
local G = "games.gamesgamesgamesgames.game"
local C1, C2 = "at://did:plc:c/games.gamesgamesgamesgames.collection/1", "at://did:plc:c/games.gamesgamesgamesgames.collection/2"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local function uri(r) return "at://did:web:cat/" .. G .. "/" .. r end
local function game(name, extra)
  local r = { name = name, applicationType = "game", publishedAt = "2026-03-07T00:00:00Z", externalIds = { igdb = "1029" } }
  for k, v in pairs(extra or {}) do r[k] = v end
  return { did = "did:web:cat", record = r }
end

-- Runs the job. Before running, `prepare(S, build)` may seed Meilisearch;
-- `build(uri)` returns the document the builder makes for that game.
local function run(opts, prepare)
  local S = F.install(opts)
  handle = nil
  dofile(JOB)
  if prepare then
    local src = io.open("src/shared/game_index.lua"):read("a")
    local build_game_doc = assert(load(src .. "\nreturn build_game_doc"))()
    prepare(S, function(u) local g = S.records[u]; return build_game_doc(u, g.did, g.record) end)
  end
  local ok, res = pcall(handle)
  return ok, res, S
end

local function three()
  return {
    [uri("a")] = game("Current"),
    [uri("b")] = game("Missing"),
    [uri("c")] = game("Gutted"),
    [uri("d")] = game("Stale"),
  }
end

local function seed(S, build)
  local a = build(uri("a")); S.meili[a.id] = F.copy(a)
  local c = build(uri("c")); S.meili[c.id] = { id = c.id, collections = { C1 } }
  local d = build(uri("d")); d.name = "Old name"; d.publishedAt = nil; S.meili[d.id] = d
end

t("a dry run sorts games into current, missing, gutted and stale and writes nothing", function()
  local ok, res, S = run({ records = three(), input = { dryRun = true } }, seed)
  assert(ok, res)
  local c = res.totals.counts
  eq(c.current, 1); eq(c.missing, 1); eq(c.gutted, 1); eq(c.stale, 1); eq(c.pushed, 0)
  eq(res.totals.staleFields.name, 1); eq(res.totals.staleFields.publishedAt, 1)
  eq(res.totals.samples.gutted[1], uri("c"))
  eq(S.posts, 0); eq(next(S.ext), nil)
  eq(res.done, true); eq(#S.chained, 0)
end)

t("a real run rewrites missing, gutted and stale documents in full", function()
  local ok, res, S = run({ records = three(), input = {}, backlinks = { [uri("c")] = { C1, C2 } } }, seed)
  assert(ok, res)
  eq(res.totals.counts.pushed, 3); eq(S.posts, 1)
  local c = S.meili[F.doc_id(uri("c"))]
  eq(c.type, "game"); eq(c.name, "Gutted"); eq(c.igdbId, "1029"); eq(#c.collections, 2)
  eq(S.meili[F.doc_id(uri("d"))].name, "Stale")
  eq(S.meili[F.doc_id(uri("b"))].uri, uri("b"))
  eq(S.ext["igdb:1029"] ~= nil, true)
end)

t("a second run finds everything current", function()
  local S0
  local ok, res, S = run({ records = three(), input = {} }, seed)
  assert(ok, res)
  local meili = S.meili
  ok, res, S0 = run({ records = three(), input = { dryRun = true }, meili = meili })
  assert(ok, res)
  eq(res.totals.counts.current, 4); eq(res.totals.counts.stale, 0)
end)

t("collections compare as a set, and empty equals absent", function()
  local ok, res = run({ records = { [uri("a")] = game("A") }, input = { dryRun = true }, backlinks = { [uri("a")] = { C1, C2 } } },
    function(S, build)
      local d = build(uri("a")); d.collections = { C2, C1 }; d.alternativeNames = nil; S.meili[d.id] = d
    end)
  assert(ok, res); eq(res.totals.counts.current, 1)
end)

t("fields only Meilisearch has do not make a document stale", function()
  local ok, res = run({ records = { [uri("a")] = game("A") }, input = { dryRun = true } },
    function(S, build) local d = build(uri("a")); d.country = "JP"; S.meili[d.id] = d end)
  assert(ok, res); eq(res.totals.counts.current, 1)
end)

t("works 1000 games a job and chains from where it stopped, carrying the totals", function()
  local records = {}
  for i = 1, 1050 do records[uri(string.format("g%04d", i))] = game("G" .. i) end
  local ok, res, S = run({ records = records, input = { dryRun = true, delay = 0 } })
  assert(ok, res)
  eq(res.processed, 1000); eq(#S.chained, 1); eq(S.chained[1].type, "search.reindex")
  eq(S.chained[1].input.after, uri("g1000")); eq(S.chained[1].input.dryRun, true)
  eq(S.chained[1].input.totals.counts.missing, 1000)
end)

t("maxGames caps the whole chain", function()
  local records = {}
  for i = 1, 300 do records[uri(string.format("g%03d", i))] = game("G" .. i) end
  local ok, res, S = run({ records = records, input = { dryRun = true, maxGames = 150 } })
  assert(ok, res); eq(res.processed, 150); eq(res.done, true); eq(#S.chained, 0)
end)

t("a uris list checks only those games", function()
  local ok, res, S = run({ records = three(), input = { dryRun = true, uris = { uri("b"), uri("c"), uri("zz"), "at://x/other.collection/1" } } }, seed)
  assert(ok, res)
  eq(res.totals.counts.missing, 1); eq(res.totals.counts.gutted, 1); eq(res.totals.counts.current, 0)
  eq(res.totals.counts.invalid, 1); eq(res.totals.counts.notInIndex, 1); eq(#S.chained, 0)
end)

t("a record that will not decode is skipped as invalid", function()
  local records = three()
  records[uri("e")] = { did = "did:web:cat", raw = "not json" }
  local ok, res = run({ records = records, input = { dryRun = true } }, seed)
  assert(ok, res); eq(res.totals.counts.invalid, 1); eq(res.totals.counts.missing, 1)
end)

t("a failed push is counted, and three in a row stop the job", function()
  local records = {}
  for i = 1, 400 do records[uri(string.format("g%03d", i))] = game("G" .. i) end
  local ok, err, S = run({ records = records, input = { delay = 0 }, fail_writes = 99 })
  eq(ok, false); assert(tostring(err):find("3 failed batches", 1, true), err)
  eq(S.progress.totals.counts.failed, 300); eq(S.progress.totals.counts.pushed, 0); eq(#S.chained, 0)
  eq(S.progress.totals.samples.failed[1], uri("g001")); eq(#S.progress.totals.samples.failed, 25)
end)

t("one failed push is counted and the job carries on", function()
  local records = {}
  for i = 1, 250 do records[uri(string.format("g%03d", i))] = game("G" .. i) end
  local ok, res = run({ records = records, input = { delay = 0 }, fail_writes = 1 })
  assert(ok, res); eq(res.totals.counts.failed, 100); eq(res.totals.counts.pushed, 150)
end)

t("a stop request ends the job without chaining", function()
  local ok, res, S = run({ records = three(), input = { dryRun = true }, stop = true })
  assert(ok, res); eq(res.stopped, true); eq(res.processed, 0); eq(#S.chained, 0)
end)

t("a stale document is replaced in full, dropping fields only Meilisearch had", function()
  local ok, res, S = run({ records = { [uri("a")] = game("New") }, input = {} },
    function(S, build) local d = build(uri("a")); d.name = "Old"; d.country = "JP"; S.meili[d.id] = d end)
  assert(ok, res); eq(res.totals.counts.stale, 1)
  local d = S.meili[F.doc_id(uri("a"))]; eq(d.name, "New"); eq(d.country, nil)
end)

t("a resumed scan starts after the given URI", function()
  local ok, res = run({ records = three(), input = { dryRun = true, after = uri("b") } }, seed)
  assert(ok, res); eq(res.processed, 2); eq(res.totals.counts.gutted, 1); eq(res.totals.counts.stale, 1)
end)

t("totals from an older job without failed samples still work", function()
  local old = { counts = { current = 0, missing = 0, gutted = 0, stale = 0, pushed = 0, failed = 0, invalid = 0, notInIndex = 0 },
    staleFields = {}, samples = { missing = {}, gutted = {}, stale = {} } }
  local ok, res = run({ records = three(), input = { delay = 0, totals = old }, fail_writes = 1 }, seed)
  assert(ok, res); eq(res.totals.samples.failed[1] ~= nil, true)
end)

t("a game with a live patch is compared and pushed with the patch overlaid", function()
  local P = "did:web:cat"
  local patches = {
    { uri = "at://did:web:cat/games.gamesgamesgamesgames.contributionPatch/1", did = P,
      record = { subject = uri("a"), createdAt = "2026-01-01T00:00:00Z", changes = { name = "Patched" } } },
    -- Any other repo's patch is ignored, as on every read path.
    { uri = "at://did:plc:x/games.gamesgamesgamesgames.contributionPatch/1", did = "did:plc:x",
      record = { subject = uri("a"), createdAt = "2026-01-02T00:00:00Z", changes = { name = "Forged" } } },
  }
  local records = { [uri("a")] = game("Stored") }
  local ok, res, S = run({ records = records, input = {}, pentaract_did = P, patches = patches })
  assert(ok, res)
  eq(res.totals.counts.pushed, 1)
  eq(S.meili[F.doc_id(uri("a"))].name, "Patched", "overlay pushed")
  eq(S.patch_queries, 1, "one patch query per batch")

  -- Meilisearch now holds the overlaid document, so a second run must find it
  -- current rather than revert it to the stored name.
  local ok2, res2, S2 = run({ records = records, input = {}, pentaract_did = P, patches = patches, meili = S.meili })
  assert(ok2, res2)
  eq(res2.totals.counts.current, 1); eq(res2.totals.counts.stale, 0); eq(S2.posts, 0)
  eq(S2.meili[F.doc_id(uri("a"))].name, "Patched")
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
