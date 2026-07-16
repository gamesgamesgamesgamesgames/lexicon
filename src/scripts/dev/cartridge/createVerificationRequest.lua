function handle()
  db.raw([[
    CREATE TABLE IF NOT EXISTS verification_requests (
      id TEXT PRIMARY KEY,
      requester_did TEXT NOT NULL,
      account_type TEXT NOT NULL,
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

  -- The account_type CHECK is gone: the taxonomy is open (see knownValues in the
  -- lexicon) and the validation below is the gate. The DO block only runs ALTER when
  -- the constraint is actually present, so the steady-state path takes no lock.
  -- pcall'd because this is Postgres-only; SQLite cannot drop a CHECK without a table
  -- rebuild, and fresh SQLite tables never have it.
  pcall(function()
    db.raw([[
      DO $$
      DECLARE cname TEXT;
      BEGIN
        SELECT con.conname INTO cname
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
         WHERE rel.relname = 'verification_requests'
           AND con.contype = 'c'
           AND pg_get_constraintdef(con.oid) ILIKE '%account_type%';
        IF cname IS NOT NULL THEN
          EXECUTE format('ALTER TABLE verification_requests DROP CONSTRAINT %I', cname);
        END IF;
      END $$;
    ]], {})
  end)

  -- Validate accountType. This is the only gate — the DB no longer constrains it.
  local VALID_ACCOUNT_TYPES = { studio = true, developer = true, publisher = true, game = true }

  if not input.accountType or not VALID_ACCOUNT_TYPES[input.accountType] then
    error("accountType must be one of: studio, developer, publisher, game")
  end

  if not input.message or input.message == "" then
    error("message is required")
  end

  if not input.contact or input.contact == "" then
    error("contact is required")
  end

  -- Generate a unique ID
  local id = TID()

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
