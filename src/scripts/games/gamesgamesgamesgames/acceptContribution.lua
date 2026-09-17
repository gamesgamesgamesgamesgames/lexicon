local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

-- Contribution patches and verifications live in the Pentaract repo, not the
-- caller's, so touching them needs a linked-repo grant over that account.
-- HappyView can only write to a repo it holds a session for.
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

local function did_from_uri(uri)
  return uri:match("^at://([^/]+)/")
end

local GAME_COLLECTION = "games.gamesgamesgamesgames.game"

-- `changes` is an unknown-typed blob, and linked-repo writes are not validated
-- against the game lexicon, so only these fields may be copied onto a game.
local GAME_FIELDS = {
  "name", "summary", "applicationType", "genres", "modes", "themes",
  "playerPerspectives", "releases", "media", "parent", "storyline", "keywords",
  "websites", "videos", "alternativeNames", "timeToBeat", "ageRatings",
  "languageSupports", "multiplayerModes", "engines", "externalIds",
  "description", "descriptionFacets", "systemRequirements", "platformFeatures",
}

local function apply_changes(record, changes)
  for _, field in ipairs(GAME_FIELDS) do
    if changes[field] ~= nil then
      record[field] = changes[field]
    end
  end
  return record
end

-- Same rules as createGame's generate_slug.
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

-- createGame lets its caller take over a slug that is already in use. A
-- community-submitted game must not repoint another game's slug, so a taken
-- slug gets a numeric suffix instead.
local function assign_slug(name, uri)
  local base = generate_slug(name)
  if not base then
    return
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
end

function handle()
  -- Validate input
  if not input.contributionPatch or input.contributionPatch == "" then
    error("contributionPatch URI is required")
  end

  -- Load the patch record
  local patch_rows = db.raw(
    "SELECT uri, record FROM happyview_records WHERE uri = $1 AND collection = 'games.gamesgamesgamesgames.contributionPatch' LIMIT 1",
    { input.contributionPatch }
  )

  if not patch_rows or #patch_rows == 0 then
    error("contributionPatch not found: " .. input.contributionPatch)
  end

  local patch_record = json.decode(patch_rows[1].record)
  local subject_uri = patch_record.subject
  local changes = patch_record.changes or {}
  local is_new_game = (subject_uri == nil or subject_uri == "")
  local entity_uri

  -- reviewContribution applies new games and Pentaract-owned games on
  -- approval, so a patch for one only exists if it was approved before that.
  -- There is no owner to accept it, so an admin does, through the grant.
  local via_pentaract = is_new_game or did_from_uri(subject_uri) == env.PENTARACT_DID

  if via_pentaract then
    if not ADMIN_DIDS[caller_did] then
      error("unauthorized: only admins can accept patches to games in the Pentaract repo")
    end

    local pentaract = pentaract_repo()

    if is_new_game then
      if not changes.name or changes.name == "" then
        error("newGame contribution must include a name in changes")
      end
      if not changes.applicationType or changes.applicationType == "" then
        error("newGame contribution must include an applicationType in changes")
      end

      local game = apply_changes({ ["$type"] = GAME_COLLECTION, createdAt = now() }, changes)
      entity_uri = pentaract:create_record({
        collection = GAME_COLLECTION,
        record = game,
      }).uri

      -- The game exists now, so a slug failure must not fail the acceptance:
      -- retrying would create the game a second time.
      local slug_ok, slug_err = pcall(assign_slug, changes.name, entity_uri)
      if not slug_ok then
        log("warning: failed to assign a slug to " .. entity_uri .. ": " .. tostring(slug_err))
      end
    else
      if subject_uri:match("^at://[^/]+/([^/]+)/") ~= GAME_COLLECTION then
        error("only game contributions can be applied to the Pentaract repo: " .. subject_uri)
      end

      local rows = db.raw(
        "SELECT cid, record FROM happyview_records WHERE uri = $1 LIMIT 1",
        { subject_uri }
      )
      if not rows or #rows == 0 then
        error("subject entity not found: " .. subject_uri)
      end

      local game = apply_changes(json.decode(rows[1].record), changes)
      game["$type"] = GAME_COLLECTION
      pentaract:put_record({
        collection = GAME_COLLECTION,
        rkey = subject_uri:match("/([^/]+)$"),
        record = game,
        swap_cid = rows[1].cid,
      })
      entity_uri = subject_uri
    end
  else
    -- correction/addition: verify ownership and patch existing record
    if did_from_uri(subject_uri) ~= caller_did then
      error("unauthorized: you do not own the subject entity")
    end

    local entity = Record.load(subject_uri)
    if not entity then
      error("subject entity not found: " .. subject_uri)
    end

    apply_changes(entity, changes)
    entity:save()
    entity_uri = entity._uri
  end

  -- Update contributionVerification: set acceptedBy to "both"
  local contribution_uri = patch_record.contribution.uri
  local verification_rows = db.raw(
    "SELECT uri, record FROM happyview_records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { contribution_uri }
  )

  if verification_rows and #verification_rows > 0 then
    local verification_uri = verification_rows[1].uri
    local verification_did = did_from_uri(verification_uri)

    -- reviewContribution writes verifications into the Pentaract repo. Going
    -- through Record.load():save() here would write to the *caller's* repo
    -- instead, because Record.load clears the repo override.
    if verification_did ~= env.PENTARACT_DID then
      error("contributionVerification " .. verification_uri ..
            " is not in the Pentaract repo; refusing to guess where to write it")
    end

    local verification = json.decode(verification_rows[1].record)
    verification["$type"] = "games.gamesgamesgamesgames.contributionVerification"
    -- Only an owner's acceptance counts towards ownerAccepted; an admin
    -- accepting on the Pentaract repo's behalf leaves it as a mod acceptance.
    if not via_pentaract then
      verification.acceptedBy = "both"
    end
    if is_new_game then
      verification.subject = entity_uri
    end

    pentaract_repo():put_record({
      collection = "games.gamesgamesgamesgames.contributionVerification",
      rkey = verification_uri:match("/([^/]+)$"),
      record = verification,
    })
  end

  -- Delete the patch record (it's been merged)
  local patch_rkey = input.contributionPatch:match("/([^/]+)$")
  if patch_rkey then
    -- The patch lives in the Pentaract repo. Deleting it from the local index
    -- alone used to leave the PDS record behind.
    local ok, err = pcall(function()
      pentaract_repo():delete_record({
        collection = "games.gamesgamesgamesgames.contributionPatch",
        rkey = patch_rkey,
      })
    end)
    if not ok then
      log("warning: failed to delete contributionPatch from the Pentaract repo: " .. tostring(err))
    end

    -- Drop it from the index regardless: the patch has been merged and should
    -- not resurface even if the PDS delete failed.
    pcall(function()
      db.raw(
        "DELETE FROM happyview_records WHERE uri = $1",
        { input.contributionPatch }
      )
    end)
  end

  return { uri = entity_uri }
end
