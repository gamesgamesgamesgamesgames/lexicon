package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local SOURCE = "src/shared/contribution_decision.lua"
local EXPORTS = {
  "did_from_uri", "load_contribution", "moderator_status", "existing_owner_decision",
  "assert_owner_may_decide", "record_owner_decision", "withdraw_patch",
}

local OWNER = "did:plc:owner"
local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local CONTRIBUTION_URI = "at://did:plc:contributor/games.gamesgamesgamesgames.contribution/1"
local PATCH_URI = "at://did:web:pentaract/games.gamesgamesgamesgames.contributionPatch/1"

-- `rows_for` maps a SQL fragment to the rows that query should return, so each
-- test says only what it cares about.
local function shared(options)
  options = options or {}
  local state = {
    saved = {}, deleted_records = {}, deleted_rows = {}, indexed = {},
    overlaid = {}, queries = {}, gets = {}, logs = {},
  }

  local function rows_for(sql)
    if sql:find("contributionReview", 1, true) then return options.review_rows or {} end
    if sql:find("contributionOwnerDecision", 1, true) then return options.decision_rows or {} end
    if sql:find("contributionPatch", 1, true) then return options.patch_rows or {} end
    if sql:find("DELETE FROM happyview_records", 1, true) then
      table.insert(state.deleted_rows, sql)
      return {}
    end
    return options.contribution_rows or {}
  end

  local sandbox = {
    caller_did = options.caller_did or OWNER,
    env = { PENTARACT_DID = "did:web:pentaract" },
    db = {
      -- Every query is recorded, so a test can assert on the SQL and the bound
      -- values. A stub that only answers by fragment cannot tell a filtered
      -- query from an unfiltered one.
      raw = function(sql, bind)
        table.insert(state.queries, { sql = sql, bind = bind })
        return rows_for(sql)
      end,
      get = function(target)
        -- `table.insert(t, nil)` stores nothing, which would hide a lookup of a
        -- nil subject behind a count of zero.
        table.insert(state.gets, target == nil and "<nil>" or target)
        if target == GAME_URI then return options.game end
        return nil
      end,
    },
    json = { decode = function(value) return value end },
    now = function() return "2026-10-01T00:00:00Z" end,
    log = function(message) table.insert(state.logs, message) end,
    Record = {
      new = function(collection, data)
        local saved = { collection = collection, data = data, _uri = "at://" .. OWNER .. "/" .. collection .. "/new" }
        saved.save = function(self) table.insert(state.saved, saved) end
        return saved
      end,
    },
    linked_repos = {
      get = function()
        return {
          delete_record = function(_, request) table.insert(state.deleted_records, request) end,
        }
      end,
    },
    index_game = function(target_uri, target_did, record)
      if options.index_fails then error("indexing failed: Meilisearch answered 503") end
      table.insert(state.indexed, { uri = target_uri, did = target_did, record = record })
    end,
    overlay_game = function(record, uri, exclude_patch_uri)
      table.insert(state.overlaid, { uri = uri, exclude = exclude_patch_uri })
      return record
    end,
  }

  return t.load_shared(SOURCE, EXPORTS, sandbox), state
end

-- The last query whose SQL mentions `fragment`, so a test can inspect the
-- filter a function actually sent rather than the rows a stub chose to return.
local function query_for(state, fragment)
  for index = #state.queries, 1, -1 do
    if state.queries[index].sql:find(fragment, 1, true) then
      return state.queries[index]
    end
  end
  return nil
end

t.test("did_from_uri reads the repo out of an at-uri", function()
  local s = shared()
  t.eq(s.did_from_uri(GAME_URI), OWNER, "owner did")
end)

t.test("load_contribution refuses a missing uri", function()
  local s = shared()
  t.raises(function() s.load_contribution("") end, "contribution URI is required", "empty")
  t.raises(function() s.load_contribution(CONTRIBUTION_URI) end, "contribution not found", "absent")
end)

t.test("load_contribution returns the row and its decoded record", function()
  local s = shared({
    contribution_rows = { { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI, changes = { name = "X" } } } },
  })
  local contribution = s.load_contribution(CONTRIBUTION_URI)
  t.eq(contribution.cid, "bafy1", "cid")
  t.eq(contribution.record.subject, GAME_URI, "record")
end)

t.test("a moderator review only counts from the Pentaract repo", function()
  -- Anyone can publish a contributionReview naming someone else's
  -- contribution; without the repo filter a stranger could make an owner's
  -- queue item unreachable.
  local s = shared({ review_rows = { { record = { status = "denied" } } } })
  t.eq(s.moderator_status(CONTRIBUTION_URI), "denied", "status read")

  local sql_seen
  local s2 = t.load_shared(SOURCE, EXPORTS, {
    caller_did = OWNER,
    env = { PENTARACT_DID = "did:web:pentaract" },
    db = { raw = function(sql, bind) sql_seen = { sql = sql, bind = bind } return {} end },
    json = { decode = function(v) return v end },
  })
  s2.moderator_status(CONTRIBUTION_URI)
  t.truthy(sql_seen.sql:find("did = $1", 1, true), "repo filtered")
  t.eq(sql_seen.bind[1], "did:web:pentaract", "to Pentaract")
  t.eq(sql_seen.bind[2], CONTRIBUTION_URI, "for this contribution")
end)

t.test("an owner decision only counts from the owner's own repo", function()
  -- The idempotence guard is only a guard if it reads the owner's own repo.
  -- Without the filter, anyone could publish a contributionOwnerDecision
  -- naming someone else's contribution and lock that owner out of deciding.
  local s, state = shared()
  s.existing_owner_decision(CONTRIBUTION_URI, OWNER)

  local query = query_for(state, "contributionOwnerDecision")
  t.truthy(query, "decision queried")
  t.truthy(query.sql:find("did = $1", 1, true), "repo filtered")
  t.eq(query.bind[1], OWNER, "to the owner")
  t.eq(query.bind[2], CONTRIBUTION_URI, "for this contribution")
end)

t.test("an owner may not decide a contribution to someone else's game", function()
  local s = shared({ caller_did = "did:plc:stranger" })
  t.raises(
    function() s.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI) end,
    "you do not own the subject entity",
    "ownership"
  )
end)

t.test("a newGame contribution has no owner to decide it", function()
  local s = shared()
  t.raises(function() s.assert_owner_may_decide(CONTRIBUTION_URI, nil) end, "no owner", "no subject")
  t.raises(function() s.assert_owner_may_decide(CONTRIBUTION_URI, "") end, "no owner", "empty subject")
end)

t.test("an owner may not decide twice", function()
  local s = shared({ decision_rows = { { uri = "at://did:plc:owner/games.gamesgamesgamesgames.contributionOwnerDecision/1" } } })
  t.raises(
    function() s.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI) end,
    "already decided",
    "idempotence"
  )
end)

t.test("an owner may not act on something a moderator closed", function()
  local s = shared({ review_rows = { { record = { status = "denied" } } } })
  t.raises(
    function() s.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI) end,
    "a moderator marked it denied",
    "denied"
  )

  local revision = shared({ review_rows = { { record = { status = "needsRevision" } } } })
  t.raises(
    function() revision.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI) end,
    "needsRevision",
    "needs revision"
  )
end)

t.test("an owner may act before any moderator has, and after an approval", function()
  local unreviewed = shared()
  unreviewed.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI)

  local approved = shared({ review_rows = { { record = { status = "approved" } } } })
  approved.assert_owner_may_decide(CONTRIBUTION_URI, GAME_URI)
  t.truthy(true, "neither raised")
end)

t.test("the decision is written to the owner's own repo", function()
  local s, state = shared()
  local uri = s.record_owner_decision(
    { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI } },
    "declined",
    "  "
  )

  t.eq(#state.saved, 1, "one record saved")
  t.eq(state.saved[1].collection, "games.gamesgamesgamesgames.contributionOwnerDecision", "collection")
  t.eq(state.saved[1].data.status, "declined", "status")
  t.eq(state.saved[1].data.subject, GAME_URI, "subject denormalised")
  t.eq(state.saved[1].data.contribution.uri, CONTRIBUTION_URI, "strong ref uri")
  t.eq(state.saved[1].data.contribution.cid, "bafy1", "strong ref")
  t.eq(state.saved[1].data.createdAt, "2026-10-01T00:00:00Z", "stamped")
  t.eq(state.saved[1].data.reason, nil, "a blank reason is omitted, not stored")
  t.truthy(uri, "returns the new uri")
end)

t.test("a reason that says something is kept", function()
  local s, state = shared()
  s.record_owner_decision(
    { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI } },
    "declined",
    "Wrong release date"
  )
  t.eq(state.saved[1].data.reason, "Wrong release date", "reason stored")
end)

t.test("a padded reason is stored trimmed", function()
  -- The blankness test trims, so the stored value trims too: deciding on one
  -- form and storing another is the inconsistency that reads as a bug later.
  local s, state = shared()
  s.record_owner_decision(
    { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI } },
    "declined",
    "  Wrong release date\n"
  )
  t.eq(state.saved[1].data.reason, "Wrong release date", "padding removed")
end)

t.test("a reason that is not a string is omitted rather than raising", function()
  -- HappyView parses a procedure's input schema but never enforces it, so a
  -- caller can send anything here. A bare truthiness check would reach `:match`
  -- on a number and raise.
  local s, state = shared()
  s.record_owner_decision(
    { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI } },
    "declined",
    42
  )
  t.eq(state.saved[1].data.reason, nil, "omitted")

  local s2, state2 = shared()
  s2.record_owner_decision(
    { uri = CONTRIBUTION_URI, cid = "bafy1", record = { subject = GAME_URI } },
    "declined",
    { nested = "table" }
  )
  t.eq(state2.saved[1].data.reason, nil, "a table is omitted too")
end)

t.test("withdrawing a patch deletes it from the Pentaract repo and the index", function()
  local s, state = shared({
    patch_rows = { { uri = PATCH_URI } },
    game = { name = "Stored" },
  })

  local withdrawn = s.withdraw_patch(CONTRIBUTION_URI, GAME_URI)
  t.eq(withdrawn, PATCH_URI, "returns the patch it withdrew")
  t.eq(#state.deleted_records, 1, "deleted from the repo")
  t.eq(state.deleted_records[1].collection, "games.gamesgamesgamesgames.contributionPatch", "collection")
  t.eq(state.deleted_records[1].rkey, "1", "rkey")
  t.eq(#state.deleted_rows, 1, "dropped from the index")
  t.eq(#state.indexed, 1, "subject reindexed immediately")
  t.eq(state.indexed[1].uri, GAME_URI, "the subject")
  t.eq(state.indexed[1].did, OWNER, "under its own repo")
end)

t.test("a withdrawn patch is excluded from the record it reindexes", function()
  -- The patch row is still in happyview_records at this point — the local
  -- DELETE and the firehose delete both land later. Without the exclusion the
  -- reindex would write the patched version straight back.
  local s, state = shared({
    patch_rows = { { uri = PATCH_URI } },
    game = { name = "Stored" },
  })

  s.withdraw_patch(CONTRIBUTION_URI, GAME_URI)
  t.eq(#state.overlaid, 1, "overlaid once")
  t.eq(state.overlaid[1].uri, GAME_URI, "for the subject")
  t.eq(state.overlaid[1].exclude, PATCH_URI, "the withdrawn patch is excluded")
end)

t.test("a live patch is only looked for in the Pentaract repo", function()
  -- A patch in anyone else's repo is not a moderator approval, and must not be
  -- the thing a decline deletes.
  local s, state = shared()
  s.withdraw_patch(CONTRIBUTION_URI, GAME_URI)

  local query = query_for(state, "contributionPatch")
  t.truthy(query, "patch queried")
  t.truthy(query.sql:find("did = $1", 1, true), "repo filtered")
  t.eq(query.bind[1], "did:web:pentaract", "to Pentaract")
  t.eq(query.bind[2], CONTRIBUTION_URI, "for this contribution")
end)

t.test("a failed reindex after the withdrawal is logged, not raised", function()
  -- The decision and any merge are committed by now. Raising would report a
  -- failure for something that happened, and the retry would be refused.
  local s, state = shared({
    patch_rows = { { uri = PATCH_URI } },
    game = { name = "Stored" },
    index_fails = true,
  })

  t.eq(s.withdraw_patch(CONTRIBUTION_URI, GAME_URI), PATCH_URI, "still withdrawn")
  t.eq(#state.deleted_records, 1, "deleted from the repo")
  t.truthy(state.logs[1] and state.logs[1]:find("could not reindex", 1, true), "logged")
end)

t.test("withdrawing when no patch exists is a no-op", function()
  local s, state = shared({ game = { name = "Stored" } })
  t.eq(s.withdraw_patch(CONTRIBUTION_URI, GAME_URI), nil, "nothing withdrawn")
  t.eq(#state.deleted_records, 0, "no repo delete")
  t.eq(#state.deleted_rows, 0, "no index delete")
  t.eq(#state.indexed, 0, "no reindex")
end)

t.test("withdrawing a newGame patch has no subject to reindex", function()
  -- acceptContribution reaches here with no subject when the contribution
  -- created the game, and there is nothing to look up or reindex.
  local s, state = shared({ patch_rows = { { uri = PATCH_URI } } })
  t.eq(s.withdraw_patch(CONTRIBUTION_URI, nil), PATCH_URI, "still withdrawn")
  t.eq(#state.gets, 0, "no subject looked up")
  t.eq(#state.indexed, 0, "no reindex")

  local blank, blank_state = shared({ patch_rows = { { uri = PATCH_URI } } })
  blank.withdraw_patch(CONTRIBUTION_URI, "")
  t.eq(#blank_state.gets, 0, "an empty subject is no subject either")
end)

t.test("withdrawing a patch whose subject has gone leaves the index alone", function()
  -- `db.get` answers nil for anything but GAME_URI, so this stands in for a
  -- subject that has been deleted out from under the patch.
  local s, state = shared({ patch_rows = { { uri = PATCH_URI } } })
  t.eq(s.withdraw_patch(CONTRIBUTION_URI, GAME_URI), PATCH_URI, "still withdrawn")
  t.eq(#state.indexed, 0, "nothing to reindex")
end)

t.report()
