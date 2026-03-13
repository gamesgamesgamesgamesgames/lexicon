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

local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function resolve_external_id(field, value)
  local body = {
    q = "",
    limit = 1,
    filter = field .. ' = "' .. value .. '"',
    attributesToRetrieve = toarray({ "uri" })
  }

  local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
  if resp.status ~= 200 then return nil end

  local data = json.decode(resp.body)
  if data.hits and #data.hits > 0 then
    return data.hits[1].uri
  end
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
    if params.igdbId and params.igdbId ~= "" then uri = resolve_external_id("igdbId", params.igdbId)
    elseif params.steamId and params.steamId ~= "" then uri = resolve_external_id("steamId", params.steamId)
    elseif params.gogId and params.gogId ~= "" then uri = resolve_external_id("gogId", params.gogId)
    elseif params.epicGamesId and params.epicGamesId ~= "" then uri = resolve_external_id("epicGamesId", params.epicGamesId)
    elseif params.humbleBundleId and params.humbleBundleId ~= "" then uri = resolve_external_id("humbleBundleId", params.humbleBundleId)
    elseif params.playStationId and params.playStationId ~= "" then uri = resolve_external_id("playStationId", params.playStationId)
    elseif params.xboxId and params.xboxId ~= "" then uri = resolve_external_id("xboxId", params.xboxId)
    elseif params.nintendoEshopId and params.nintendoEshopId ~= "" then uri = resolve_external_id("nintendoEshopId", params.nintendoEshopId)
    elseif params.appleAppStoreId and params.appleAppStoreId ~= "" then uri = resolve_external_id("appleAppStoreId", params.appleAppStoreId)
    elseif params.googlePlayId and params.googlePlayId ~= "" then uri = resolve_external_id("googlePlayId", params.googlePlayId)
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
