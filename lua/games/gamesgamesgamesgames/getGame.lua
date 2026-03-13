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

-- Map of param name -> JSON path in record->'externalIds'
local EXTERNAL_ID_PARAMS = {
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

function resolve_external_id(param_name, value)
  local field = EXTERNAL_ID_PARAMS[param_name]
  if not field then return nil end
  local rows = db.raw(
    "SELECT uri FROM records WHERE collection = $1 AND record->'externalIds'->>'" .. field .. "' = $2 LIMIT 1",
    {"games.gamesgamesgamesgames.game", value}
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
    for param_name, _ in pairs(EXTERNAL_ID_PARAMS) do
      local value = params[param_name]
      if value and value ~= "" then
        uri = resolve_external_id(param_name, value)
        break
      end
    end
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
