function handle()
  local query_params = {}
  if params.handle and params.handle ~= "" then
    query_params.handle = params.handle
  end

  local resp = xrpc.query("games.gamesgamesgamesgames.getProfile", query_params)
  local result
  if resp and resp.status == 200 and resp.body and resp.body ~= "" then
    result = json.decode(resp.body)
  else
    result = { profile = nil, profileType = nil }
  end

  local roles = {}

  if caller_did and caller_did ~= "" then
    local superadmin = env.CARTRIDGE_SUPERADMIN_DID
    if superadmin and superadmin ~= "" and caller_did == superadmin then
      table.insert(roles, "superadmin")
    end

    local admin_rows = db.raw(
      "SELECT owner_did FROM happyview_spaces WHERE type_nsid = 'dev.cartridge.claims.adminGroup' AND skey = 'self' LIMIT 1",
      {}
    )
    if admin_rows and #admin_rows > 0 then
      local admin_space_uri = "at://" .. admin_rows[1].owner_did .. "/space/dev.cartridge.claims.adminGroup/self"
      if atproto.spaces.is_member(admin_space_uri, caller_did) then
        table.insert(roles, "admin")
      end
    end
  end

  result.roles = toarray(roles)
  return result
end
