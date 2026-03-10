function handle()
  local profile = Record.new("games.gamesgamesgamesgames.actor.profile", {
    displayName = input.displayName,
    description = input.description,
    descriptionFacets = input.descriptionFacets,
    pronouns = input.pronouns,
    websites = input.websites,
    avatar = input.avatar,
    createdAt = input.createdAt or now()
  })
  profile:set_key_type("literal:self")
  profile:set_rkey("self")
  profile:save()

  return { uri = profile._uri, cid = profile._cid }
end
