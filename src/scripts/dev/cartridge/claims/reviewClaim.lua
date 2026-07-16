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
  if not ADMIN_DIDS[caller_did] then
    error("unauthorized: only admins can review claims")
  end

  if not input.claim or not input.claim.uri or not input.claim.cid then
    error("claim strongRef (uri + cid) is required")
  end

  if not input.status or (input.status ~= "approved" and input.status ~= "denied") then
    error("status must be 'approved' or 'denied'")
  end

  local claim_uri = input.claim.uri
  local claimant_did = claim_uri:match("^at://([^/]+)/")
  if not claimant_did then
    error("invalid claim URI")
  end

  local space_uri = "at://" .. claimant_did .. "/space/dev.cartridge.claims.space/self"
  local space = atproto.spaces.get(space_uri)
  if not space then
    error("claimant has no claims space")
  end

  local claim_rows = db.raw(
    "SELECT uri FROM happyview_space_records WHERE uri = $1 AND collection = 'dev.cartridge.claims.claim' LIMIT 1",
    { claim_uri }
  )
  if not claim_rows or #claim_rows == 0 then
    error("claim not found in claimant's space")
  end

  if input.status == "approved" and input.approvedGames then
    for _, game_uri in ipairs(input.approvedGames) do
      local existing = db.raw(
        "SELECT sr.uri FROM happyview_space_records sr " ..
        "INNER JOIN happyview_spaces s ON s.id = sr.space_id AND s.type_nsid = 'dev.cartridge.claims.space' " ..
        "WHERE sr.collection = 'dev.cartridge.claims.claimReview' " ..
        "AND sr.record::jsonb->>'status' = 'approved' " ..
        "AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(sr.record::jsonb->'approvedGames') AS elem WHERE elem = $1) " ..
        "LIMIT 1",
        { game_uri }
      )
      if existing and #existing > 0 then
        error("game " .. game_uri .. " is already approved in another claim review: " .. existing[1].uri)
      end
    end
  end

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

  local result = space:write_record{
    collection = "dev.cartridge.claims.claimReview",
    record = review_data,
  }

  return { uri = result.uri }
end
