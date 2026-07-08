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
  local is_admin = ADMIN_DIDS[caller_did]
  local rows

  if params.id and params.id ~= "" then
    rows = db.raw("SELECT * FROM verification_requests WHERE id = $1 LIMIT 1", { params.id })
  elseif params.requesterDid and params.requesterDid ~= "" then
    rows = db.raw(
      "SELECT * FROM verification_requests WHERE requester_did = $1 ORDER BY created_at DESC LIMIT 1",
      { params.requesterDid }
    )
  else
    -- Default: get caller's most recent request
    rows = db.raw(
      "SELECT * FROM verification_requests WHERE requester_did = $1 ORDER BY created_at DESC LIMIT 1",
      { caller_did }
    )
  end

  if not rows or #rows == 0 then
    return { request = nil }
  end

  local row = rows[1]

  -- Non-admins can only view their own requests
  if not is_admin and row.requester_did ~= caller_did then
    error("unauthorized: can only view your own verification requests")
  end

  local view = {
    ["$type"] = "dev.cartridge.getVerificationRequest#verificationRequestView",
    id = row.id,
    requesterDid = row.requester_did,
    accountType = row.account_type,
    message = row.message,
    status = row.status,
    createdAt = row.created_at,
  }

  -- Include contact for admins or the requester themselves
  if is_admin or row.requester_did == caller_did then
    view.contact = row.contact
  end

  if row.review_reason then
    view.reviewReason = row.review_reason
  end

  if row.reviewed_by then
    view.reviewedBy = row.reviewed_by
  end

  if row.reviewed_at then
    view.reviewedAt = row.reviewed_at
  end

  return { request = view }
end
