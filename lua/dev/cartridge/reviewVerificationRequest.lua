local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

local function get_verifier_session()
  local pds_url = env.VERIFIER_PDS_URL
  local identifier = env.VERIFIER_DID
  local password = env.VERIFIER_APP_PASSWORD
  if not pds_url or not identifier or not password then
    error("VERIFIER_PDS_URL, VERIFIER_DID, and VERIFIER_APP_PASSWORD must all be configured")
  end

  local resp = http.post(pds_url .. "/xrpc/com.atproto.server.createSession", {
    headers = { ["content-type"] = "application/json" },
    body = json.encode({ identifier = identifier, password = password }),
  })

  if not resp or resp.status ~= 200 then
    local msg = resp and resp.body or "no response"
    error("failed to create verifier session: " .. msg)
  end

  local session = json.decode(resp.body)
  return session.accessJwt, session.did
end

local function create_record_as_verifier(pds_url, access_token, repo_did, collection, record_value)
  local resp = http.post(pds_url .. "/xrpc/com.atproto.repo.createRecord", {
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. access_token,
    },
    body = json.encode({
      repo = repo_did,
      collection = collection,
      record = record_value,
    }),
  })

  if not resp or resp.status ~= 200 then
    local msg = resp and resp.body or "no response"
    error("failed to create " .. collection .. " record: " .. msg)
  end

  return json.decode(resp.body)
end

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
    -- Resolve the requester's handle from their DID doc
    local requester_did = request.requester_did
    local resolved_handle = requester_did
    local did_doc_url
    if string.find(requester_did, "^did:web:") then
      local domain = requester_did:sub(9)
      did_doc_url = "https://" .. domain .. "/.well-known/did.json"
    else
      did_doc_url = "https://plc.directory/" .. requester_did
    end
    local did_resp = http.get(did_doc_url)
    if did_resp and did_resp.body and did_resp.body ~= "" then
      local doc = json.decode(did_resp.body)
      if doc and doc.alsoKnownAs then
        for _, aka in ipairs(doc.alsoKnownAs) do
          local h = aka:match("^at://(.+)")
          if h then
            resolved_handle = h
            break
          end
        end
      end
    end

    -- Look up display name from their actor profile record
    local display_name = resolved_handle
    local profile_results = db.query({
      collection = "games.gamesgamesgamesgames.actor.profile",
      did = requester_did,
      limit = 1
    })
    if profile_results.records and #profile_results.records > 0 then
      local pr = profile_results.records[1]
      if pr.value and pr.value.displayName and pr.value.displayName ~= "" then
        display_name = pr.value.displayName
      end
    end

    -- Authenticate as the verifier account via app password
    local access_token, verifier_did = get_verifier_session()
    local pds_url = env.VERIFIER_PDS_URL
    local created_at = now()

    -- Write app.bsky.graph.verification record from verifier account
    create_record_as_verifier(pds_url, access_token, verifier_did, "app.bsky.graph.verification", {
      ["$type"] = "app.bsky.graph.verification",
      subject = requester_did,
      handle = resolved_handle,
      displayName = display_name,
      createdAt = created_at,
    })

    -- Write dev.cartridge.graph.verification record from verifier account
    local cartridge_result = create_record_as_verifier(pds_url, access_token, verifier_did, "dev.cartridge.graph.verification", {
      ["$type"] = "dev.cartridge.graph.verification",
      subject = requester_did,
      handle = resolved_handle,
      displayName = display_name,
      accountType = request.account_type,
      createdAt = created_at,
    })

    verification_uri = cartridge_result.uri
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
