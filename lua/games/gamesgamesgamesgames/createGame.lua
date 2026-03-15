function generate_slug(str)
  if not str or str == "" then
    return nil
  end

  local slug = str:lower()
  slug = slug:gsub("[^%w%s%-]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")

  if slug == "" then
    return nil
  end

  return slug
end

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
  -- Enrich externalIds: resolve Twitch ID from IGDB ID if missing
  local external_ids = input.externalIds
  if external_ids then
    if external_ids.igdb and (not external_ids.twitch or external_ids.twitch == "") then
      external_ids.twitch = resolve_twitch_id(external_ids.igdb)
    end
  end

  local game = Record.new("games.gamesgamesgamesgames.game", {
    name = input.name,
    summary = input.summary,
    applicationType = input.applicationType,
    genres = input.genres,
    modes = input.modes,
    themes = input.themes,
    playerPerspectives = input.playerPerspectives,
    releases = input.releases,
    media = input.media,
    parent = input.parent,
    storyline = input.storyline,
    keywords = input.keywords,
    websites = input.websites,
    videos = input.videos,
    alternativeNames = input.alternativeNames,
    timeToBeat = input.timeToBeat,
    ageRatings = input.ageRatings,
    languageSupports = input.languageSupports,
    multiplayerModes = input.multiplayerModes,
    engines = input.engines,
    externalIds = external_ids,
    createdAt = now()
  })

  if input.shouldPublish then
    game.publishedAt = now()
  end

  game:save()

  local slug_value = input.slug or generate_slug(input.name)
  if slug_value then
    db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO UPDATE SET uri = $2",
      {slug_value, game._uri})
  end

  return { uri = game._uri, cid = game._cid }
end
