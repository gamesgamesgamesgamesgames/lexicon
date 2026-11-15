package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/declineContribution.lua"

local OWNER = "did:plc:owner"
local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local CONTRIBUTION_URI = "at://did:plc:contributor/games.gamesgamesgamesgames.contribution/1"
local PATCH_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/1"

-- A live patch, as happyview_records still holds it while the decline runs: the
-- local DELETE and the firehose delete both land after the reindex. `changes`
-- differs from the stored game so the index document says which version the
-- reindex used.
local LIVE_PATCH = {
  uri = PATCH_URI,
  record = {
    subject = GAME_URI,
    changes = { name = "Patched" },
    createdAt = "2026-09-30T00:00:00Z",
  },
}

local function run_handler(options)
  options = options or {}
  local state = {
    saved = {}, deleted_records = {}, deleted_rows = {}, posts = {},
    repo_writes = {}, sequence = {},
  }

  local sandbox = {
    caller_did = options.caller_did or OWNER,
    input = options.input or { contribution = CONTRIBUTION_URI },
    env = { PENTARACT_DID = "did:web:pentaract", MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili" },
    db = {
      backlinks = function() return { records = {} } end,
      raw = function(sql, bind)
        if sql:find("contributionReview", 1, true) then return options.review_rows or {} end
        if sql:find("contributionOwnerDecision", 1, true) then return options.decision_rows or {} end
        if sql:find("contributionPatch", 1, true) then return options.patch_rows or {} end
        if sql:find("DELETE FROM happyview_records", 1, true) then
          table.insert(state.deleted_rows, bind and bind[1])
          return {}
        end
        if sql:find("FROM slugs", 1, true) then return {} end
        if sql:find("'games.gamesgamesgamesgames.contribution'", 1, true) then
          return options.contribution_rows
            or { { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI, changes = { name = "Proposed" } } } }
        end
        return {}
      end,
      get = function(target) if target == GAME_URI then return options.game or { name = "Stored", applicationType = "game" } end return nil end,
    },
    json = { decode = function(value) return value end, encode = function(value) return value end },
    now = function() return "2026-10-01T00:00:00Z" end,
    log = function() end,
    toarray = function(value) return value end,
    http = { post = function(_, request) table.insert(state.posts, request.body); return { status = 202 } end, delete = function() return { status = 202 } end },
    Record = {
      new = function(collection, data)
        local saved = { collection = collection, data = data, _uri = "at://" .. OWNER .. "/" .. collection .. "/new" }
        saved.save = function()
          table.insert(state.saved, saved)
          table.insert(state.sequence, "decision")
        end
        return saved
      end,
    },
    linked_repos = {
      get = function()
        return {
          delete_record = function(_, request)
            table.insert(state.deleted_records, request)
            table.insert(state.sequence, "withdraw")
          end,
          -- Stubbed so a write through the grant is a failed assertion rather
          -- than a missing-method error that reads like a harness problem.
          create_record = function(_, request)
            table.insert(state.repo_writes, request)
            return { uri = "at://did:web:pentaract/" .. tostring(request.collection) .. "/new", cid = "bafy2" }
          end,
          put_record = function(_, request) table.insert(state.repo_writes, request) end,
        }
      end,
    },
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local result = sandbox.handle()
  return result, state
end

t.test("declining writes the decision to the owner's repo", function()
  local result, state = run_handler()
  t.eq(#state.saved, 1, "one decision")
  t.eq(state.saved[1].collection, "games.gamesgamesgamesgames.contributionOwnerDecision", "collection")
  t.eq(state.saved[1].data.status, "declined", "status")
  t.eq(state.saved[1].data.subject, GAME_URI, "subject")
  t.eq(state.saved[1].data.contribution.cid, "bafy1", "strong ref")
  t.truthy(result.uri, "returns the decision uri")
end)

t.test("declining withdraws a live patch and reverts the index", function()
  local _, state = run_handler({ patch_rows = { LIVE_PATCH } })
  t.eq(#state.deleted_records, 1, "patch deleted from the Pentaract repo")
  t.eq(state.deleted_records[1].collection, "games.gamesgamesgamesgames.contributionPatch", "collection")
  t.eq(state.deleted_records[1].rkey, "1", "rkey")
  t.eq(state.deleted_rows[1], PATCH_URI, "patch dropped from the index")
  t.eq(#state.posts, 1, "subject reindexed")
  -- The patch row is still readable here, so this is only "Stored" if the
  -- reindex excluded the patch it just withdrew.
  t.eq(state.posts[1][1].name, "Stored", "index shows the stored record again")
end)

t.test("the decision is written before the patch is withdrawn", function()
  -- A failure part-way must leave the contribution out of the queue rather than
  -- a withdrawn patch with nothing explaining why.
  local _, state = run_handler({ patch_rows = { LIVE_PATCH } })
  t.eq(state.sequence[1], "decision", "decision first")
  t.eq(state.sequence[2], "withdraw", "withdrawal second")
end)

t.test("declining an unreviewed contribution needs no patch", function()
  local _, state = run_handler()
  t.eq(#state.deleted_records, 0, "nothing to withdraw")
  t.eq(#state.posts, 0, "nothing to reindex")
  t.eq(#state.saved, 1, "the decision is still recorded")
end)

t.test("a non-owner cannot decline", function()
  t.raises(
    function() run_handler({ caller_did = "did:plc:stranger" }) end,
    "you do not own the subject entity",
    "authz"
  )
end)

t.test("the record is never modified by a decline", function()
  -- A decline removes the overlay. It must not write to the game.
  local _, state = run_handler({ patch_rows = { LIVE_PATCH } })
  for _, saved in ipairs(state.saved) do
    t.falsy(
      saved.collection == "games.gamesgamesgamesgames.game",
      "no game record written"
    )
  end
  t.eq(#state.repo_writes, 0, "nothing written through the Pentaract grant either")
end)

t.test("a missing contribution is reported, not ignored", function()
  t.raises(function() run_handler({ contribution_rows = {} }) end, "contribution not found", "missing")
end)

t.test("a contribution a moderator closed cannot be declined", function()
  t.raises(
    function() run_handler({ review_rows = { { record = { status = "denied" } } } }) end,
    "a moderator marked it denied",
    "denied"
  )
end)

t.test("declining twice is refused", function()
  t.raises(
    function() run_handler({ decision_rows = { { uri = "at://did:plc:owner/games.gamesgamesgamesgames.contributionOwnerDecision/1" } } }) end,
    "already decided",
    "idempotence"
  )
end)

t.test("a reason is carried onto the decision", function()
  local _, state = run_handler({ input = { contribution = CONTRIBUTION_URI, reason = "Wrong release date" } })
  t.eq(state.saved[1].data.reason, "Wrong release date", "reason stored")
end)

t.report()
