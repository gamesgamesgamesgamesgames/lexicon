function handle()
  local list = Record.new("games.gamesgamesgamesgames.feed.list", {
    name = input.name,
    description = input.description,
    createdAt = now()
  })
  list:save()

  return { uri = list._uri, cid = list._cid }
end
