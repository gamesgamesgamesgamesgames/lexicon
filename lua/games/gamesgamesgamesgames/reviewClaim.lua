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
    error("unauthorized: only admins can review claims")
  end

  -- Validate input
  if not input.claim or not input.claim.uri or not input.claim.cid then
    error("claim strongRef (uri + cid) is required")
  end

  if not input.status or (input.status ~= "approved" and input.status ~= "denied") then
    error("status must be 'approved' or 'denied'")
  end

  -- If approving, check that each approved game isn't already approved in another claimReview
  if input.status == "approved" and input.approvedGames then
    for _, game_uri in ipairs(input.approvedGames) do
      local existing = db.raw(
        "SELECT uri FROM records WHERE collection = 'games.gamesgamesgamesgames.claimReview' AND record->>'status' = 'approved' AND record->'approvedGames' ? $1 LIMIT 1",
        { game_uri }
      )
      if existing and #existing > 0 then
        error("game " .. game_uri .. " is already approved in another claim review: " .. existing[1].uri)
      end
    end
  end

  -- Create claimReview in pentaract's repo
  local review_data = {
    claim = {
      uri = input.claim.uri,
      cid = input.claim.cid,
    },
    status = input.status,
    reviewedBy = caller_did,
    createdAt = now(),
  }

  if input.approvedGames then
    review_data.approvedGames = input.approvedGames
  end

  if input.reason and input.reason ~= "" then
    review_data.reason = input.reason
  end

  local review = Record.new("games.gamesgamesgamesgames.claimReview", review_data)
  review:set_repo(PENTARACT_DID)
  review:save()

  return { uri = review._uri }
end
