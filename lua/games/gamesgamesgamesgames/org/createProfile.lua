function handle()
  local profile = Record.new("games.gamesgamesgamesgames.org.profile", {
    displayName = input.displayName,
    description = input.description,
    descriptionFacets = input.descriptionFacets,
    country = input.country,
    status = input.status,
    parent = input.parent,
    foundedAt = input.foundedAt,
    websites = input.websites,
    media = input.media,
    avatar = input.avatar,
    createdAt = input.createdAt or now()
  })
  profile:set_key_type("literal:self")
  profile:set_rkey("self")
  profile:save()

  return { uri = profile._uri, cid = profile._cid }
end
