function handle()
  local collection = "games.gamesgamesgamesgames.actor.profile"
  local uri = "at://" .. caller_did .. "/" .. collection .. "/self"
  local profile = Record.load(uri)

  if not profile then
    profile = Record.new(collection, {})
    profile:set_key_type("literal:self")
    profile:set_rkey("self")
  end

  profile.displayName = input.displayName or profile.displayName
  profile.description = input.description or profile.description
  profile.descriptionFacets = input.descriptionFacets or profile.descriptionFacets
  profile.pronouns = input.pronouns or profile.pronouns
  profile.websites = input.websites or profile.websites
  profile.avatar = input.avatar or profile.avatar
  profile.createdAt = profile.createdAt or now()

  profile:save()

  return { uri = profile._uri, cid = profile._cid }
end
