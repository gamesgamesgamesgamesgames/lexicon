function handle()
  local subject = input.subject

  -- Check if the user already has a like for this game
  local results = db.query({
    collection = "games.gamesgamesgamesgames.graph.like",
    did = did,
    limit = 100
  })

  local existing = nil
  if results.records then
    for _, record in ipairs(results.records) do
      if record.subject == subject then
        existing = record
        break
      end
    end
  end

  if existing then
    -- Unlike: delete the existing like record
    local r = Record.load(existing.uri)
    if r then r:delete() end
    return { action = "unliked" }
  else
    -- Like: create a new like record
    local like = Record.new("games.gamesgamesgamesgames.graph.like", {
      subject = subject,
      createdAt = now()
    })
    like:save()
    return { uri = like._uri, cid = like._cid, action = "liked" }
  end
end
