package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/contributionPatch.lua"
local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local PATCH_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/1"

local function run_handler(options)
  local posts = {}

  local sandbox = {
    action = options.action or "create",
    uri = options.uri or PATCH_URI,
    did = options.did or "did:web:pentaract",
    record = options.record,
    env = { PENTARACT_DID = "did:web:pentaract", MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili" },
    db = {
      backlinks = function() return { records = {} } end,
      get = function(target)
        if target == GAME_URI then return options.game end
        if target == (options.uri or PATCH_URI) then return options.indexed_patch end
        if options.other_subject_uri and target == options.other_subject_uri then
          return options.other_subject
        end
        return nil
      end,
      raw = function(sql)
        if sql:find("contributionPatch", 1, true) then return options.patch_rows or {} end
        return {}
      end,
    },
    json = { decode = function(value) return value end, encode = function(value) return value end },
    http = { post = function(url, request) table.insert(posts, request.body); return { status = 202 } end, delete = function() return { status = 202 } end },
    toarray = function(value) return value end,
    log = function() end,
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local returned = sandbox.handle()
  return { posts = posts, returned = returned }
end

local function live_patch(changes)
  return {
    { uri = PATCH_URI, record = { subject = GAME_URI, createdAt = "2026-01-01T00:00:00Z", changes = changes } },
  }
end

t.test("a new patch reindexes its subject with the overlay applied", function()
  local result = run_handler({
    record = { subject = GAME_URI, changes = { name = "Patched" } },
    game = { name = "Stored", applicationType = "game" },
    patch_rows = live_patch({ name = "Patched" }),
  })

  t.eq(#result.posts, 1, "one index write")
  t.eq(result.posts[1][1].name, "Patched", "overlay in the document")
  t.eq(result.posts[1][1].uri, GAME_URI, "the game's document, not the patch's")
  -- `did` on the document is the repo the record belongs to. The patch lives in
  -- the Pentaract repo, so passing the handler's own `did` through would file the
  -- game under the wrong owner on every reindex.
  t.eq(result.posts[1][1].did, "did:plc:owner", "attributed to the game's owner, not the patch's repo")
end)

t.test("a deleted patch reindexes the subject without it", function()
  -- The handler runs BEFORE the row is removed, so the patch being deleted is
  -- still in the index. Without excluding it the decline would appear to do
  -- nothing until some later event.
  local result = run_handler({
    action = "delete",
    record = nil,
    indexed_patch = { subject = GAME_URI },
    game = { name = "Stored", applicationType = "game" },
    patch_rows = live_patch({ name = "Patched" }),
  })

  t.eq(result.posts[1][1].name, "Stored", "reverted to the stored record")
  t.truthy(result.returned, "returned truthy so the delete proceeds")
end)

t.test("a delete keeps other live patches on the same game", function()
  local result = run_handler({
    action = "delete",
    record = nil,
    indexed_patch = { subject = GAME_URI },
    game = { name = "Stored", summary = "Stored summary", applicationType = "game" },
    patch_rows = {
      { uri = PATCH_URI, record = { subject = GAME_URI, createdAt = "2026-01-01T00:00:00Z", changes = { name = "Going" } } },
      { uri = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/2",
        record = { subject = GAME_URI, createdAt = "2026-01-02T00:00:00Z", changes = { summary = "Staying" } } },
    },
  })

  t.eq(result.posts[1][1].name, "Stored", "deleted patch dropped")
  t.eq(result.posts[1][1].summary, "Staying", "other patch kept")
end)

t.test("a patch in any other repo is ignored", function()
  local result = run_handler({
    did = "did:plc:stranger",
    uri = "at://did:plc:stranger/games.gamesgamesgamesgames.contributionPatch/1",
    record = { subject = GAME_URI, changes = { name = "Forged" } },
    game = { name = "Stored", applicationType = "game" },
  })

  t.eq(#result.posts, 0, "no index write")
  t.truthy(result.returned, "the record is still indexed normally")
end)

t.test("a patch for a newGame contribution has nothing to reindex", function()
  local result = run_handler({ record = { changes = { name = "Brand new" } }, game = nil })
  t.eq(#result.posts, 0, "no subject, no reindex")
end)

t.test("a patch whose subject is not a game is ignored", function()
  -- The subject resolves to a real record, so the collection check is the only
  -- thing that can stop the reindex. Left unresolvable, this test would pass
  -- just as well with no collection check at all.
  local NON_GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.org.profile/self"
  local result = run_handler({
    record = { subject = NON_GAME_URI, changes = {} },
    other_subject_uri = NON_GAME_URI,
    other_subject = { name = "An org" },
  })
  t.eq(#result.posts, 0, "only games are indexed by this builder")
end)

t.report()
