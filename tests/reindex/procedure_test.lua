-- Standalone tests for src/scripts/games/gamesgamesgamesgames/reindexCatalogueGames.lua.
-- Run: lua tests/reindex/procedure_test.lua src/scripts/games/gamesgamesgamesgames/reindexCatalogueGames.lua
local SCRIPT = arg[1]
local P = "did:web:pentaract"
local ADMIN, BOT, HUMAN = "did:plc:admin", "did:plc:bot", "did:plc:human"
local G = "at://" .. P .. "/games.gamesgamesgamesgames.game/"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local function call(caller, body, reindex_dids)
  local created
  env = { ADMIN_DIDS = ADMIN .. ", did:plc:admin2", PENTARACT_DID = P, REINDEX_DIDS = reindex_dids }
  caller_did = caller
  input = body
  jobs = { create = function(ty, inp) created = { type = ty, input = inp }; return "job-1" end }
  handle = nil
  dofile(SCRIPT)
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin queues a reindex job", function()
  local ok, res, created = call(ADMIN, { uris = { G .. "a", G .. "b" } })
  assert(ok, res); eq(res.jobId, "job-1"); eq(res.count, 2); eq(created.type, "catalogue.reindex")
  eq(#created.input.uris, 2); eq(created.input.dryRun, false); eq(created.input.delay, nil)
end)

t("dry run and pace are passed on", function()
  local ok, res, created = call(ADMIN, { uris = { G .. "a" }, dryRun = true, perSecond = 4 })
  assert(ok, res); eq(created.input.dryRun, true); eq(created.input.delay, 0.25)
end)

t("anyone else is refused", function()
  local ok, err, created = call(HUMAN, { uris = { G .. "a" } })
  eq(ok, false); assert(tostring(err):find("unauthorized", 1, true), err); eq(created, nil)
end)

t("an account listed in REINDEX_DIDS may queue it", function()
  local ok, res = call(BOT, { uris = { G .. "a" } }, BOT)
  assert(ok, res)
  local ok2 = call(BOT, { uris = { G .. "a" } }, nil)
  eq(ok2, false)
end)

t("rejects URIs that are not catalogue games", function()
  for _, bad in ipairs({ "at://did:plc:else/games.gamesgamesgamesgames.game/a", "at://" .. P .. "/games.gamesgamesgamesgames.contribution/a", G, 42 }) do
    local ok, err, created = call(ADMIN, { uris = { G .. "ok", bad } })
    eq(ok, false, tostring(bad)); assert(tostring(err):find("uris%[2%]"), err); eq(created, nil)
  end
end)

t("needs uris, at most 5000", function()
  eq((call(ADMIN, { uris = {} })), false)
  eq((call(ADMIN, {})), false)
  local many = {}
  for i = 1, 5001 do many[i] = G .. i end
  local ok, err = call(ADMIN, { uris = many })
  eq(ok, false); assert(tostring(err):find("5000", 1, true), err)
  many[5001] = nil
  assert((call(ADMIN, { uris = many })))
end)

t("perSecond must be a whole number from 1 to 5", function()
  for _, bad in ipairs({ 0, 6, 1.5, "2" }) do
    eq((call(ADMIN, { uris = { G .. "a" }, perSecond = bad })), false, tostring(bad))
  end
  assert((call(ADMIN, { uris = { G .. "a" }, perSecond = 5 })))
  assert((call(ADMIN, { uris = { G .. "a" }, perSecond = 1.0 })))
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
