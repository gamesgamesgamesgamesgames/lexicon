function handle()
  local results = db.query({
    collection = "games.gamesgamesgamesgames.org.profile",
    did = caller_did,
    limit = 1
  })
  if results.records and #results.records > 0 then
    local record = results.records[1]
    local profile = {
      ["$type"] = "games.gamesgamesgamesgames.defs#orgProfileDetailView",
      uri = record.uri,
      did = caller_did,
      displayName = record.displayName,
      description = record.description,
      country = record.country,
      status = record.status,
      parent = record.parent,
      foundedAt = record.foundedAt,
      websites = record.websites,
      media = record.media,
      avatar = record.avatar,
      createdAt = record.createdAt
    }
    return { profile = profile }
  end
  return { profile = nil }
end
