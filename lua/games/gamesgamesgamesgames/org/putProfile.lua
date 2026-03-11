function handle()
  local collection = "games.gamesgamesgamesgames.org.profile"
  local uri = "at://" .. ctx.did .. "/" .. collection .. "/self"
  local profile = Record.load(uri)

  if not profile then
    profile = Record.new(collection, {})
    profile:set_key_type("literal:self")
    profile:set_rkey("self")
  end

  profile.displayName = input.displayName or profile.displayName
  profile.description = input.description or profile.description
  profile.descriptionFacets = input.descriptionFacets or profile.descriptionFacets
  profile.country = input.country or profile.country
  profile.status = input.status or profile.status
  profile.parent = input.parent or profile.parent
  profile.foundedAt = input.foundedAt or profile.foundedAt
  profile.websites = input.websites or profile.websites
  profile.media = input.media or profile.media
  profile.avatar = input.avatar or profile.avatar
  profile.createdAt = profile.createdAt or now()

  profile:save()

  return { uri = profile._uri, cid = profile._cid }
end
