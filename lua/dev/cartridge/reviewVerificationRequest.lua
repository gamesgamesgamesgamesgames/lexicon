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
    error("unauthorized: only admins can review verification requests")
  end

  if not input.requestId or input.requestId == "" then
    error("requestId is required")
  end

  if not input.status or (input.status ~= "approved" and input.status ~= "denied") then
    error("status must be 'approved' or 'denied'")
  end

  -- Load the request
  local rows = db.raw("SELECT * FROM verification_requests WHERE id = $1 LIMIT 1", { input.requestId })
  if not rows or #rows == 0 then
    error("verification request not found")
  end

  local request = rows[1]

  if request.status ~= "pending" then
    error("verification request has already been reviewed")
  end

  local VERIFIER_DID = env.VERIFIER_DID
  if not VERIFIER_DID or VERIFIER_DID == "" then
    error("VERIFIER_DID is not configured")
  end

  local verification_uri = nil

  if input.status == "approved" then
    -- Resolve the requester's current handle and display name
    local profile = resolve_identity(request.requester_did)
    if not profile then
      error("could not resolve identity for " .. request.requester_did)
    end

    -- Write app.bsky.graph.verification record from verifier account
    local bsky_verification = Record.new("app.bsky.graph.verification", {
      subject = request.requester_did,
      handle = profile.handle,
      displayName = profile.displayName or profile.handle,
      createdAt = now(),
    })
    bsky_verification:set_repo(VERIFIER_DID)
    bsky_verification:save()

    -- Write dev.cartridge.graph.verification record from verifier account
    local cartridge_verification = Record.new("dev.cartridge.graph.verification", {
      subject = request.requester_did,
      handle = profile.handle,
      displayName = profile.displayName or profile.handle,
      accountType = request.account_type,
      createdAt = now(),
    })
    cartridge_verification:set_repo(VERIFIER_DID)
    cartridge_verification:save()

    verification_uri = cartridge_verification._uri
  end

  -- Update the request row
  local reason_sql = ""
  local update_params = { input.status, caller_did, now(), input.requestId }
  if input.reason and input.reason ~= "" then
    reason_sql = ", review_reason = $5"
    table.insert(update_params, input.reason)
  end

  db.raw(
    "UPDATE verification_requests SET status = $1, reviewed_by = $2, reviewed_at = $3" .. reason_sql .. " WHERE id = $4",
    update_params
  )

  local result = { requestId = input.requestId }
  if verification_uri then
    result.verificationUri = verification_uri
  end

  return result
end
