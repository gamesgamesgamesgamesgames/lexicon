local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

-- Every record this script writes lands in the Pentaract repo, not the
-- caller's, so it needs a linked-repo grant over that account. HappyView can
-- only write to a repo it holds a session for.
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
  -- Verify caller is admin
  if not ADMIN_DIDS[caller_did] then
    error("unauthorized: only admins can review contributions")
  end

  -- Validate input
  if not input.contribution or not input.contribution.uri or not input.contribution.cid then
    error("contribution strongRef (uri + cid) is required")
  end

  if not input.status then
    error("status is required")
  end

  if input.status ~= "approved" and input.status ~= "denied" and input.status ~= "needsRevision" then
    error("status must be 'approved', 'denied', or 'needsRevision'")
  end

  -- Load the contribution record
  local contribution_uri = input.contribution.uri
  local contribution_rows = db.raw(
    "SELECT uri, cid, record FROM happyview_records WHERE uri = $1 LIMIT 1",
    { contribution_uri }
  )

  if not contribution_rows or #contribution_rows == 0 then
    error("contribution not found: " .. contribution_uri)
  end

  local contribution_record = json.decode(contribution_rows[1].record)

  -- Check no existing review exists for this contribution
  local existing_review = db.raw(
    "SELECT uri FROM happyview_records WHERE collection = 'games.gamesgamesgamesgames.contributionReview' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { contribution_uri }
  )

  if existing_review and #existing_review > 0 then
    error("contribution already has a review: " .. existing_review[1].uri)
  end

  local pentaract = pentaract_repo()
  local subject = contribution_record.subject
  local is_new_game = subject == nil or subject == ""

  -- A game in the Pentaract repo has no owner to accept a patch, and a new
  -- game belongs in the Pentaract repo until a studio claims it, so approving
  -- either applies the changes now. Games with a real owner get a patch for
  -- that owner to accept instead.
  local applies_now = input.status == "approved"
    and (is_new_game or subject:match("^at://([^/]+)/") == pentaract.did)

  -- The game is written before the review so a failed write (a concurrent
  -- edit tripping swap_cid, say) leaves the contribution reviewable again.
  if applies_now then
    local changes = contribution_record.changes or {}

    if is_new_game then
      if not changes.name or changes.name == "" then
        error("newGame contribution must include a name in changes")
      end
      if not changes.applicationType or changes.applicationType == "" then
        error("newGame contribution must include an applicationType in changes")
      end

      local game = apply_changes({ ["$type"] = GAME_COLLECTION, createdAt = now() }, changes)
      subject = pentaract:create_record({
        collection = GAME_COLLECTION,
        record = game,
      }).uri

      -- The game exists now, so a slug failure must not fail the approval:
      -- retrying would create the game a second time.
      local slug_ok, slug_err = pcall(assign_slug, changes.name, subject)
      if not slug_ok then
        log("warning: failed to assign a slug to " .. subject .. ": " .. tostring(slug_err))
      end
    else
      if subject:match("^at://[^/]+/([^/]+)/") ~= GAME_COLLECTION then
        error("only game contributions can be applied to the Pentaract repo: " .. subject)
      end

      local rows = db.raw(
        "SELECT cid, record FROM happyview_records WHERE uri = $1 LIMIT 1",
        { subject }
      )
      if not rows or #rows == 0 then
        error("subject entity not found: " .. subject)
      end

      local game = apply_changes(json.decode(rows[1].record), changes)
      game["$type"] = GAME_COLLECTION
      pentaract:put_record({
        collection = GAME_COLLECTION,
        rkey = subject:match("/([^/]+)$"),
        record = game,
        swap_cid = rows[1].cid,
      })
    end
  end

  -- Create contributionReview in Pentaract repo
  local review_data = {
    ["$type"] = "games.gamesgamesgamesgames.contributionReview",
    contribution = {
      uri = input.contribution.uri,
      cid = input.contribution.cid,
    },
    status = input.status,
    reviewedBy = caller_did,
    createdAt = now(),
  }

  if input.reason and input.reason ~= "" then
    review_data.reason = input.reason
  end

  local review = pentaract:create_record({
    collection = "games.gamesgamesgamesgames.contributionReview",
    record = review_data,
  })

  -- If approved: create contributionPatch (unless already applied) and
  -- contributionVerification
  if input.status == "approved" then
    local contributor_did = contribution_uri:match("^at://([^/]+)/")

    -- A patch is what an owner accepts; one that has been applied has nothing
    -- left to accept, just as acceptContribution deletes a patch once merged.
    if not applies_now then
      local patch_data = {
        ["$type"] = "games.gamesgamesgamesgames.contributionPatch",
        contribution = {
          uri = input.contribution.uri,
          cid = input.contribution.cid,
        },
        contributionReview = {
          uri = review.uri,
          cid = review.cid,
        },
        subject = subject,
        changes = contribution_record.changes,
        createdAt = now(),
      }

      pentaract:create_record({
        collection = "games.gamesgamesgamesgames.contributionPatch",
        record = patch_data,
      })
    end

    -- Create contributionVerification
    local verification_data = {
      ["$type"] = "games.gamesgamesgamesgames.contributionVerification",
      contribution = {
        uri = input.contribution.uri,
        cid = input.contribution.cid,
      },
      contributor = contributor_did,
      subject = subject,
      contributionType = contribution_record.contributionType,
      acceptedBy = "mod",
      createdAt = now(),
    }

    pentaract:create_record({
      collection = "games.gamesgamesgamesgames.contributionVerification",
      record = verification_data,
    })
  end

  return { uri = review.uri }
end
