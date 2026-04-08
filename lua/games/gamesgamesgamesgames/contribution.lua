-- Index hook for contribution records.
-- Only indexes contributions with a valid inline attestation signature.

function handle()
  if action == "delete" then
    return true
  end

  -- Verify inline attestation signature from HappyView
  if not record.signatures or #record.signatures == 0 then
    return nil  -- Skip unattested contributions
  end

  -- Verify at least one signature is from our HappyView instance
  local valid = false
  for _, sig in ipairs(record.signatures) do
    if atproto.verify_signature(record, sig, did) then
      valid = true
      break
    end
  end

  if not valid then
    return nil  -- Skip contributions with invalid/unknown signatures
  end

  return record
end
