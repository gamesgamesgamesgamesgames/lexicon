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

  local slug_value = input.slug or generate_slug(input.displayName)
  if slug_value then
    local slug = Record.new("games.gamesgamesgamesgames.slug", {
      slug = slug_value,
      ref = profile._uri
    })
    slug:set_rkey(slug_value)
    slug:save()
  end

  return { uri = profile._uri, cid = profile._cid }
end
