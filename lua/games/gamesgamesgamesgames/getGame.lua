function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function resolve_release_platforms(releases)
  if not releases then return nil end

  for _, release in ipairs(releases) do
    if release.platformUri and not release.platform then
      local platform_record = db.get(release.platformUri)
      if platform_record then
        release.platform = platform_record.name
      end
    end
  end

  return releases
end

function resolve_slug(slug)
  local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", {slug})
  if rows and #rows > 0 then return rows[1].uri end
  return nil
end

local EXTERNAL_ID_SERVICES = {
  igdbId = "igdb",
  steamId = "steam",
  gogId = "gog",
  epicGamesId = "epicGames",
  humbleBundleId = "humbleBundle",
  playStationId = "playStation",
  xboxId = "xbox",
  nintendoEshopId = "nintendoEshop",
  appleAppStoreId = "appleAppStore",
  googlePlayId = "googlePlay",
}

function resolve_external_id(service, value)
  local rows = db.raw(
    "SELECT uri FROM external_ids WHERE service = $1 AND external_id = $2 LIMIT 1",
    { service, value }
  )
  if rows and #rows > 0 then return rows[1].uri end
  return nil
end

function handle()
  local uri = params.uri

  if params.slug and params.slug ~= "" then
    uri = resolve_slug(params.slug)
    if not uri then
      return { game = nil }
    end
  end

  -- Check external ID params if no uri or slug was provided
  if not uri or uri == "" then
    if params.igdbId and params.igdbId ~= "" then uri = resolve_external_id("igdb", params.igdbId)
    elseif params.steamId and params.steamId ~= "" then uri = resolve_external_id("steam", params.steamId)
    elseif params.gogId and params.gogId ~= "" then uri = resolve_external_id("gog", params.gogId)
    elseif params.epicGamesId and params.epicGamesId ~= "" then uri = resolve_external_id("epicGames", params.epicGamesId)
    elseif params.humbleBundleId and params.humbleBundleId ~= "" then uri = resolve_external_id("humbleBundle", params.humbleBundleId)
    elseif params.playStationId and params.playStationId ~= "" then uri = resolve_external_id("playStation", params.playStationId)
    elseif params.xboxId and params.xboxId ~= "" then uri = resolve_external_id("xbox", params.xboxId)
    elseif params.nintendoEshopId and params.nintendoEshopId ~= "" then uri = resolve_external_id("nintendoEshop", params.nintendoEshopId)
    elseif params.appleAppStoreId and params.appleAppStoreId ~= "" then uri = resolve_external_id("appleAppStore", params.appleAppStoreId)
    elseif params.googlePlayId and params.googlePlayId ~= "" then uri = resolve_external_id("googlePlay", params.googlePlayId)
    else return { game = nil }
    end
    if not uri then return { game = nil } end
  end

  local record = db.get(uri)

  if not record then
    return { game = nil }
  end

  local game = {
    ["$type"] = "games.gamesgamesgamesgames.defs#gameDetailView",
    uri = record.uri,
    name = record.name,
    summary = record.summary,
    applicationType = record.applicationType,
    createdAt = record.createdAt,
    publishedAt = record.publishedAt,
    parent = record.parent,
    storyline = record.storyline,
    genres = record.genres,
    modes = record.modes,
    themes = record.themes,
    playerPerspectives = record.playerPerspectives,
    releases = resolve_release_platforms(record.releases),
    media = record.media,
    keywords = record.keywords,
    websites = record.websites,
    videos = record.videos,
    alternativeNames = record.alternativeNames,
    timeToBeat = record.timeToBeat,
    ageRatings = record.ageRatings,
    languageSupports = record.languageSupports,
    multiplayerModes = record.multiplayerModes,
    engines = record.engines,
    externalIds = record.externalIds,
    slug = find_slug(record.uri)
  }

  -- Build collections by finding collection records that reference this game
  local backlinks = db.backlinks({
    collection = "games.gamesgamesgamesgames.collection",
    uri = record.uri,
    limit = 100
  })
  if backlinks and backlinks.records and #backlinks.records > 0 then
    local coll_uris = {}
    for _, coll in ipairs(backlinks.records) do
      table.insert(coll_uris, coll.uri)
    end
    game.collections = coll_uris
  end

  return { game = game }
end
