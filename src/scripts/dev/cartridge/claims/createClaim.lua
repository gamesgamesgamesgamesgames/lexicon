local function get_admin_space_uri()
  local rows = db.raw(
    "SELECT authority_did FROM happyview_spaces WHERE type_nsid = 'dev.cartridge.claims.adminGroup' AND skey = 'self' LIMIT 1",
    {}
  )
  if not rows or #rows == 0 then return nil end
  return "at://" .. rows[1].authority_did .. "/space/dev.cartridge.claims.adminGroup/self"
end

function handle()
  if not input.type or (input.type ~= "game" and input.type ~= "org") then
    error("type must be 'game' or 'org'")
  end

  if not input.contact or input.contact == "" then
    error("contact is required")
  end

  if input.type == "game" then
    if not input.games or #input.games == 0 then
      error("games are required for game claims")
    end
  end

  if input.type == "org" then
    if not input.org or input.org == "" then
      error("org is required for org claims")
    end
  end

  local space_uri = "at://" .. caller_did .. "/space/dev.cartridge.claims.space/self"
  local space = atproto.spaces.get(space_uri)

  if not space then
    space = atproto.spaces.create{
      type = "dev.cartridge.claims.space",
      skey = "self",
      config = { membershipPublic = false, recordsPublic = false },
    }

    local admin_space_uri = get_admin_space_uri()
    if admin_space_uri then
      space:add_member{ did = admin_space_uri, access = "write", is_delegation = true }
    end
  end

  local claim_data = {
    type = input.type,
    createdAt = now(),
  }

  if input.games then
    claim_data.games = input.games
  end

  if input.org then
    claim_data.org = input.org
  end

  if input.message and input.message ~= "" then
    claim_data.message = input.message
  end

  claim_data.contact = input.contact

  local result = space:write_record{
    collection = "dev.cartridge.claims.claim",
    record = claim_data,
  }

  return { uri = result.uri }
end
