package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/game.lua"

-- The handler is a real script: it declares `function handle()` as a global, so
-- it loads directly rather than through load_shared.
local function run_handler(options)
  local posts, deletes, raw_calls = {}, {}, {}

  local sandbox = {
    action = options.action or "create",
    uri = options.uri,
    did = options.did,
    record = options.record,
    env = { PENTARACT_DID = "did:web:pentaract", MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili" },
    db = {
      raw = function(sql, bind)
        table.insert(raw_calls, { sql = sql, bind = bind })
        if sql:find("contributionPatch", 1, true) then
          return options.patch_rows or {}
        end
        return {}
      end,
    },
    json = { decode = function(value) return value end, encode = function(value) return value end },
    http = {
      post = function(url, request) table.insert(posts, request.body) end,
      delete = function(url) table.insert(deletes, url) end,
    },
    toarray = function(value) return value end,
    log = function() end,
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local returned = sandbox.handle()

  return { posts = posts, deletes = deletes, returned = returned, raw_calls = raw_calls }
end

local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local PATCH_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/1"

t.test("a game with no patches indexes its stored record", function()
  local result = run_handler({
    uri = GAME_URI,
    did = "did:plc:owner",
    record = { name = "Stored", applicationType = "game" },
  })
  t.eq(result.posts[1][1].name, "Stored", "stored name indexed")
end)

t.test("a game with a live patch indexes the overlaid record", function()
  -- The failure this closes: if the handler indexed the stored record, any
  -- unrelated edit to a patched game would silently drop the overlay from
  -- search until the next patch event.
  local result = run_handler({
    uri = GAME_URI,
    did = "did:plc:owner",
    record = { name = "Stored", summary = "Stored summary", applicationType = "game" },
    patch_rows = {
      { uri = PATCH_URI,
        record = { subject = GAME_URI, createdAt = "2026-01-01T00:00:00Z", changes = { name = "Patched" } } },
    },
  })

  t.eq(result.posts[1][1].name, "Patched", "overlay reached the index")
  t.eq(result.posts[1][1].summary, "Stored summary", "unpatched field intact")
end)

t.test("the overlay is never persisted", function()
  -- A record handler's return value replaces what gets stored.
  local stored = { name = "Stored", applicationType = "game" }
  local result = run_handler({
    uri = GAME_URI,
    did = "did:plc:owner",
    record = stored,
    patch_rows = {
      { uri = PATCH_URI,
        record = { subject = GAME_URI, createdAt = "2026-01-01T00:00:00Z", changes = { name = "Patched" } } },
    },
  })

  -- Both halves matter: the first catches indexing and returning the wrong
  -- copy, the second catches an overlay that edited the record in place.
  t.eq(result.returned.name, "Stored", "returned record is the stored one")
  t.truthy(result.returned == stored, "the very table that came in is returned")
  t.eq(stored.name, "Stored", "the incoming record was not mutated")
  -- And the overlay did reach the index, so the assertion above is not passing
  -- because nothing was overlaid at all.
  t.eq(result.posts[1][1].name, "Patched", "the index still got the overlay")
end)

t.test("the patch lookup is scoped to the Pentaract repo", function()
  -- happyview_records indexes the whole network. The db stub returns the same
  -- rows whatever is bound, so only the SQL and its binds can show the filter.
  local result = run_handler({
    uri = GAME_URI,
    did = "did:plc:owner",
    record = { name = "Stored" },
  })

  local patch_call = nil
  for _, call in ipairs(result.raw_calls) do
    if call.sql:find("contributionPatch", 1, true) then
      patch_call = call
    end
  end

  t.truthy(patch_call, "a patch query ran")
  t.truthy(patch_call.sql:find("did = $1", 1, true), "the query filters on did")
  t.eq(patch_call.bind[1], "did:web:pentaract", "bound to the Pentaract DID")
  t.eq(patch_call.bind[2], GAME_URI, "and to this game's uri")
end)

t.test("a delete removes the document and does not abort", function()
  local result = run_handler({ action = "delete", uri = GAME_URI, did = "did:plc:owner" })
  t.eq(#result.deletes, 1, "one delete")
  t.truthy(result.returned, "returned truthy so the delete proceeds")
end)

t.report()
