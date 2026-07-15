function handle()
  local PENTARACT_DID = env.PENTARACT_DID

  local claim_uri = input.claim
  local review_uri = input.claimReview

  if not claim_uri or claim_uri == "" then
    error("claim URI is required")
  end
  if not review_uri or review_uri == "" then
    error("claimReview URI is required")
  end

  -- Verify claim belongs to caller
  local claim_did = claim_uri:match("^at://([^/]+)/")
  if claim_did ~= caller_did then
    error("unauthorized: claim does not belong to caller")
  end

  -- Load the claim
  local claim_record = db.get(claim_uri)
  if not claim_record then
    error("claim not found")
  end

  -- Load the review and verify
  local review_record = db.get(review_uri)
  if not review_record then
    error("claimReview not found")
  end

  if review_record.status ~= "approved" then
    error("claim review is not approved")
  end

  if not review_record.claim or review_record.claim.uri ~= claim_uri then
    error("claimReview does not match the provided claim")
  end

  local approved_games = review_record.approvedGames or {}

  -- Extract org info for org claims
  local org_uri = nil
  local org_did = nil
  if claim_record.type == "org" and claim_record.org then
    org_uri = claim_record.org
    org_did = org_uri:match("^at://([^/]+)/")
  end

  -- Enqueue migration job
  local job_id = jobs.create("migration.claim", {
    claim_type = claim_record.type,
    claim_uri = claim_uri,
    review_uri = review_uri,
    approved_games = approved_games,
    org_uri = org_uri,
    org_did = org_did,
  }, { auth = true })

  return {
    jobId = job_id,
    status = "pending",
    gamesCount = #approved_games,
  }
end
