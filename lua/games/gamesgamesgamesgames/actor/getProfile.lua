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
  local results = db.query({
    collection = "games.gamesgamesgamesgames.actor.profile",
    did = caller_did,
    limit = 1
  })
  if results.records and #results.records > 0 then
    local record = results.records[1]
    local slug = find_slug(record.uri)
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#actorProfileDetailView",
      uri = record.uri,
      did = caller_did,
      displayName = record.displayName,
      description = record.description,
      pronouns = record.pronouns,
      slug = slug,
      websites = record.websites,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile }
  end
  return { profile = nil }
end
