-- Applies contributions from trusted automated accounts (AUTO_ACCEPT_DIDS, e.g.
-- the IGDB sync account) to the Pentaract catalogue without a moderator.
--
-- createContribution queues one of these per contribution from such an
-- account. An admin can also queue a sweep through autoAcceptContributions to
-- drain contributions that were never applied, or to retry ones whose job
-- failed. HappyView does not retry failed jobs on its own.
--
-- Input:
--   uri, cid        apply a single contribution
--   sweep = true    process pending contributions, oldest first
--     limit         how many to look at (default 500, max 5000)
--     after         resume from the `after` cursor a previous sweep reported
--   writes          "full" (game + verification + review, the default) or
--                   "minimal" (game + review). Falls back to
--                   env.AUTO_ACCEPT_WRITES, then "full".
--   dryRun          report what would happen without writing anything
--
-- Every contribution this job finishes gets a review in the Pentaract repo:
-- approved when it was applied or already matched, denied when a newer
-- contribution from the same account for the same game superseded it. The
-- review is the marker every pending check keys on (listContributions,
-- createContribution's limit, the sweep), so "minimal" still writes it; only
-- the verification, which credits the contributor, is optional. Contributions
-- the job declines to touch (human authors, owned games) get no review and
-- stay pending.
--
-- Media: a PDS refuses a record that references a blob it does not hold. When
-- that happens nothing is applied and the contribution stays pending
-- ("deferred"), tracked in the contribution_deferrals table. It is retried no
-- sooner than AUTO_ACCEPT_MEDIA_RETRY_HOURS (default 6) later ("waiting" until
-- then). After AUTO_ACCEPT_MEDIA_MAX_ATTEMPTS (default 3) deferred attempts,
-- or AUTO_ACCEPT_MEDIA_MAX_DAYS (default 7) after the first, whichever comes
-- first, the full change is tried once more and, only if the blobs are still
-- missing, applied without its media and approved with the reason "media
-- unavailable in catalogue repo".
--
-- Note: IGDB is treated as authoritative for the fields it sends. An accepted
-- IGDB contribution overwrites those fields on a Pentaract game, including
-- values a moderator approved from a human contribution earlier.
--
-- Safety:
--   * The Pentaract linked-repo grant is checked before anything is written, so
--     a dead grant fails the job with nothing applied.
--   * Only reviews written by the Pentaract repo count. Anyone can publish a
--     contributionReview record, so a review from any other repo is ignored.
--   * A contribution is superseded, never applied, when the same account has
--     a newer one for the same game (or the same IGDB id for a new game).
--     Sweeps also run oldest first, and a deferred contribution applies
--     nothing until it applies in full. Old data cannot land over new.
--   * The game is the only write that changes catalogue data: a single put
--     guarded by swap_cid, or a create at a deterministic rkey. The
--     verification and review follow it. If one of them fails, a rerun finds
--     the game already matching, writes only what is missing, and stops.

local GAME_COLLECTION = "games.gamesgamesgamesgames.game"
local CONTRIBUTION_COLLECTION = "games.gamesgamesgamesgames.contribution"
local REVIEW_COLLECTION = "games.gamesgamesgamesgames.contributionReview"
local VERIFICATION_COLLECTION = "games.gamesgamesgamesgames.contributionVerification"

-- Same list as reviewContribution: `changes` is an unknown-typed blob and
-- linked-repo writes are not validated against the game lexicon.
local GAME_FIELDS = {
  "name", "summary", "applicationType", "genres", "modes", "themes",
  "playerPerspectives", "releases", "media", "parent", "storyline", "keywords",
  "websites", "videos", "alternativeNames", "timeToBeat", "ageRatings",
  "languageSupports", "multiplayerModes", "engines", "externalIds",
  "description", "descriptionFacets", "systemRequirements", "platformFeatures",
}

local DEFAULT_SWEEP_LIMIT = 500
local MAX_SWEEP_LIMIT = 5000

local function parse_did_list(raw)
  local dids = {}
  for d in (raw or ""):gmatch("[^,]+") do
    local trimmed = d:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      dids[trimmed] = true
    end
  end
  return dids
end

local AUTO_ACCEPT_DIDS = parse_did_list(env.AUTO_ACCEPT_DIDS)

local function auto_accept_did_list()
  local list = {}
  for d, _ in pairs(AUTO_ACCEPT_DIDS) do
    table.insert(list, d)
  end
  table.sort(list)
  return list
end

local function did_of(uri)
  return uri and uri:match("^at://([^/]+)/")
end

local function collection_of(uri)
  return uri and uri:match("^at://[^/]+/([^/]+)/")
end

local function rkey_of(uri)
  return uri and uri:match("/([^/]+)$")
end

-- Errors that mean the grant itself is unusable. A sweep stops on these
-- instead of marking every remaining contribution as failed.
local function is_grant_error(err)
  local s = tostring(err)
  return s:find("needs reauthorization", 1, true)
    or s:find("has not been authorized", 1, true)
    or s:find("no linked repo grant", 1, true)
    or s:find("is gone", 1, true)
end

local function is_missing_blob_error(err)
  local s = tostring(err)
  return s:find("BlobNotFound", 1, true) or s:find("Could not find blob", 1, true)
end

local function pentaract_repo()
  local did = env.PENTARACT_DID
  if not did or did == "" then
    error("PENTARACT_DID is not configured")
  end
  local repo = linked_repos.get(did)
  if not repo then
    error("no linked repo grant for " .. did .. " — an admin must link that account")
  end
  if repo.status ~= "active" then
    error("linked repo " .. did .. " needs reauthorization (status " .. tostring(repo.status) .. ")")
  end
  return repo
end

-- Structural equality for decoded JSON. Key order does not matter; an empty
-- array and an empty object compare equal, which is fine for game fields.
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- externalIds is a map of services to ids. IGDB only knows some services, so
-- its ids are merged over the stored ones instead of replacing them (a Twitch
-- id resolved by createGame, say, must survive an IGDB update).
local function merge_external_ids(incoming, stored)
  if type(incoming) ~= "table" or type(stored) ~= "table" then
    return incoming
  end
  local merged = {}
  for k, v in pairs(stored) do
    merged[k] = v
  end
  for k, v in pairs(incoming) do
    merged[k] = v
  end
  return merged
end

-- The fields of `changes` that differ from `current`, in GAME_FIELDS order.
local function effective_changes(changes, current)
  local out, fields = {}, {}
  for _, field in ipairs(GAME_FIELDS) do
    local v = changes[field]
    if field == "externalIds" then
      v = merge_external_ids(v, current[field])
    end
    if v ~= nil and not deep_equal(v, current[field]) then
      out[field] = v
      table.insert(fields, field)
    end
  end
  return out, fields
end

local function generate_slug(str)
  if not str or str == "" then
    return nil
  end
  local slug = str:lower()
  slug = slug:gsub("[^%w%s%-]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return nil
  end
  return slug
end

-- Like reviewContribution's assign_slug: a taken slug gets a numeric suffix
-- rather than being repointed. Reruns reuse the slug already assigned to uri.
-- Returns the slug and whether this call inserted it.
local function assign_slug(name, uri)
  local owned = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", { uri })
  if owned and #owned > 0 then
    return owned[1].slug, false
  end

  local base = generate_slug(name)
  if not base then
    return nil, false
  end

  local slug, n = base, 1
  while true do
    local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", { slug })
    if not rows or #rows == 0 then
      break
    end
    n = n + 1
    slug = base .. "-" .. n
  end

  db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO NOTHING", { slug, uri })
  return slug, true
end

local function load_record(uri)
  local rows = db.raw("SELECT uri, cid, record FROM happyview_records WHERE uri = $1 LIMIT 1", { uri })
  if not rows or #rows == 0 then
    return nil
  end
  return { uri = rows[1].uri, cid = rows[1].cid, record = json.decode(rows[1].record) }
end

-- Whether the Pentaract repo already holds a `collection` record for this
-- contribution. Records in any other repo do not count.
local function pentaract_has(collection, contribution_uri)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = $1 AND did = $2 " ..
    "AND record::jsonb->'contribution'->>'uri' = $3 LIMIT 1",
    { collection, env.PENTARACT_DID, contribution_uri }
  )
  return rows and #rows > 0
end

local function resolve_igdb(igdb_id)
  if not igdb_id or igdb_id == "" then
    return nil
  end
  local rows = db.raw(
    "SELECT uri FROM external_ids WHERE service = 'igdb' AND external_id = $1 LIMIT 1",
    { tostring(igdb_id) }
  )
  if rows and #rows > 0 then
    return rows[1].uri
  end
  return nil
end

-- A newer contribution from the same author for the same game, if any.
-- "Newer" is by the record's createdAt, then uri, the order sweeps use.
-- Corrections are full diffs against the stored game, so the author's newest
-- one carries everything its older pending ones would have changed. Another
-- account's contribution carries its own fields, not this one's, so it never
-- supersedes.
local function newer_contribution(c, contribution_uri, author)
  local created = c.createdAt or ""
  local rows
  if c.subject and c.subject ~= "" then
    rows = db.raw(
      "SELECT uri FROM happyview_records " ..
      "WHERE collection = 'games.gamesgamesgamesgames.contribution' " ..
      "AND did = $1 " ..
      "AND record::jsonb->>'subject' = $2 " ..
      "AND (COALESCE(record::jsonb->>'createdAt', ''), uri) > ($3, $4) " ..
      "ORDER BY record::jsonb->>'createdAt' DESC LIMIT 1",
      { author, c.subject, created, contribution_uri }
    )
  else
    local igdb = c.changes and c.changes.externalIds and c.changes.externalIds.igdb
    if not igdb or igdb == "" then
      return nil
    end
    rows = db.raw(
      "SELECT uri FROM happyview_records " ..
      "WHERE collection = 'games.gamesgamesgamesgames.contribution' " ..
      "AND did = $1 " ..
      "AND record::jsonb->>'contributionType' = 'newGame' " ..
      "AND record::jsonb->'changes'->'externalIds'->>'igdb' = $2 " ..
      "AND (COALESCE(record::jsonb->>'createdAt', ''), uri) > ($3, $4) " ..
      "ORDER BY record::jsonb->>'createdAt' DESC LIMIT 1",
      { author, tostring(igdb), created, contribution_uri }
    )
  end
  if rows and #rows > 0 then
    return rows[1].uri
  end
  return nil
end

-- Media deferral state lives in the `contribution_deferrals` table (created by
-- the deploy DDL, not by this script). A contribution whose media blobs are
-- missing from the catalogue repo is retried no more often than every
-- AUTO_ACCEPT_MEDIA_RETRY_HOURS, and after AUTO_ACCEPT_MEDIA_MAX_ATTEMPTS
-- failed attempts or AUTO_ACCEPT_MEDIA_MAX_DAYS since the first one,
-- whichever comes first, it is applied without its media.
local function config_number(name, fallback)
  local v = tonumber(env[name])
  if v and v > 0 then
    return v
  end
  return fallback
end

local function load_deferral(uri)
  local rows = db.raw(
    "SELECT attempts, " ..
    "EXTRACT(EPOCH FROM (now() - first_deferred_at)) / 86400 AS age_days, " ..
    "EXTRACT(EPOCH FROM (now() - last_attempt_at)) / 3600 AS since_hours " ..
    "FROM contribution_deferrals WHERE uri = $1",
    { uri }
  )
  if not rows or #rows == 0 then
    return nil
  end
  return {
    attempts = tonumber(rows[1].attempts) or 0,
    age_days = tonumber(rows[1].age_days) or 0,
    since_hours = tonumber(rows[1].since_hours) or 0,
  }
end

local function record_deferral(uri, err)
  db.raw(
    "INSERT INTO contribution_deferrals (uri, attempts, first_deferred_at, last_attempt_at, last_error) " ..
    "VALUES ($1, 1, now(), now(), $2) " ..
    "ON CONFLICT (uri) DO UPDATE SET attempts = contribution_deferrals.attempts + 1, " ..
    "last_attempt_at = now(), last_error = $2",
    { uri, tostring(err):sub(1, 500) }
  )
end

local function clear_deferral(uri)
  db.raw("DELETE FROM contribution_deferrals WHERE uri = $1", { uri })
end

-- Game record keys are "any", so a new game gets a key derived from its IGDB
-- id (or the contribution's own key). A rerun after a partial failure then
-- finds the game it already created instead of creating a second one.
local function new_game_rkey(changes, contribution_uri)
  local igdb = changes.externalIds and changes.externalIds.igdb
  if igdb and tostring(igdb):match("^[%w]+$") then
    return "igdb-" .. tostring(igdb)
  end
  return rkey_of(contribution_uri)
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function write_review(pentaract, ref, author, status, reason)
  -- Narrows the race with a concurrent job on the same contribution; the
  -- caller handles the rest.
  if pentaract_has(REVIEW_COLLECTION, ref.uri) then
    return false
  end
  pentaract:create_record({
    collection = REVIEW_COLLECTION,
    record = {
      ["$type"] = REVIEW_COLLECTION,
      contribution = ref,
      status = status,
      reviewedBy = author,
      reason = reason,
      createdAt = now(),
    },
  })
  return true
end

local function verify(pentaract, ref, author, subject, contribution_type, opts)
  if opts.writes == "full" and not pentaract_has(VERIFICATION_COLLECTION, ref.uri) then
    pentaract:create_record({
      collection = VERIFICATION_COLLECTION,
      record = {
        ["$type"] = VERIFICATION_COLLECTION,
        contribution = ref,
        contributor = author,
        subject = subject,
        contributionType = contribution_type,
        acceptedBy = "mod",
        createdAt = now(),
      },
    })
  end
end

local function without_media(fields)
  local rest = {}
  for _, f in ipairs(fields) do
    if f ~= "media" then
      table.insert(rest, f)
    end
  end
  return rest
end

local function process(contribution_uri, opts)
  local pentaract = opts.pentaract
  local author = did_of(contribution_uri)

  if collection_of(contribution_uri) ~= CONTRIBUTION_COLLECTION then
    return { status = "skipped", reason = "not a contribution uri" }
  end
  if not AUTO_ACCEPT_DIDS[author] then
    return { status = "skipped", reason = "author is not an auto-accept account" }
  end

  local contribution = load_record(contribution_uri)
  if not contribution then
    return { status = "skipped", reason = "contribution not indexed" }
  end
  if opts.cid and opts.cid ~= "" and opts.cid ~= contribution.cid then
    return { status = "skipped", reason = "contribution cid changed since it was queued" }
  end
  if pentaract_has(REVIEW_COLLECTION, contribution_uri) then
    return { status = "skipped", reason = "already reviewed" }
  end

  local c = contribution.record
  local changes = c.changes or {}
  local ref = { uri = contribution_uri, cid = contribution.cid }
  local subject = c.subject
  local is_new_game = subject == nil or subject == ""
  local result = { status = "applied", contributionType = c.contributionType }

  -- A newGame for a game the catalogue already has (an earlier run, or another
  -- contribution for the same IGDB game) becomes an update.
  local create_rkey
  if is_new_game then
    local igdb = changes.externalIds and changes.externalIds.igdb
    subject = resolve_igdb(igdb)
    if not subject then
      create_rkey = new_game_rkey(changes, contribution_uri)
      local candidate = "at://" .. pentaract.did .. "/" .. GAME_COLLECTION .. "/" .. create_rkey
      if load_record(candidate) then
        subject = candidate
        create_rkey = nil
      end
    end
  end

  -- Ownership and subject checks come before anything that writes, including
  -- the supersede review: a contribution to an owned game belongs to the
  -- owner's queue and gets no Pentaract review from here.
  if subject then
    if did_of(subject) ~= pentaract.did then
      return { status = "skipped", reason = "subject is not in the Pentaract repo" }
    end
    if collection_of(subject) ~= GAME_COLLECTION then
      return { status = "skipped", reason = "subject is not a game" }
    end
  end

  local current, diff, fields
  if not create_rkey then
    current = load_record(subject)
    if not current then
      return { status = "skipped", reason = "subject game not found: " .. subject }
    end
    diff, fields = effective_changes(changes, current.record)
    result.fields = fields
    result.subject = subject

    -- Already matching, whether from an earlier run of this job whose review
    -- write failed or by coincidence: approve, never deny.
    if #fields == 0 then
      result.status = "noop"
      if not opts.dry_run then
        clear_deferral(contribution_uri)
        write_review(pentaract, ref, author, "approved", "Auto-accepted: the game already matches this contribution.")
      end
      return result
    end
  end

  local newer = newer_contribution(c, contribution_uri, author)
  if newer then
    if not opts.dry_run then
      clear_deferral(contribution_uri)
      write_review(pentaract, ref, author, "denied", "Superseded by a newer contribution: " .. newer)
    end
    return { status = "superseded", supersededBy = newer, subject = subject }
  end

  -- Media deferral: a contribution whose media blobs were missing is not
  -- retried until AUTO_ACCEPT_MEDIA_RETRY_HOURS have passed, which gives the
  -- sync a chance to mirror them.
  local deferral = load_deferral(contribution_uri)
  local max_attempts = config_number("AUTO_ACCEPT_MEDIA_MAX_ATTEMPTS", 3)
  local max_days = config_number("AUTO_ACCEPT_MEDIA_MAX_DAYS", 7)
  local retry_hours = config_number("AUTO_ACCEPT_MEDIA_RETRY_HOURS", 6)
  local give_up_media = deferral ~= nil and (deferral.attempts >= max_attempts or deferral.age_days >= max_days)
  if deferral and not give_up_media and deferral.since_hours < retry_hours then
    return { status = "waiting", reason = "media retry not due yet", attempts = deferral.attempts }
  end

  local media_dropped = false

  if create_rkey then
    if not changes.name or changes.name == "" or not changes.applicationType or changes.applicationType == "" then
      return { status = "skipped", reason = "newGame contribution lacks name or applicationType" }
    end
    subject = "at://" .. pentaract.did .. "/" .. GAME_COLLECTION .. "/" .. create_rkey
    local game
    game, fields = effective_changes(changes, {})
    game["$type"] = GAME_COLLECTION
    game.createdAt = now()
    -- IGDB games have always been published on import.
    game.publishedAt = now()
    result.fields = fields
    result.created = true
    result.subject = subject

    if opts.dry_run then
      return result
    end

    -- The slug goes in first so the game's index hook can see it, and comes
    -- out again if the create fails.
    local slug, inserted = assign_slug(changes.name, subject)
    local function create()
      return pentaract:create_record({ collection = GAME_COLLECTION, rkey = create_rkey, record = game })
    end
    -- The full record is always tried first, even once the deferral cap has
    -- been reached: the blobs may have arrived since the last attempt.
    local ok, err = pcall(create)
    if not ok and is_missing_blob_error(err) and game.media ~= nil and give_up_media then
      game.media = nil
      fields = without_media(fields)
      result.fields = fields
      media_dropped = true
      ok, err = pcall(create)
    end
    if not ok then
      if inserted then
        db.raw("DELETE FROM slugs WHERE slug = $1 AND uri = $2", { slug, subject })
      end
      if is_missing_blob_error(err) and game.media ~= nil then
        record_deferral(contribution_uri, err)
        return { status = "deferred", reason = "media blobs are not in the catalogue repo", subject = subject }
      end
      error(err)
    end
  else
    if opts.dry_run then
      return result
    end

    local function put(fields_to_apply)
      -- Only top-level fields are replaced, so a shallow copy keeps
      -- current.record intact for a second attempt.
      local game = {}
      for k, v in pairs(current.record) do
        game[k] = v
      end
      for _, f in ipairs(fields_to_apply) do
        game[f] = diff[f]
      end
      game["$type"] = GAME_COLLECTION
      game.uri = nil
      game.cid = nil
      return pentaract:put_record({
        collection = GAME_COLLECTION,
        rkey = rkey_of(subject),
        record = game,
        swap_cid = current.cid,
      })
    end

    -- The full change is always tried first, even once the deferral cap has
    -- been reached: the blobs may have arrived since the last attempt.
    local to_apply = fields
    local ok, err = pcall(put, to_apply)
    if not ok and is_missing_blob_error(err) and contains(to_apply, "media") and give_up_media then
      to_apply = without_media(fields)
      media_dropped = true
      ok, err = true, nil
      if #to_apply > 0 then
        ok, err = pcall(put, to_apply)
      end
    end

    if not ok then
      if not (is_missing_blob_error(err) and contains(to_apply, "media")) then
        error(err)
      end
      -- The new media references blobs the catalogue PDS does not hold.
      -- Nothing is applied: a partial apply that stays pending would be
      -- re-applied by later sweeps over whatever changed since.
      record_deferral(contribution_uri, err)
      return { status = "deferred", reason = "media blobs are not in the catalogue repo", subject = subject, attempts = (deferral and deferral.attempts or 0) + 1 }
    end
    result.fields = to_apply
  end

  clear_deferral(contribution_uri)
  if media_dropped then
    result.mediaDropped = true
  end

  -- A verification credits the contributor for something that landed. A
  -- media-only change whose media was given up on applied nothing.
  -- (A rerun after a failure between the game write and the verification
  -- finds the game matching and lands in the no-op branch, so that
  -- contribution goes uncredited. It is rare, and crediting every no-op
  -- would be worse.)
  if #result.fields > 0 then
    verify(pentaract, ref, author, subject, c.contributionType, opts)
  end

  local reason = "Auto-accepted: contribution from an automated account."
  if media_dropped then
    reason = "Auto-accepted without media: media unavailable in catalogue repo."
  end
  write_review(pentaract, ref, author, "approved", reason)

  return result
end

-- Two jobs can pick up the same contribution (the one createContribution
-- queued and a sweep). When one fails, it may only be because the other got
-- there first: report that as a skip, not a failure.
local function process_guarded(contribution_uri, opts)
  local ok, res = pcall(process, contribution_uri, opts)
  if ok then
    return res
  end
  if not is_grant_error(res) and pentaract_has(REVIEW_COLLECTION, contribution_uri) then
    return { status = "skipped", reason = "reviewed by a concurrent job" }
  end
  error(res, 0)
end

local function resolve_writes(input)
  local writes = input.writes
  if writes == nil or writes == "" then
    writes = env.AUTO_ACCEPT_WRITES
  end
  if writes == nil or writes == "" then
    writes = "full"
  end
  if writes ~= "full" and writes ~= "minimal" then
    error("writes must be 'full' or 'minimal', got " .. tostring(writes))
  end
  return writes
end

-- Sweep cursors are "<createdAt>|<uri>", the sweep's sort key.
local function parse_cursor(after)
  if not after or after == "" then
    return "", ""
  end
  local created, uri = after:match("^(.-)|(.*)$")
  if not created then
    error("after must be a cursor a previous sweep reported")
  end
  return created, uri
end

local function sweep(input, opts)
  local limit = math.floor(tonumber(input.limit) or DEFAULT_SWEEP_LIMIT)
  if limit < 1 then
    limit = 1
  elseif limit > MAX_SWEEP_LIMIT then
    limit = MAX_SWEEP_LIMIT
  end

  local dids = auto_accept_did_list()
  if #dids == 0 then
    error("AUTO_ACCEPT_DIDS is not configured")
  end

  local after_created, after_uri = parse_cursor(input.after)

  -- Pending = no review from the Pentaract repo yet. Oldest first, so that
  -- even without the supersede check an older change never lands last.
  local rows = db.raw(
    "SELECT c.uri, COALESCE(c.record::jsonb->>'createdAt', '') AS created FROM happyview_records c " ..
    "WHERE c.collection = 'games.gamesgamesgamesgames.contribution' " ..
    "AND c.did = ANY(string_to_array($1, ',')) " ..
    "AND (COALESCE(c.record::jsonb->>'createdAt', ''), c.uri) > ($2, $3) " ..
    "AND NOT EXISTS (SELECT 1 FROM happyview_records r " ..
      "WHERE r.collection = 'games.gamesgamesgamesgames.contributionReview' " ..
      "AND r.did = $4 " ..
      "AND r.record::jsonb->'contribution'->>'uri' = c.uri) " ..
    "ORDER BY COALESCE(c.record::jsonb->>'createdAt', ''), c.uri LIMIT $5",
    { table.concat(dids, ","), after_created, after_uri, env.PENTARACT_DID, limit }
  )

  local counts = { applied = 0, noop = 0, superseded = 0, deferred = 0, waiting = 0, skipped = 0, failed = 0 }
  local failures = {}
  local last = input.after

  for i, row in ipairs(rows or {}) do
    if job.should_stop() then
      break
    end

    local ok, res = pcall(process_guarded, row.uri, opts)
    if not ok then
      if is_grant_error(res) then
        error("stopped at " .. row.uri .. ": " .. tostring(res))
      end
      counts.failed = counts.failed + 1
      if #failures < 50 then
        table.insert(failures, { uri = row.uri, error = tostring(res) })
      end
      job.warn("failed " .. row.uri .. ": " .. tostring(res))
    else
      counts[res.status] = (counts[res.status] or 0) + 1
    end

    last = (row.created or "") .. "|" .. row.uri
    if i % 25 == 0 then
      job.progress({ processed = i, after = last, counts = counts })
    end
  end

  local done = not rows or #rows < limit
  job.progress({ processed = rows and #rows or 0, after = last, counts = counts, done = done })
  return { counts = counts, after = last, done = done, failures = toarray(failures) }
end

function handle()
  local input = job.input or {}
  local opts = {
    writes = resolve_writes(input),
    dry_run = input.dryRun == true,
  }

  -- Checked first, so a dead grant fails the job before anything is written.
  opts.pentaract = pentaract_repo()

  if input.sweep then
    local out = sweep(input, opts)
    log("contribution.auto-accept sweep: " .. json.encode(out.counts) .. " after=" .. tostring(out.after))
    return out
  end

  if not input.uri or input.uri == "" then
    error("uri is required unless sweep is set")
  end

  opts.cid = input.cid
  local res = process_guarded(input.uri, opts)
  log("contribution.auto-accept " .. input.uri .. ": " .. res.status .. (res.reason and (" (" .. res.reason .. ")") or ""))
  return res
end
