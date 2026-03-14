function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function resolve_release_platforms(releases)
  if not releases then return nil end

  for _, release in ipairs(releases) do
    local platform_uri = release.platformUri or release.platformURI
    if platform_uri and not release.platform then
      local platform_record = db.get(platform_uri)
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

  -- Organization credits
  if params.includeOrgCredits == true or params.includeOrgCredits == "true" then
    local org_backlinks = db.backlinks({
      collection = "games.gamesgamesgamesgames.org.credit",
      uri = record.uri,
      limit = 100
    })
    if org_backlinks and org_backlinks.records and #org_backlinks.records > 0 then
      local org_credits = {}
      for _, credit in ipairs(org_backlinks.records) do
        table.insert(org_credits, {
          ["$type"] = "games.gamesgamesgamesgames.defs#orgCreditView",
          uri = credit.uri,
          orgUri = credit.org and credit.org.uri or nil,
          displayName = credit.displayName,
          roles = credit.roles
        })
      end
      game.orgCredits = org_credits
    end
  end

  -- Actor credits
  if params.includeActorCredits == true or params.includeActorCredits == "true" then
    local actor_backlinks = db.backlinks({
      collection = "games.gamesgamesgamesgames.actor.credit",
      uri = record.uri,
      limit = 500
    })
    if actor_backlinks and actor_backlinks.records and #actor_backlinks.records > 0 then
      local actor_credits = {}
      for _, credit in ipairs(actor_backlinks.records) do
        table.insert(actor_credits, {
          ["$type"] = "games.gamesgamesgamesgames.defs#actorCreditView",
          uri = credit.uri,
          actorUri = credit.actor and credit.actor.uri or nil,
          displayName = credit.displayName,
          credits = credit.credits
        })
      end
      game.actorCredits = actor_credits
    end
  end

  return { game = game }
end
