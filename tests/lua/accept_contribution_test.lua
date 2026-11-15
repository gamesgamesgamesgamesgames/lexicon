package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/acceptContribution.lua"

local OWNER = "did:plc:owner"
local ADMIN = "did:plc:admin"
local PENTARACT = "did:web:pentaract"
local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local PENTARACT_GAME_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.game/9"
local CONTRIBUTION_URI = "at://did:plc:contributor/games.gamesgamesgamesgames.contribution/1"
local PATCH_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/1"

local function run_handler(options)
  options = options or {}
  local state = { saved = {}, entity_saves = {}, deleted_records = {}, put_records = {}, posts = {} }

  local entity = options.entity or { name = "Stored", summary = "Stored summary" }
  entity._uri = options.subject or GAME_URI
  entity.save = function(self) table.insert(state.entity_saves, self) end

  local sandbox = {
    caller_did = options.caller_did or OWNER,
    input = options.input or { contribution = CONTRIBUTION_URI },
    env = { PENTARACT_DID = PENTARACT, ADMIN_DIDS = ADMIN, MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili" },
    db = {
      raw = function(sql, bind)
        if sql:find("contributionReview", 1, true) then return options.review_rows or {} end
        if sql:find("contributionOwnerDecision", 1, true) then return options.decision_rows or {} end
        if sql:find("contributionVerification", 1, true) then
          state.verification_query = { sql = sql, bind = bind }
          return options.verification_rows or {}
        end
        if sql:find("contributionPatch", 1, true) then return options.patch_rows or {} end
        if sql:find("DELETE FROM happyview_records", 1, true) then return {} end
        if sql:find("FROM slugs", 1, true) then return {} end
        if sql:find("'games.gamesgamesgamesgames.contribution'", 1, true) then
          return options.contribution_rows
            or { { uri = CONTRIBUTION_URI, cid = "bafy1",
                   record = { subject = options.subject or GAME_URI, changes = options.changes or { name = "Proposed" } } } }
        end
        -- The Pentaract branch reads the stored game straight out of the index
        -- rather than through Record.load, because it writes through the grant.
        if sql:find("SELECT cid, record FROM happyview_records", 1, true) then
          return options.subject_rows
            or { { cid = "bafygame", record = options.game or { name = "Stored", applicationType = "game" } } }
        end
        return options.generic_rows or {}
      end,
      get = function(target)
        if target == (options.subject or GAME_URI) then return options.game or { name = "Stored", applicationType = "game" } end
        return nil
      end,
    },
    json = { decode = function(value) return value end, encode = function(value) return value end },
    now = function() return "2026-10-01T00:00:00Z" end,
    log = function(message) state.logs = state.logs or {}; table.insert(state.logs, message) end,
    toarray = function(value) return value end,
    http = { post = function(_, request) table.insert(state.posts, request.body) end, delete = function() end },
    Record = {
      new = function(collection, data)
        local saved = { collection = collection, data = data, _uri = "at://" .. OWNER .. "/" .. collection .. "/new" }
        saved.save = function()
          if options.decision_save_fails and collection == "games.gamesgamesgamesgames.contributionOwnerDecision" then
            error("ScopeMissing: repo:games.gamesgamesgamesgames.contributionOwnerDecision")
          end
          table.insert(state.saved, saved)
        end
        return saved
      end,
      load = function(target) return entity end,
    },
    linked_repos = {
      get = function()
        return {
          did = PENTARACT,
          delete_record = function(_, request) table.insert(state.deleted_records, request) end,
          put_record = function(_, request) table.insert(state.put_records, request) end,
          create_record = function(_, request)
            table.insert(state.put_records, request)
            return { uri = PENTARACT_GAME_URI, cid = "bafynew" }
          end,
        }
      end,
    },
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local result = sandbox.handle()
  return result, state, entity
end

t.test("an owner accepting merges the changes into their record", function()
  local result, state, entity = run_handler({ changes = { name = "Proposed", summary = "" } })

  t.eq(entity.name, "Proposed", "allowlisted field merged")
  t.eq(entity.summary, "", "an empty string clears the field")
  t.eq(#state.entity_saves, 1, "the record was saved once")
  t.eq(result.uri, GAME_URI, "returns the entity uri")
end)

t.test("accepting records the owner's decision", function()
  local _, state = run_handler()
  local decisions = 0
  for _, saved in ipairs(state.saved) do
    if saved.collection == "games.gamesgamesgamesgames.contributionOwnerDecision" then
      decisions = decisions + 1
      t.eq(saved.data.status, "accepted", "status")
    end
  end
  t.eq(decisions, 1, "exactly one decision")
end)

t.test("accepting deletes the patch, because there is nothing left to overlay", function()
  local _, state = run_handler({ patch_rows = { { uri = PATCH_URI } } })
  t.eq(#state.deleted_records, 1, "patch deleted")
  t.eq(state.deleted_records[1].collection, "games.gamesgamesgamesgames.contributionPatch", "collection")
  -- Withdrawing the patch has to reindex the subject it was overlaying, so the
  -- subject URI must reach withdraw_patch rather than nil.
  t.eq(#state.posts, 1, "the subject was reindexed")
end)

t.test("the merged write and the overlay agree", function()
  -- The correctness requirement behind generating one merge source: if these
  -- disagreed the public would see one thing and the owner would commit
  -- another.
  local _, _, entity = run_handler({ changes = { name = "Proposed", genres = { "puzzle" } } })
  t.eq(entity.name, "Proposed", "name")
  t.deep_eq(entity.genres, { "puzzle" }, "array replaced wholesale, as the overlay does")
end)

t.test("only allowlisted fields can be merged", function()
  local _, _, entity = run_handler({
    changes = { name = "Proposed", publishedAt = "1999-01-01T00:00:00Z", ["$type"] = "nonsense" },
  })
  t.eq(entity.publishedAt, nil, "publishedAt is not writable through a contribution")
  t.falsy(entity["$type"] == "nonsense", "$type is not writable")
end)

t.test("a non-owner cannot accept", function()
  t.raises(function() run_handler({ caller_did = "did:plc:stranger" }) end, "you do not own the subject entity", "authz")
end)

t.test("an owner cannot accept something a moderator denied", function()
  t.raises(
    function() run_handler({ review_rows = { { record = { status = "denied" } } } }) end,
    "a moderator marked it denied",
    "closed by a moderator"
  )
end)

t.test("an owner cannot accept twice", function()
  t.raises(
    function() run_handler({ decision_rows = { { uri = "at://did:plc:owner/games.gamesgamesgamesgames.contributionOwnerDecision/1" } } }) end,
    "already decided",
    "idempotence"
  )
end)

t.test("verification is upgraded to both on an owner acceptance", function()
  local _, state = run_handler({
    verification_rows = {
      { uri = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionVerification/1",
        record = { acceptedBy = "mod" } },
    },
  })

  local upgraded = false
  for _, put in ipairs(state.put_records) do
    if put.collection == "games.gamesgamesgamesgames.contributionVerification" then
      upgraded = put.record.acceptedBy == "both"
    end
  end
  t.truthy(upgraded, "acceptedBy became both")
end)

t.test("an admin acceptance is not an owner acceptance", function()
  -- acceptedBy = "both" means the owner signed off. Nobody owns a game in the
  -- shared repo, so an admin accepting on its behalf stays a mod acceptance.
  local _, state = run_handler({
    caller_did = ADMIN,
    subject = PENTARACT_GAME_URI,
    verification_rows = {
      { uri = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionVerification/1",
        record = { acceptedBy = "mod" } },
    },
  })

  local checked = false
  for _, put in ipairs(state.put_records) do
    if put.collection == "games.gamesgamesgamesgames.contributionVerification" then
      checked = true
      t.eq(put.record.acceptedBy, "mod", "acceptedBy left alone")
    end
  end
  t.truthy(checked, "the verification was written")
end)

t.test("the verification lookup is constrained to the Pentaract repo", function()
  -- happyview_records indexes the whole network, so anyone can publish a
  -- contributionVerification naming someone else's contribution. Without the
  -- repo filter the handler would read a forged one and write it back.
  local _, state = run_handler()
  t.truthy(state.verification_query, "the verification was looked up")
  t.truthy(state.verification_query.sql:find("did = $1", 1, true), "repo filtered")
  t.eq(state.verification_query.bind[1], PENTARACT, "to Pentaract")
  t.eq(state.verification_query.bind[2], CONTRIBUTION_URI, "for this contribution")
end)

t.test("a Pentaract-owned game is still admin-only", function()
  t.raises(
    function() run_handler({ caller_did = OWNER, subject = PENTARACT_GAME_URI }) end,
    "only admins can accept",
    "ownerless games stay with admins"
  )
end)

t.test("an admin can accept on the Pentaract repo's behalf without an owner decision", function()
  local _, state = run_handler({ caller_did = ADMIN, subject = PENTARACT_GAME_URI })
  for _, saved in ipairs(state.saved) do
    t.falsy(
      saved.collection == "games.gamesgamesgamesgames.contributionOwnerDecision",
      "no owner decision for an ownerless game"
    )
  end
  local wrote_game = false
  for _, put in ipairs(state.put_records) do
    if put.collection == "games.gamesgamesgamesgames.game" then wrote_game = true end
  end
  t.truthy(wrote_game, "the Pentaract game was written")
end)

t.test("a live patch's changes are what gets committed", function()
  -- The contributor can edit their contribution after the approval. The owner
  -- and the public have been seeing the patch, so the patch is what merges.
  local _, _, entity = run_handler({
    changes = { name = "Edited after approval" },
    patch_rows = { { uri = PATCH_URI, record = { changes = { name = "Approved" } } } },
  })
  t.eq(entity.name, "Approved", "patch changes, not the edited contribution")
end)

t.test("an older client's contributionPatch input still resolves", function()
  local _, state, entity = run_handler({
    input = { contributionPatch = PATCH_URI },
    patch_rows = { { uri = PATCH_URI, record = { contribution = { uri = CONTRIBUTION_URI }, changes = { name = "Approved" } } } },
  })
  t.eq(entity.name, "Approved", "merged")
  t.eq(#state.deleted_records, 1, "patch withdrawn")
end)

t.test("a failed decision write does not undo the acceptance", function()
  local result, state, entity = run_handler({
    decision_save_fails = true,
    patch_rows = { { uri = PATCH_URI, record = { changes = { name = "Approved" } } } },
  })
  t.eq(entity.name, "Approved", "merged")
  t.eq(result.uri, GAME_URI, "returns the entity")
  t.eq(#state.deleted_records, 1, "patch still withdrawn")
  t.truthy(state.logs and state.logs[1] and state.logs[1]:find("could not record", 1, true), "logged")
end)

t.test("no contribution and no patch is refused", function()
  t.raises(function() run_handler({ input = {} }) end, "contribution URI is required")
end)

t.report()
