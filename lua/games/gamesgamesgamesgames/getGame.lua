function find_slug(target_uri)
  local did = string.match(target_uri, "at://([^/]+)/")
  if not did then return nil end
  local results = db.query({
    collection = "games.gamesgamesgamesgames.slug",
    did = did,
    limit = 50
  })
  if results.records then
    for _, record in ipairs(results.records) do
      if record.ref == target_uri then
        return record.slug
      end
    end
  end
  return nil
end

function handle()
  local uri = params.uri
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
    releases = record.releases,
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
