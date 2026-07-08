function handle()
  local list_uri = input.listUri
  local game_uri = input.gameUri

  -- Check if the user already has a listItem for this game in this list
  local results = db.query({
    collection = "games.gamesgamesgamesgames.feed.listItem",
    did = caller_did,
    limit = 1000
  })

  local existing = nil
  if results.records then
    for _, rec in ipairs(results.records) do
      if rec.listUri == list_uri and rec.gameUri == game_uri then
        existing = rec
        break
      end
    end
  end

  if existing then
    local r = Record.load(existing.uri)
    if r then r:delete() end
    return { action = "removed" }
  else
    local item = Record.new("games.gamesgamesgamesgames.feed.listItem", {
      listUri = list_uri,
      gameUri = game_uri,
      addedAt = now()
    })
    item:save()
    return { uri = item._uri, cid = item._cid, action = "added" }
  end
end
