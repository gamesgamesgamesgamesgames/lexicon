-- Canonical owner-decision writes, shared by acceptContribution and
-- declineContribution.
--
-- THIS FILE IS A SOURCE, NOT A HANDLER. `bun run generate:shared` inlines it
-- into every handler that marks a slot for it. Do not edit the copies.
--
-- Slot order matters: this block calls `index_game` (src/shared/game_index.lua)
-- and `overlay_game` (src/shared/game_changes.lua), so both of those slots must
-- appear above it in a handler.
--
-- Declarations only: no `return`, no `function handle()`. Reads the handler
-- globals `db`, `json`, `env`, `now`, `log`, `caller_did`, `Record` and
-- `linked_repos`.

local OWNER_DECISION_COLLECTION = "games.gamesgamesgamesgames.contributionOwnerDecision"
local CONTRIBUTION_COLLECTION = "games.gamesgamesgamesgames.contribution"
local REVIEW_COLLECTION = "games.gamesgamesgamesgames.contributionReview"
local OVERLAY_PATCH_COLLECTION = "games.gamesgamesgamesgames.contributionPatch"

local function did_from_uri(target_uri)
  return target_uri:match("^at://([^/]+)/")
end

-- Patches live in the Pentaract repo, not the caller's, so touching them needs
-- a linked-repo grant over that account. HappyView can only write to a repo it
-- holds a session for.
local function pentaract_repo()
  local did = env.PENTARACT_DID
  if not did or did == "" then
    error("PENTARACT_DID is not configured")
  end
  local repo = linked_repos.get(did)
  if not repo then
    error("no linked repo grant for " .. did .. " — an admin must link that account")
  end
  return repo
end

local function load_contribution(contribution_uri)
  if not contribution_uri or contribution_uri == "" then
    error("contribution URI is required")
  end

  local rows = db.raw(
    "SELECT uri, cid, record FROM happyview_records " ..
    "WHERE uri = $1 AND collection = '" .. CONTRIBUTION_COLLECTION .. "' LIMIT 1",
    { contribution_uri }
  )

  if not rows or #rows == 0 then
    error("contribution not found: " .. contribution_uri)
  end

  return {
    uri = rows[1].uri,
    cid = rows[1].cid,
    record = json.decode(rows[1].record),
  }
end

-- The moderator's verdict, or nil if nobody has looked at it.
--
-- `did = PENTARACT_DID` is a security filter: reviews are only authoritative
-- from the Pentaract repo, and happyview_records holds the whole network.
local function moderator_status(contribution_uri)
  local rows = db.raw(
    "SELECT record FROM happyview_records WHERE collection = '" .. REVIEW_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  return json.decode(rows[1].record).status
end

-- The owner's own decision on this contribution, if they have made one.
--
-- `did = owner_did` is the same security filter: a decision is only the owner's
-- if it is in the owner's repo. Without it, anyone could publish a
-- contributionOwnerDecision naming someone else's contribution and lock that
-- owner out of deciding it.
local function existing_owner_decision(contribution_uri, owner_did)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = '" .. OWNER_DECISION_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { owner_did, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  return rows[1].uri
end

-- The three ways an owner's decision can be out of order, refused with the
-- reason rather than silently ignored.
local function assert_owner_may_decide(contribution_uri, subject)
  if not subject or subject == "" then
    error("a newGame contribution has no owner to decide it")
  end

  if did_from_uri(subject) ~= caller_did then
    error("unauthorized: you do not own the subject entity")
  end

  local decided = existing_owner_decision(contribution_uri, caller_did)
  if decided then
    error("you have already decided this contribution: " .. decided)
  end

  -- An owner may act before any moderator has, or after an approval. A denial
  -- or a revision request puts the ball elsewhere.
  local status = moderator_status(contribution_uri)
  if status and status ~= "approved" then
    error("this contribution is not available to decide: a moderator marked it " .. status)
  end
end

-- A reason is stored trimmed, or omitted when it is blank.
--
-- `type(reason) == "string"` rather than a bare `reason`: HappyView parses a
-- procedure's input schema but never enforces it, so a caller can send a number
-- here and `:match` would raise. Trimming on store as well as for the blankness
-- test keeps the two consistent — deciding on the trimmed value and storing the
-- padded one reads as a bug later.
local function clean_reason(reason)
  if type(reason) ~= "string" then
    return nil
  end

  local trimmed = reason:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local function record_owner_decision(contribution, status, reason)
  local decision = Record.new(OWNER_DECISION_COLLECTION, {
    contribution = { uri = contribution.uri, cid = contribution.cid },
    subject = contribution.record.subject,
    status = status,
    reason = clean_reason(reason),
    createdAt = now(),
  })
  decision:save()
  return decision._uri
end

-- Remove the public overlay for a contribution, if one is live.
--
-- contributionPatch.lua reindexes the subject when the delete reaches the
-- firehose; the index write here means the public read is already correct
-- before that arrives, which matters most for a decline.
local function withdraw_patch(contribution_uri, subject)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = '" .. OVERLAY_PATCH_COLLECTION .. "' " ..
    "AND did = $1 AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { env.PENTARACT_DID, contribution_uri }
  )

  if not rows or #rows == 0 then
    return nil
  end

  local patch_uri = rows[1].uri

  local ok, err = pcall(function()
    pentaract_repo():delete_record({
      collection = OVERLAY_PATCH_COLLECTION,
      rkey = patch_uri:match("/([^/]+)$"),
    })
  end)
  if not ok then
    log("warning: failed to delete contributionPatch from the Pentaract repo: " .. tostring(err))
  end

  -- Drop it from the index regardless: the decision has been made and the
  -- patch must not resurface even if the PDS delete failed.
  pcall(function()
    db.raw("DELETE FROM happyview_records WHERE uri = $1", { patch_uri })
  end)

  if subject and subject ~= "" then
    local game = db.get(subject)
    if game then
      index_game(subject, did_from_uri(subject), overlay_game(game, subject, patch_uri))
    end
  end

  return patch_uri
end
