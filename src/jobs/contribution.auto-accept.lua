-- Applies contributions from trusted system identities (SYSTEM_DIDS, e.g. the
-- IGDB sync account) to the Pentaract catalogue without a moderator.
--
-- createContribution queues one of these per system contribution. An admin can
-- also queue a sweep through autoAcceptContributions to drain contributions
-- that were never applied, or to retry ones whose job failed.
--
-- Input:
--   uri, cid        apply a single contribution
--   sweep = true    apply pending system contributions in uri order
--     limit         how many to look at (default 500, max 5000)
--     after         resume after this contribution uri
--   writes          "full" (game + verification + review, the default) or
--                   "game_only" (just the game write). Falls back to
--                   env.AUTO_ACCEPT_WRITES, then "full".
--   dryRun          report what would happen without writing anything
--
-- Safety:
--   * The Pentaract linked-repo grant is checked before anything is written, so
--     a dead grant fails the job with nothing applied.
--   * The game is the only write that changes catalogue data, and it is a
--     single put guarded by swap_cid (or a create at a deterministic rkey).
--     The verification and the review follow it. If one of them fails, a rerun
--     finds the game already matches, writes only what is missing, and stops.
--   * Contributions that already have a review are skipped, so reruns and
--     overlapping sweeps are harmless.

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
    dids[d:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local SYSTEM_DIDS = parse_did_list(env.SYSTEM_DIDS)

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

-- The fields of `changes` that differ from `current`, in GAME_FIELDS order.
local function effective_changes(changes, current)
  local out, fields = {}, {}
  for _, field in ipairs(GAME_FIELDS) do
    local v = changes[field]
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
local function assign_slug(name, uri)
  local owned = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", { uri })
  if owned and #owned > 0 then
    return owned[1].slug
  end

  local base = generate_slug(name)
  if not base then
    return nil
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
  return slug
end

local function load_record(uri)
  local rows = db.raw("SELECT uri, cid, record FROM happyview_records WHERE uri = $1 LIMIT 1", { uri })
  if not rows or #rows == 0 then
    return nil
  end
  return { uri = rows[1].uri, cid = rows[1].cid, record = json.decode(rows[1].record) }
end

local function has_record_for(collection, contribution_uri)
  local rows = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = $1 " ..
    "AND record::jsonb->'contribution'->>'uri' = $2 LIMIT 1",
    { collection, contribution_uri }
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

-- Writes a game, dropping media when the catalogue PDS does not hold one of
-- its blobs. Contribution media is uploaded to the contributor's repo, and a
-- record may only reference blobs in its own repo. Returns the write result
-- and whether media was dropped.
local function write_game(fn, game, fields)
  local ok, result = pcall(fn, game)
  if ok then
    return result, false
  end
  if game.media == nil or not is_missing_blob_error(result) then
    error(result)
  end
  local has_media_change = false
  for _, f in ipairs(fields) do
    if f == "media" then
      has_media_change = true
    end
  end
  if not has_media_change then
    error(result)
  end
  return nil, true
end

local function process(contribution_uri, opts)
  local pentaract = opts.pentaract
  local author = did_of(contribution_uri)

  if collection_of(contribution_uri) ~= CONTRIBUTION_COLLECTION then
    return { status = "skipped", reason = "not a contribution uri" }
  end
  if not SYSTEM_DIDS[author] then
    return { status = "skipped", reason = "author is not a system identity" }
  end

  local contribution = load_record(contribution_uri)
  if not contribution then
    return { status = "skipped", reason = "contribution not indexed" }
  end
  if opts.cid and opts.cid ~= "" and opts.cid ~= contribution.cid then
    return { status = "skipped", reason = "contribution cid changed since it was queued" }
  end
  if has_record_for(REVIEW_COLLECTION, contribution_uri) then
    return { status = "skipped", reason = "already reviewed" }
  end

  local c = contribution.record
  local changes = c.changes or {}
  local subject = c.subject
  local is_new_game = subject == nil or subject == ""
  local result = { status = "applied", contributionType = c.contributionType }

  -- A newGame for a game the catalogue already has (an earlier run, or a
  -- second contribution for the same IGDB game) becomes an update.
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

  if subject then
    if did_of(subject) ~= pentaract.did then
      -- Owned games take changes through the owner's patch flow, not here.
      return { status = "skipped", reason = "subject is not in the Pentaract repo" }
    end
    if collection_of(subject) ~= GAME_COLLECTION then
      return { status = "skipped", reason = "subject is not a game" }
    end
  end

  local writes_game = false
  local media_deferred = false

  if create_rkey then
    if not changes.name or changes.name == "" or not changes.applicationType or changes.applicationType == "" then
      return { status = "skipped", reason = "newGame contribution lacks name or applicationType" }
    end
    subject = "at://" .. pentaract.did .. "/" .. GAME_COLLECTION .. "/" .. create_rkey
    local game, fields = effective_changes(changes, {})
    game["$type"] = GAME_COLLECTION
    game.createdAt = now()
    -- IGDB games have always been published on import.
    game.publishedAt = now()
    result.fields = fields
    result.created = true
    writes_game = true

    if not opts.dry_run then
      -- The slug goes in first so the game's index hook can see it.
      assign_slug(changes.name, subject)
      local create = function(rec)
        return pentaract:create_record({ collection = GAME_COLLECTION, rkey = create_rkey, record = rec })
      end
      local _, dropped = write_game(create, game, fields)
      if dropped then
        game.media = nil
        create(game)
        media_deferred = true
      end
    end
  else
    local current = load_record(subject)
    if not current then
      return { status = "skipped", reason = "subject game not found: " .. subject }
    end
    local diff, fields = effective_changes(changes, current.record)
    result.fields = fields
    if #fields == 0 then
      result.status = "noop"
    else
      writes_game = true
      if not opts.dry_run then
        local game = current.record
        local original_media = game.media
        for k, v in pairs(diff) do
          game[k] = v
        end
        game["$type"] = GAME_COLLECTION
        game.uri = nil
        game.cid = nil
        local put = function(rec)
          return pentaract:put_record({
            collection = GAME_COLLECTION,
            rkey = rkey_of(subject),
            record = rec,
            swap_cid = current.cid,
          })
        end
        local _, dropped = write_game(put, game, fields)
        if dropped then
          game.media = original_media
          put(game)
          media_deferred = true
        end
      end
    end
  end

  if media_deferred then
    result.mediaDeferred = true
  end
  result.subject = subject

  if opts.writes ~= "full" or opts.dry_run then
    return result
  end

  local ref = { uri = contribution_uri, cid = contribution.cid }

  -- A no-op gets a review but no verification: nothing was accepted from it.
  -- (A rerun after a failure between the game write and the verification
  -- also lands here, so that contribution goes uncredited. It is rare, and
  -- crediting every no-op would be worse.)
  if writes_game and not has_record_for(VERIFICATION_COLLECTION, contribution_uri) then
    pentaract:create_record({
      collection = VERIFICATION_COLLECTION,
      record = {
        ["$type"] = VERIFICATION_COLLECTION,
        contribution = ref,
        contributor = author,
        subject = subject,
        contributionType = c.contributionType,
        acceptedBy = "mod",
        createdAt = now(),
      },
    })
  end

  local reason = "Auto-accepted: contribution from a system identity."
  if result.status == "noop" then
    reason = "Auto-accepted: the game already matches this contribution."
  elseif media_deferred then
    reason = reason .. " Media was not applied: its blobs are not in the catalogue repo."
  end

  pentaract:create_record({
    collection = REVIEW_COLLECTION,
    record = {
      ["$type"] = REVIEW_COLLECTION,
      contribution = ref,
      status = "approved",
      reviewedBy = author,
      reason = reason,
      createdAt = now(),
    },
  })

  return result
end

local function resolve_writes(input)
  local writes = input.writes or env.AUTO_ACCEPT_WRITES or "full"
  if writes ~= "full" and writes ~= "game_only" then
    error("writes must be 'full' or 'game_only', got " .. tostring(writes))
  end
  return writes
end

local function system_did_list()
  local list = {}
  for d, _ in pairs(SYSTEM_DIDS) do
    table.insert(list, d)
  end
  table.sort(list)
  return list
end

local function sweep(input, opts)
  local limit = math.floor(tonumber(input.limit) or DEFAULT_SWEEP_LIMIT)
  if limit < 1 then
    limit = 1
  elseif limit > MAX_SWEEP_LIMIT then
    limit = MAX_SWEEP_LIMIT
  end

  local dids = system_did_list()
  if #dids == 0 then
    error("SYSTEM_DIDS is not configured")
  end

  -- Pending = no review yet, the same rule listContributions uses.
  local rows = db.raw(
    "SELECT c.uri FROM happyview_records c " ..
    "WHERE c.collection = 'games.gamesgamesgamesgames.contribution' " ..
    "AND c.did = ANY(string_to_array($1, ',')) " ..
    "AND c.uri > $2 " ..
    "AND NOT EXISTS (SELECT 1 FROM happyview_records r " ..
      "WHERE r.collection = 'games.gamesgamesgamesgames.contributionReview' " ..
      "AND r.record::jsonb->'contribution'->>'uri' = c.uri) " ..
    "ORDER BY c.uri LIMIT $3",
    { table.concat(dids, ","), input.after or "", limit }
  )

  local counts = { applied = 0, noop = 0, skipped = 0, failed = 0, mediaDeferred = 0 }
  local failures = {}
  local last = input.after

  for i, row in ipairs(rows or {}) do
    if job.should_stop() then
      break
    end

    local ok, res = pcall(process, row.uri, opts)
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
      if res.mediaDeferred then
        counts.mediaDeferred = counts.mediaDeferred + 1
      end
    end

    last = row.uri
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
  local res = process(input.uri, opts)
  log("contribution.auto-accept " .. input.uri .. ": " .. res.status .. (res.reason and (" (" .. res.reason .. ")") or ""))
  return res
end
