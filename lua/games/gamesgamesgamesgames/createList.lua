function handle()
  local list = Record.new("social.popfeed.feed.list", {
    name = input.name,
    description = input.description,
    createdAt = now()
  })
  list:save()

  return { uri = list._uri, cid = list._cid }
end
