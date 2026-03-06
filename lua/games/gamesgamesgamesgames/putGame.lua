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
  game.collections = input.collections
  game.engines = input.engines

  if input.shouldPublish and not game.publishedAt then
    game.publishedAt = now()
  end

  game:save()

  return { uri = game._uri, cid = game._cid }
end
