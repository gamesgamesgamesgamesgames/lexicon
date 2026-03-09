function find_slug(target_uri)
  local rows = db.raw(
    "SELECT record FROM records WHERE collection = $1 AND record->>'ref' = $2 LIMIT 1",
    {"games.gamesgamesgamesgames.slug", target_uri}
  )
  if rows and #rows > 0 and rows[1].record then
    return rows[1].record.slug
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
