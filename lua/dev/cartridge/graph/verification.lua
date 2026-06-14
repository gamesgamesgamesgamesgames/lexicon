-- Trigger: record.delete:dev.cartridge.graph.verification
-- Fires when a dev.cartridge.graph.verification record is deleted from any repo.
-- Resets the matching verification_requests row so the dashboard reflects the revocation.

function handle()
  -- Look up the record before HappyView removes it so we can get the subject DID
  local rows = db.raw(
    "SELECT record FROM records WHERE uri = $1 LIMIT 1",
    { uri }
  )

  if rows and #rows > 0 then
    local rec = json.decode(rows[1].record)
    if rec and rec.subject then
      db.raw(
        "UPDATE verification_requests SET status = 'pending', reviewed_by = NULL, reviewed_at = NULL, review_reason = NULL WHERE requester_did = $1 AND status = 'approved'",
        { rec.subject }
      )
    end
  end

  -- Return truthy so HappyView proceeds with the delete
  return true
end
