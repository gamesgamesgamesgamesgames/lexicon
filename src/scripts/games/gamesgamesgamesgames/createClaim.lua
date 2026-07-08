function handle()
  -- Validate input
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

  -- Create claim record in caller's repo
  local claim_data = {
    type = input.type,
    createdAt = now()
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

  -- Store contact directly on the record (filtered on output unless admin)
  claim_data.contact = input.contact

  local claim = Record.new("games.gamesgamesgamesgames.claim", claim_data)
  claim:save()

  return { uri = claim._uri }
end
