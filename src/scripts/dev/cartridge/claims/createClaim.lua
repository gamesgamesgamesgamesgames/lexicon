local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[#dids + 1] = did:match("^%s*(.-)%s*$")
  end
  return dids
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

    local admin_dids = parse_admin_dids()
    for _, admin_did in ipairs(admin_dids) do
      space:add_member{ did = admin_did, access = "write" }
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
