function find_slug(target_uri)
  local rows = db.raw(
    "SELECT record FROM records WHERE collection = $1 AND record->>'ref' = $2 LIMIT 1",
    {"games.gamesgamesgamesgames.slug", target_uri}
  )
  if rows and #rows > 0 and rows[1].record then
    return rows[1].record.slug
  end
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
  local rows = db.raw(
    "SELECT uri, did, record FROM records WHERE collection = $1 AND rkey = $2 LIMIT 1",
    {"games.gamesgamesgamesgames.slug", slug}
  )
  if rows and #rows > 0 and rows[1].record and rows[1].record.ref then
    return rows[1].record.ref
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
    collections = record.collections,
    engines = record.engines,
    slug = find_slug(record.uri)
  }

  return { game = game }
end
