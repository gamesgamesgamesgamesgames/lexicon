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
    error("unauthorized: only admins can list verification requests")
  end

  local limit = params.limit or 25
  local status_filter = params.status
  local cursor_val = params.cursor

  -- Parse cursor: format "created_at|id"
  local cursor_created_at = nil
  local cursor_id = nil
  if cursor_val and cursor_val ~= "" then
    local pipe_pos = cursor_val:find("|", 1, true)
    if pipe_pos then
      cursor_created_at = cursor_val:sub(1, pipe_pos - 1)
      cursor_id = cursor_val:sub(pipe_pos + 1)
    end
  end

  -- Build SQL dynamically
  local sql_parts = { "SELECT * FROM verification_requests WHERE 1=1" }
  local sql_params = {}
  local param_idx = 0

  local function next_param(val)
    param_idx = param_idx + 1
    sql_params[param_idx] = val
    return "$" .. param_idx
  end

  if status_filter and status_filter ~= "" then
    table.insert(sql_parts, " AND status = " .. next_param(status_filter))
  end

  if cursor_created_at and cursor_id then
    table.insert(sql_parts, " AND (created_at, id) < (" .. next_param(cursor_created_at) .. ", " .. next_param(cursor_id) .. ")")
  end

  table.insert(sql_parts, " ORDER BY created_at DESC, id DESC LIMIT " .. next_param(limit))

  local sql = table.concat(sql_parts)
  local rows = db.raw(sql, sql_params)

  local requests = {}
  local last_row = nil

  for _, row in ipairs(rows or {}) do
    local view = {
      ["$type"] = "dev.cartridge.getVerificationRequest#verificationRequestView",
      id = row.id,
      requesterDid = row.requester_did,
      accountType = row.account_type,
      message = row.message,
      contact = row.contact,
      status = row.status,
      createdAt = row.created_at,
    }

    if row.review_reason then
      view.reviewReason = row.review_reason
    end
    if row.reviewed_by then
      view.reviewedBy = row.reviewed_by
    end
    if row.reviewed_at then
      view.reviewedAt = row.reviewed_at
    end

    table.insert(requests, view)
    last_row = row
  end

  local next_cursor = nil
  if last_row and #requests == limit then
    next_cursor = last_row.created_at .. "|" .. last_row.id
  end

  return { requests = toarray(requests), cursor = next_cursor }
end
