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

function handle()
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
