-- Standalone tests for src/scripts/games/gamesgamesgamesgames/autoAcceptContributions.lua.
-- Run: lua tests/auto-accept/procedure_test.lua src/scripts/games/gamesgamesgamesgames/autoAcceptContributions.lua
local SCRIPT = arg[1]
local ADMIN, SYNC, HUMAN = "did:plc:admin", "did:plc:sync", "did:plc:human"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local function call(caller, body)
  local created
  env = { ADMIN_DIDS = ADMIN, AUTO_ACCEPT_DIDS = SYNC .. ", did:plc:other" }
  caller_did = caller
  input = body or {}
  jobs = { create = function(job_type, job_input) created = { type = job_type, input = job_input }; return "job-1" end }
  handle = nil
  dofile(SCRIPT)
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin sweep covers every auto-accept account", function()
  local ok, res, created = call(ADMIN, { limit = 100 })
  assert(ok, res); eq(res.jobId, "job-1"); eq(created.type, "contribution.auto-accept")
  eq(created.input.sweep, true); eq(created.input.author, nil); eq(created.input.limit, 100)
end)

t("an auto-accept account's sweep is pinned to its own contributions", function()
  local ok, res, created = call(SYNC, { limit = 5000 })
  assert(ok, res); eq(created.input.author, SYNC)
end)

t("an auto-accept account cannot widen its sweep", function()
  local ok, res, created = call(SYNC, { limit = 10, author = "did:plc:other" })
  assert(ok, res); eq(created.input.author, SYNC)
end)

t("anyone else is refused", function()
  local ok, err, created = call(HUMAN, {})
  eq(ok, false); assert(tostring(err):find("unauthorized"), err); eq(created, nil)
end)

t("limits outside 1-5000 are refused", function()
  local ok = call(ADMIN, { limit = 0 }); eq(ok, false)
  ok = call(ADMIN, { limit = 5001 }); eq(ok, false)
end)

t("writes and dryRun pass through", function()
  local ok, res, created = call(SYNC, { writes = "minimal", dryRun = true })
  assert(ok, res); eq(created.input.writes, "minimal"); eq(created.input.dryRun, true)
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
