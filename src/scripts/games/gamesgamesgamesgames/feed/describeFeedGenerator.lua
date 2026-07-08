function handle()
  local service_did = env.SERVICE_DID

  local feeds = {
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/likes" },
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/similar" },
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/upcoming" },
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/recently-updated" },
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/hot" },
    { uri = "at://" .. service_did .. "/games.gamesgamesgamesgames.feed.generator/personalized" },
  }

  return {
    did = service_did,
    feeds = toarray(feeds),
  }
end
