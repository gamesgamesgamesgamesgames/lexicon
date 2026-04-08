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
  local limit = params.limit or 25
  local status_filter = params.status
  local subject_filter = params.subject
  local contributor_filter = params.contributor
  local cursor_val = params.cursor

  -- Parse cursor: format "indexed_at|uri"
  local cursor_indexed_at = nil
  local cursor_uri = nil
  if cursor_val and cursor_val ~= "" then
    local pipe_pos = cursor_val:find("|", 1, true)
    if pipe_pos then
      cursor_indexed_at = cursor_val:sub(1, pipe_pos - 1)
      cursor_uri = cursor_val:sub(pipe_pos + 1)
    end
  end

  -- Build SQL dynamically
  local sql = ""
  local sql_params = {}
  local param_idx = 0

  local function next_param(val)
    param_idx = param_idx + 1
    sql_params[param_idx] = val
    return "$" .. param_idx
  end

  if status_filter == "pending" then
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at FROM records c " ..
          "WHERE c.collection = 'games.gamesgamesgamesgames.contribution' " ..
          "AND NOT EXISTS (" ..
            "SELECT 1 FROM records r WHERE r.collection = 'games.gamesgamesgamesgames.contributionReview' " ..
            "AND r.record::jsonb->'contribution'->>'uri' = c.uri" ..
          ")"
  elseif status_filter == "approved" or status_filter == "denied" or status_filter == "needsRevision" then
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at FROM records c " ..
          "INNER JOIN records r ON r.collection = 'games.gamesgamesgamesgames.contributionReview' " ..
          "AND r.record::jsonb->'contribution'->>'uri' = c.uri " ..
          "AND r.record::jsonb->>'status' = " .. next_param(status_filter) .. " " ..
          "WHERE c.collection = 'games.gamesgamesgamesgames.contribution'"
  else
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at FROM records c " ..
          "WHERE c.collection = 'games.gamesgamesgamesgames.contribution'"
  end

  -- Access control: non-admins see own contributions + contributions to their entities
  if not is_admin then
    sql = sql .. " AND (c.did = " .. next_param(caller_did) ..
          " OR c.record::jsonb->>'subject' IN (" ..
            "SELECT uri FROM records WHERE collection = 'games.gamesgamesgamesgames.game' AND did = " .. next_param(caller_did) ..
          "))"
  end

  -- Subject filter
  if subject_filter and subject_filter ~= "" then
    sql = sql .. " AND c.record::jsonb->>'subject' = " .. next_param(subject_filter)
  end

  -- Contributor filter
  if contributor_filter and contributor_filter ~= "" then
    sql = sql .. " AND c.did = " .. next_param(contributor_filter)
  end

  -- Cursor pagination
  if cursor_indexed_at and cursor_uri then
    sql = sql .. " AND (c.indexed_at, c.uri) < (" .. next_param(cursor_indexed_at) .. ", " .. next_param(cursor_uri) .. ")"
  end

  sql = sql .. " ORDER BY c.indexed_at DESC, c.uri DESC LIMIT " .. next_param(limit)

  local rows = db.raw(sql, sql_params)

  local contributions = {}
  local last_row = nil

  for _, row in ipairs(rows or {}) do
    local record = json.decode(row.record)
    local contributor_did = row.uri:match("^at://([^/]+)/")

    -- Resolve subject name
    local subject_name = nil
    if record.subject then
      local subject_record = db.get(record.subject)
      if subject_record then
        subject_name = subject_record.name
      end
    end

    local view = {
      ["$type"] = "games.gamesgamesgamesgames.getContribution#contributionView",
      uri = row.uri,
      cid = row.cid,
      contributorDid = contributor_did,
      contributionType = record.contributionType,
      subject = record.subject,
      subjectName = subject_name,
      changes = record.changes,
      message = record.message,
      createdAt = record.createdAt,
    }

    -- Look up associated review
    local review_rows = db.raw(
      "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionReview' " ..
      "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
      { row.uri }
    )

    if review_rows and #review_rows > 0 then
      local review_record = json.decode(review_rows[1].record)
      view.review = {
        ["$type"] = "games.gamesgamesgamesgames.getContribution#reviewView",
        uri = review_rows[1].uri,
        status = review_record.status,
        reviewedBy = review_record.reviewedBy,
        reason = review_record.reason,
        createdAt = review_record.createdAt,
      }
    end

    -- Look up associated verification
    local verification_rows = db.raw(
      "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
      "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
      { row.uri }
    )

    if verification_rows and #verification_rows > 0 then
      local verification_record = json.decode(verification_rows[1].record)
      view.verification = {
        ["$type"] = "games.gamesgamesgamesgames.getContribution#verificationView",
        uri = verification_rows[1].uri,
        contributor = verification_record.contributor,
        acceptedBy = verification_record.acceptedBy,
        createdAt = verification_record.createdAt,
      }
    end

    table.insert(contributions, view)
    last_row = row
  end

  -- Build cursor for next page
  local next_cursor = nil
  if last_row and #contributions == limit then
    next_cursor = last_row.indexed_at .. "|" .. last_row.uri
  end

  return { contributions = toarray(contributions), cursor = next_cursor }
end
