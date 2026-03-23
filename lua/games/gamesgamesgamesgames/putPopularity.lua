local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

function handle()
  if not ADMIN_DIDS[caller_did] then
    error("unauthorized: only admins can update popularity data")
  end

  if not input.games or #input.games == 0 then
    return { upserted = 0 }
  end

  local count = 0
  for _, game in ipairs(input.games) do
    if game.steamId and game.ccu then
      db.raw(
        "INSERT INTO game_popularity (steam_id, ccu, updated_at) VALUES ($1, $2, datetime('now')) ON CONFLICT (steam_id) DO UPDATE SET ccu = $2, updated_at = datetime('now')",
        { game.steamId, game.ccu }
      )
      count = count + 1
    end
  end

  return { upserted = count }
end
