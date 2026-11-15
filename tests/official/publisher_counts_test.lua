-- Standalone tests for the search.publisher-counts job and the
-- refreshPublisherCounts procedure. The SQL itself was checked against
-- Postgres 17; here the database is a stub.
-- Run: lua tests/official/publisher_counts_test.lua
local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local function run_job(dry)
  local sent
  json = { encode = function() return "{}" end }
  log = function() end
  db = { raw = function(sql, b) sent = { sql = sql, binds = b }; return { { publishers = 7, established = 3, changed = 2, removed = 1 } } end }
  job = { input = { dryRun = dry }, progress = function() end }
  env = { PENTARACT_DID = "did:web:cat" }
  handle = nil
  dofile("src/jobs/search.publisher-counts.lua")
  return handle(), sent
end

t("a dry run only reads", function()
  local res, sent = run_job(true)
  eq(res.dryRun, true); eq(res.established, 3); eq(res.removed, 1)
  eq(sent.sql:find("INSERT", 1, true), nil); eq(sent.sql:find("DELETE", 1, true), nil)
  eq(sent.binds[1], "games.gamesgamesgamesgames.org.credit"); eq(sent.binds[2], "did:web:cat")
  assert(sent.sql:find("AND did = $2", 1, true), "counts catalogue credits only")
end)

t("a real run writes only changed counts and removes former publishers", function()
  local res, sent = run_job(false)
  eq(res.changed, 2)
  assert(sent.sql:find("WHERE publisher_counts.games IS DISTINCT FROM EXCLUDED.games", 1, true), "needs the no-op guard")
  assert(sent.sql:find("DELETE FROM publisher_counts", 1, true), "needs the removal")
  assert(sent.sql:find("jsonb_typeof(record::jsonb->'roles') = 'array'", 1, true), "must tolerate non-array roles")
end)

local function call(caller, body, active)
  local created
  env = { ADMIN_DIDS = "did:plc:admin", MAINTENANCE_DIDS = "did:plc:bot", REINDEX_DIDS = "did:plc:reindexer" }
  caller_did, input = caller, body
  jobs = { create = function(ty, inp) created = { type = ty, input = inp }; return "job-1" end }
  db = { raw = function(sql)
    assert(sql:find("job_type = 'search.publisher-counts'", 1, true), sql)
    return active or {}
  end }
  handle = nil
  dofile("src/scripts/games/gamesgamesgamesgames/refreshPublisherCounts.lua")
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin queues a refresh", function()
  local ok, res, created = call("did:plc:admin", { dryRun = true })
  assert(ok, res); eq(created.type, "search.publisher-counts"); eq(created.input.dryRun, true)
end)

t("the MAINTENANCE_DIDS account may queue one; REINDEX_DIDS and anyone else may not", function()
  assert((call("did:plc:bot", {})))
  eq((call("did:plc:reindexer", {})), false)
  local ok, err = call("did:plc:human", {})
  eq(ok, false); assert(tostring(err):find("unauthorized", 1, true), err)
end)

t("a running refresh is reported instead of starting another", function()
  local ok, res, created = call("did:plc:admin", {}, { { id = "job-0", status = "running" } })
  assert(ok, res); eq(res.alreadyQueued, true); eq(created, nil)
end)

t("the job needs PENTARACT_DID", function()
  json = { encode = function() return "{}" end }; log = function() end
  db = { raw = function() error("must not query") end }
  job = { input = {}, progress = function() end }
  env = {}
  handle = nil
  dofile("src/jobs/search.publisher-counts.lua")
  local ok, err = pcall(handle)
  eq(ok, false); assert(tostring(err):find("PENTARACT_DID", 1, true), err)
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
