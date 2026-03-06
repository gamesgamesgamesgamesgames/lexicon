function find_slug(target_uri)
  local results = db.query({
    collection = "games.gamesgamesgamesgames.slug",
    did = caller_did,
    limit = 100
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
  local actor_results = db.query({
    collection = "games.gamesgamesgamesgames.actor.profile",
    did = caller_did,
    limit = 1
  })

  if actor_results.records and #actor_results.records > 0 then
    local record = actor_results.records[1]
    local slug = find_slug(record.uri)
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#actorProfileDetailView",
      uri = record.uri,
      did = caller_did,
      displayName = record.displayName,
      description = record.description,
      descriptionFacets = record.descriptionFacets,
      pronouns = record.pronouns,
      slug = slug,
      websites = record.websites,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile, profileType = "actor" }
  end

  local org_results = db.query({
    collection = "games.gamesgamesgamesgames.org.profile",
    did = caller_did,
    limit = 1
  })

  if org_results.records and #org_results.records > 0 then
    local record = org_results.records[1]
    local slug = find_slug(record.uri)
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#orgProfileDetailView",
      uri = record.uri,
      did = caller_did,
      displayName = record.displayName,
      description = record.description,
      descriptionFacets = record.descriptionFacets,
      country = record.country,
      status = record.status,
      parent = record.parent,
      foundedAt = record.foundedAt,
      slug = slug,
      websites = record.websites,
      media = record.media,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile, profileType = "org" }
  end

  return { profile = nil, profileType = nil }
end
