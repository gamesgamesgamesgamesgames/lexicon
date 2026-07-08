function handle()
  local results = db.query({
    collection = "games.gamesgamesgamesgames.actor.profile",
    did = caller_did,
    limit = 1
  })
  if results.records and #results.records > 0 then
    local record = results.records[1]
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#actorProfileDetailView",
      uri = record.uri,
      did = caller_did,
      displayName = record.displayName,
      description = record.description,
      pronouns = record.pronouns,
      websites = record.websites,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile }
  end
  return { profile = nil }
end
