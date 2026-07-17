function handle()
  local superadmin = env.CARTRIDGE_SUPERADMIN_DID
  if not superadmin or superadmin == "" then
    error("CARTRIDGE_SUPERADMIN_DID is not configured")
  end

  if caller_did ~= superadmin then
    error("unauthorized: only the superadmin can manage the admin space")
  end

  local rows = db.raw(
    "SELECT authority_did FROM happyview_spaces WHERE type_nsid = 'dev.cartridge.claims.adminGroup' AND skey = 'self' LIMIT 1",
    {}
  )

  local space
  local created = false
  local space_uri

  if rows and #rows > 0 then
    space_uri = "at://" .. rows[1].authority_did .. "/space/dev.cartridge.claims.adminGroup/self"
    space = atproto.spaces.get(space_uri)
    if not space then
      error("admin space record exists but could not be loaded")
    end
  else
    space = atproto.spaces.create{
      type = "dev.cartridge.claims.adminGroup",
      skey = "self",
      config = { membershipPublic = false, recordsPublic = false },
    }
    created = true
    space_uri = "at://" .. caller_did .. "/space/dev.cartridge.claims.adminGroup/self"

    if not space:is_member(superadmin) then
      space:add_member{ did = superadmin, access = "write" }
    end
  end

  local member_added = false
  if input.adminDid and input.adminDid ~= "" then
    if not space:is_member(input.adminDid) then
      space:add_member{ did = input.adminDid, access = "write" }
      member_added = true
    end
  end

  return {
    spaceUri = space_uri,
    created = created,
    memberAdded = member_added,
  }
end
