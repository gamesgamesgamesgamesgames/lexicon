function resolve_twitch_id(igdb_id)
  if not igdb_id or igdb_id == "" then return nil end
  if not env.TWITCH_CLIENT_ID or not env.TWITCH_ACCESS_TOKEN then return nil end

  local resp = http.get("https://api.twitch.tv/helix/games?igdb_id=" .. igdb_id, {
    headers = {
      ["Client-ID"] = env.TWITCH_CLIENT_ID,
      ["Authorization"] = "Bearer " .. env.TWITCH_ACCESS_TOKEN,
    }
  })

  if resp and resp.status == 200 then
    local body = json.decode(resp.body)
    if body and body.data and #body.data > 0 then
      return body.data[1].id
    end
  end

  return nil
end

function handle()
  local game = Record.load(input.uri)

  if not game then
    return { error = "not found" }
  end

  -- Only update fields that were provided
  if input.name ~= nil then game.name = input.name end
  if input.summary ~= nil then game.summary = input.summary end
  if input.applicationType ~= nil then game.applicationType = input.applicationType end
  if input.genres ~= nil then game.genres = input.genres end
  if input.modes ~= nil then game.modes = input.modes end
  if input.themes ~= nil then game.themes = input.themes end
  if input.playerPerspectives ~= nil then game.playerPerspectives = input.playerPerspectives end
  if input.releases ~= nil then game.releases = input.releases end
  if input.media ~= nil then game.media = input.media end
  if input.parent ~= nil then game.parent = input.parent end
  if input.createdAt ~= nil then game.createdAt = input.createdAt end
  if input.storyline ~= nil then game.storyline = input.storyline end
  if input.keywords ~= nil then game.keywords = input.keywords end
  if input.websites ~= nil then game.websites = input.websites end
  if input.videos ~= nil then game.videos = input.videos end
  if input.alternativeNames ~= nil then game.alternativeNames = input.alternativeNames end
  if input.timeToBeat ~= nil then game.timeToBeat = input.timeToBeat end
  if input.ageRatings ~= nil then game.ageRatings = input.ageRatings end
  if input.languageSupports ~= nil then game.languageSupports = input.languageSupports end
  if input.multiplayerModes ~= nil then game.multiplayerModes = input.multiplayerModes end
  if input.engines ~= nil then game.engines = input.engines end

  -- Enrich externalIds: resolve Twitch ID from IGDB ID if missing
  if input.externalIds ~= nil then
    local external_ids = input.externalIds
    if external_ids.igdb and (not external_ids.twitch or external_ids.twitch == "") then
      external_ids.twitch = resolve_twitch_id(external_ids.igdb)
    end
    game.externalIds = external_ids
  end

  if input.shouldPublish and not game.publishedAt then
    game.publishedAt = now()
  end

  -- Only save the record if any record fields changed (not just slug)
  local has_record_changes = false
  for k, _ in pairs(input) do
    if k ~= "uri" and k ~= "slug" and k ~= "shouldPublish" then
      has_record_changes = true
      break
    end
  end

  if has_record_changes then
    game:save()
  end

  if input.slug then
    db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO UPDATE SET uri = $2",
      {input.slug, game._uri})
  end

  return { uri = game._uri, cid = game._cid }
end
