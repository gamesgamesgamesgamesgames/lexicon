-- Ensure verification_requests table exists
db.raw([[
  CREATE TABLE IF NOT EXISTS verification_requests (
    id TEXT PRIMARY KEY,
    requester_did TEXT NOT NULL,
    account_type TEXT NOT NULL CHECK (account_type IN ('studio', 'developer', 'publisher')),
    message TEXT NOT NULL,
    contact TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
    review_reason TEXT,
    reviewed_by TEXT,
    reviewed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (now())
  )
]], {})

db.raw([[
  CREATE UNIQUE INDEX IF NOT EXISTS verification_requests_one_pending
    ON verification_requests (requester_did)
    WHERE status = 'pending'
]], {})

db.raw([[
  CREATE INDEX IF NOT EXISTS idx_verification_requests_requester
    ON verification_requests (requester_did)
]], {})

db.raw([[
  CREATE INDEX IF NOT EXISTS idx_verification_requests_status
    ON verification_requests (status)
]], {})

function handle()
  -- Validate accountType
  if not input.accountType or (input.accountType ~= "studio" and input.accountType ~= "developer" and input.accountType ~= "publisher") then
    error("accountType must be 'studio', 'developer', or 'publisher'")
  end

  if not input.message or input.message == "" then
    error("message is required")
  end

  if not input.contact or input.contact == "" then
    error("contact is required")
  end

  -- Generate a unique ID
  local id = generate_tid()

  -- Insert into verification_requests table
  -- The partial unique index (verification_requests_one_pending) enforces one pending request per account
  local ok, err = pcall(function()
    db.raw(
      "INSERT INTO verification_requests (id, requester_did, account_type, message, contact) VALUES ($1, $2, $3, $4, $5)",
      { id, caller_did, input.accountType, input.message, input.contact }
    )
  end)

  if not ok then
    if err and tostring(err):find("UNIQUE") then
      error("you already have a pending verification request")
    end
    error("failed to create verification request: " .. tostring(err))
  end

  return { id = id }
end
