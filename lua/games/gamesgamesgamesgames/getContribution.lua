function handle()
  local uri = params.uri
  if not uri or uri == "" then
    error("uri is required")
  end

  -- Load contribution record
  local rows = db.raw(
    "SELECT uri, cid, record FROM records WHERE uri = $1 LIMIT 1",
    { uri }
  )

  if not rows or #rows == 0 then
    error("contribution not found")
  end

  local row = rows[1]
  local record = json.decode(row.record)

  -- Extract contributor DID from URI
  local contributor_did = uri:match("^at://([^/]+)/")

  -- Resolve subject name for display
  local subject_name = nil
  if record.subject then
    local subject_record = db.get(record.subject)
    if subject_record then
      subject_name = subject_record.name
    end
  end

  -- Build base contribution view
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

  -- Look up associated contributionReview
  local review_rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionReview' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { uri }
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

  -- Look up associated contributionPatch
  local patch_rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionPatch' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { uri }
  )

  if patch_rows and #patch_rows > 0 then
    local patch_record = json.decode(patch_rows[1].record)
    view.patch = {
      ["$type"] = "games.gamesgamesgamesgames.getContribution#patchView",
      uri = patch_rows[1].uri,
      subject = patch_record.subject,
      changes = patch_record.changes,
      createdAt = patch_record.createdAt,
    }
  end

  -- Look up associated contributionVerification
  local verification_rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { uri }
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

  return { contribution = view }
end
