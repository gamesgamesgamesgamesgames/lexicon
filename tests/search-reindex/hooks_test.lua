-- Standalone tests for the Meilisearch writes in game.lua and collection.lua,
-- and for the reindexSearchGames procedure.
-- Run: lua tests/search-reindex/hooks_test.lua
local F = dofile("tests/search-reindex/fake.lua")
local DIR = "src/scripts/games/gamesgamesgamesgames/"
local GAME = "at://did:web:cat/games.gamesgamesgamesgames.game/oot"
local COLL = "at://did:plc:c/games.gamesgamesgamesgames.collection/zelda"
local OTHER = "at://did:plc:c/games.gamesgamesgamesgames.collection/n64"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local OOT = {
  name = "The Legend of Zelda: Ocarina of Time", applicationType = "game", publishedAt = "2026-03-07T00:00:00Z",
  externalIds = { igdb = "1029", steam = "" },
  releases = { { releaseDates = { { releasedAt = "1998-11-21" } } } },
}

local function hook(script, opts, act, u, rec)
  local S = F.install(opts)
  action, uri, did, record = act, u, u:match("^at://([^/]+)/"), rec
  handle = nil
  dofile(DIR .. script)
  local ok, res = pcall(handle)
  return ok, res, S
end

t("game.lua indexes collections and store ids with the document", function()
  local ok, res, S = hook("game.lua", { backlinks = { [GAME] = { COLL, OTHER } } }, "create", GAME, OOT)
  assert(ok, res)
  local d = S.meili[F.doc_id(GAME)]
  eq(d.type, "game"); eq(d.igdbId, "1029"); eq(d.steamId, nil); eq(#d.collections, 2); eq(d.firstReleaseDate, 19981121)
  eq(S.ext["igdb:1029"], GAME)
end)

t("game.lua raises when Meilisearch refuses the document, so HappyView retries", function()
  local ok, err = hook("game.lua", { fail_writes = 1 }, "create", GAME, OOT)
  eq(ok, false); assert(tostring(err):find("Meilisearch answered 500", 1, true), err)
end)

t("game.lua raises when a delete is refused", function()
  local ok, err = hook("game.lua", { delete_status = 503 }, "delete", GAME, nil)
  eq(ok, false); assert(tostring(err):find("503", 1, true), err)
end)

t("collection.lua merges collections into the game document instead of replacing it", function()
  local id = F.doc_id(GAME)
  local meili = { [id] = { id = id, type = "game", uri = GAME, name = OOT.name } }
  local ok, res, S = hook("collection.lua", { meili = meili, backlinks = { [GAME] = { OTHER } } }, "create", COLL,
    { name = "Zelda", type = "franchise", games = { GAME } })
  assert(ok, res)
  eq(S.puts, 1)
  local d = S.meili[id]
  eq(d.name, OOT.name); eq(d.type, "game"); eq(#d.collections, 2)
end)

t("collection.lua raises when Meilisearch refuses the write", function()
  local ok, err = hook("collection.lua", { fail_writes = 1 }, "create", COLL, { name = "Zelda", games = { GAME } })
  eq(ok, false); assert(tostring(err):find("Meilisearch answered 500", 1, true), err)
end)

-- reindexSearchGames ---------------------------------------------------------

local function call(caller, body, active)
  local created
  env = { ADMIN_DIDS = "did:plc:admin", REINDEX_DIDS = "did:plc:bot" }
  caller_did, input = caller, body
  jobs = { create = function(ty, inp) created = { type = ty, input = inp }; return "job-1" end }
  db = { raw = function(sql)
    assert(sql:find("job_type = 'search.reindex'", 1, true) and sql:find("status IN ('pending', 'running')", 1, true), sql)
    return active or {}
  end }
  handle = nil
  dofile(DIR .. "reindexSearchGames.lua")
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin queues a full dry run", function()
  local ok, res, created = call("did:plc:admin", { dryRun = true, maxGames = 500 })
  assert(ok, res); eq(res.jobId, "job-1"); eq(created.type, "search.reindex")
  eq(created.input.dryRun, true); eq(created.input.maxGames, 500); eq(created.input.uris, nil)
end)

t("a REINDEX_DIDS account may queue a run for listed games", function()
  local ok, res, created = call("did:plc:bot", { uris = { GAME } })
  assert(ok, res); eq(created.input.dryRun, false); eq(#created.input.uris, 1)
end)

t("anyone else is refused", function()
  local ok, err = call("did:plc:human", {})
  eq(ok, false); assert(tostring(err):find("unauthorized", 1, true), err)
end)

t("only game URIs are accepted", function()
  local ok, err = call("did:plc:admin", { uris = { COLL } })
  eq(ok, false); assert(tostring(err):find("is not a game URI", 1, true), err)
end)

t("maxGames must be a positive whole number", function()
  eq((call("did:plc:admin", { maxGames = 0 })), false)
  eq((call("did:plc:admin", { maxGames = 1.5 })), false)
end)

t("a running reindex is reported instead of starting another", function()
  local ok, res, created = call("did:plc:admin", {}, { { id = "job-0", status = "running" } })
  assert(ok, res); eq(res.alreadyQueued, true); eq(res.jobId, "job-0"); eq(created, nil)
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
