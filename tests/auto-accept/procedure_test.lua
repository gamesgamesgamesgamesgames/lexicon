-- Standalone tests for src/scripts/games/gamesgamesgamesgames/autoAcceptContributions.lua.
-- Run: lua tests/auto-accept/procedure_test.lua src/scripts/games/gamesgamesgamesgames/autoAcceptContributions.lua
local SCRIPT = arg[1]
local ADMIN, SYNC, HUMAN = "did:plc:admin", "did:plc:sync", "did:plc:human"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local queue = {}

local function call(caller, body)
  local created
  env = { ADMIN_DIDS = ADMIN, AUTO_ACCEPT_DIDS = SYNC .. ", did:plc:other" }
  caller_did = caller
  input = body or {}
  jobs = { create = function(job_type, job_input)
    created = { type = job_type, input = job_input }
    table.insert(queue, { id = "job-" .. (#queue + 1), type = job_type, status = "pending", input = job_input })
    return queue[#queue].id
  end }
  db = { raw = function(sql, b)
    assert(sql:find("status IN %('pending', 'running'%)"), "duplicate check must look at pending and running jobs")
    local by_author = sql:find("input::jsonb->>'author'", 1, true) ~= nil
    for _, j in ipairs(queue) do
      if j.type == "contribution.auto-accept" and (j.status == "pending" or j.status == "running")
        and j.input.sweep == true and (not by_author or (j.input.author or "") == b[1]) then
        return { { id = j.id, status = j.status, started_at = j.started_at } }
      end
    end
    return {}
  end }
  handle = nil
  dofile(SCRIPT)
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin sweep covers every auto-accept account", function()
  queue = {}
  local ok, res, created = call(ADMIN, { limit = 100 })
  assert(ok, res); eq(res.jobId, "job-1"); eq(res.alreadyQueued, false); eq(created.type, "contribution.auto-accept")
  eq(created.input.sweep, true); eq(created.input.author, nil); eq(created.input.limit, 100)
end)

t("an auto-accept account's sweep is pinned to its own contributions", function()
  queue = {}
  local ok, res, created = call(SYNC, { limit = 5000 })
  assert(ok, res); eq(created.input.author, SYNC)
end)

t("an auto-accept account cannot widen its sweep", function()
  queue = {}
  local ok, res, created = call(SYNC, { limit = 10, author = "did:plc:other" })
  assert(ok, res); eq(created.input.author, SYNC)
end)

t("anyone else is refused", function()
  local ok, err, created = call(HUMAN, {})
  eq(ok, false); assert(tostring(err):find("unauthorized"), err); eq(created, nil)
end)

t("limits outside 1-5000 are refused", function()
  queue = {}
  local ok = call(ADMIN, { limit = 0 }); eq(ok, false)
  ok = call(ADMIN, { limit = 5001 }); eq(ok, false)
end)

t("writes and dryRun pass through", function()
  queue = {}
  local ok, res, created = call(SYNC, { writes = "minimal", dryRun = true })
  assert(ok, res); eq(created.input.writes, "minimal"); eq(created.input.dryRun, true)
end)

t("a second sweep for the same account returns the one already queued", function()
  queue = {}
  local ok, first = call(SYNC, {}); assert(ok, first)
  local ok2, second, created = call(SYNC, {}); assert(ok2, second)
  eq(second.jobId, first.jobId); eq(second.alreadyQueued, true); eq(created, nil); eq(#queue, 1)
  eq(second.status, "pending"); eq(second.startedAt, nil, "a pending sweep has not started")
end)

t("a running sweep also blocks a new one; a finished one does not", function()
  queue = {}
  local _, first = call(SYNC, {})
  queue[1].status = "running"; queue[1].started_at = "2026-11-14T00:00:05Z"
  local _, again = call(SYNC, {}); eq(again.alreadyQueued, true)
  eq(again.status, "running"); eq(again.startedAt, "2026-11-14T00:00:05Z")
  queue[1].status = "completed"
  local _, fresh = call(SYNC, {}); eq(fresh.alreadyQueued, false); eq(#queue, 2)
end)

t("one account's sweep does not block another's or the admin's", function()
  queue = {}
  call(SYNC, {})
  local _, admin = call(ADMIN, {}); eq(admin.alreadyQueued, false)
  local _, other = call("did:plc:other", {}); eq(other.alreadyQueued, false)
  eq(#queue, 3)
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
