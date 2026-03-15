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

  game.name = input.name
  game.summary = input.summary
  game.applicationType = input.applicationType
  game.genres = input.genres
  game.modes = input.modes
  game.themes = input.themes
  game.playerPerspectives = input.playerPerspectives
  game.releases = input.releases
  game.media = input.media
  game.parent = input.parent
  game.createdAt = input.createdAt or game.createdAt
  game.storyline = input.storyline
  game.keywords = input.keywords
  game.websites = input.websites
  game.videos = input.videos
  game.alternativeNames = input.alternativeNames
  game.timeToBeat = input.timeToBeat
  game.ageRatings = input.ageRatings
  game.languageSupports = input.languageSupports
  game.multiplayerModes = input.multiplayerModes
  game.engines = input.engines

  -- Enrich externalIds: resolve Twitch ID from IGDB ID if missing
  local external_ids = input.externalIds or game.externalIds
  if external_ids then
    if external_ids.igdb and (not external_ids.twitch or external_ids.twitch == "") then
      external_ids.twitch = resolve_twitch_id(external_ids.igdb)
    end
  end
  game.externalIds = external_ids

  if input.shouldPublish and not game.publishedAt then
    game.publishedAt = now()
  end

  game:save()

  if input.slug then
    db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO UPDATE SET uri = $2",
      {input.slug, game._uri})
  end

  return { uri = game._uri, cid = game._cid }
end
