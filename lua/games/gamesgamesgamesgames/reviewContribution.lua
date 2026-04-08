local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

function handle()
  local PENTARACT_DID = env.PENTARACT_DID

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
    "SELECT uri, cid, record FROM records WHERE uri = $1 LIMIT 1",
    { contribution_uri }
  )

  if not contribution_rows or #contribution_rows == 0 then
    error("contribution not found: " .. contribution_uri)
  end

  local contribution_record = json.decode(contribution_rows[1].record)

  -- Check no existing review exists for this contribution
  local existing_review = db.raw(
    "SELECT uri FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionReview' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { contribution_uri }
  )

  if existing_review and #existing_review > 0 then
    error("contribution already has a review: " .. existing_review[1].uri)
  end

  -- Create contributionReview in Pentaract repo
  local review_data = {
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

  local review = Record.new("games.gamesgamesgamesgames.contributionReview", review_data)
  review:set_repo(PENTARACT_DID)
  review:save()

  -- If approved: create contributionPatch and contributionVerification
  if input.status == "approved" then
    local contributor_did = contribution_uri:match("^at://([^/]+)/")
    local subject = contribution_record.subject

    -- Create contributionPatch
    local patch_data = {
      contribution = {
        uri = input.contribution.uri,
        cid = input.contribution.cid,
      },
      contributionReview = {
        uri = review._uri,
        cid = review._cid,
      },
      subject = subject,
      changes = contribution_record.changes,
      createdAt = now(),
    }

    local patch = Record.new("games.gamesgamesgamesgames.contributionPatch", patch_data)
    patch:set_repo(PENTARACT_DID)
    patch:save()

    -- Create contributionVerification
    local verification_data = {
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

    local verification = Record.new("games.gamesgamesgamesgames.contributionVerification", verification_data)
    verification:set_repo(PENTARACT_DID)
    verification:save()
  end

  return { uri = review._uri }
end
