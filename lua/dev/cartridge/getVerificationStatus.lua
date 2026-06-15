function handle()
  local handle_param = params.handle
  if not handle_param or handle_param == "" then
    return { isVerified = false }
  end

  local did = handle_param
  if not string.find(handle_param, "^did:") then
    local resp = xrpc.query("com.atproto.identity.resolveHandle", { handle = handle_param })
    if not resp or resp.status ~= 200 or not resp.body or resp.body == "" then
      return { isVerified = false }
    end
    local resolve_result = json.decode(resp.body)
    if not resolve_result or not resolve_result.did then
      return { isVerified = false }
    end
    did = resolve_result.did
  end

  local VERIFIER_DID = env.VERIFIER_DID
  if not VERIFIER_DID or VERIFIER_DID == "" then
    return { isVerified = false }
  end

  local v_rows = db.raw(
    "SELECT record FROM records WHERE collection = 'dev.cartridge.graph.verification' AND did = $1 AND record::jsonb->>'subject' = $2 LIMIT 1",
    { VERIFIER_DID, did }
  )

  if v_rows and #v_rows > 0 then
    local v_record = json.decode(v_rows[1].record)
    return { isVerified = true, accountType = v_record.accountType }
  end

  return { isVerified = false }
end
