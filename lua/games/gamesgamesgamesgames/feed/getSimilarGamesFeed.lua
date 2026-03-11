local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

function handle()
  local game_uri = params.uri
  local limit = tonumber(params.limit) or 5
  if limit < 1 then limit = 1 end
  if limit > 10 then limit = 10 end

  -- Load the source game
  local game = db.get(game_uri)
  if not game then
    return { games = toarray({}) }
  end

  -- Build a search query from the game's attributes
  local terms = {}

  if game.genres then
    for _, g in ipairs(game.genres) do
      table.insert(terms, g)
    end
  end

  if game.themes then
    for _, t in ipairs(game.themes) do
      table.insert(terms, t)
    end
  end

  if game.modes then
    for _, m in ipairs(game.modes) do
      table.insert(terms, m)
    end
  end

  if game.playerPerspectives then
    for _, p in ipairs(game.playerPerspectives) do
      table.insert(terms, p)
    end
  end

  -- Add a few keywords for extra specificity
  if game.keywords then
    for i, k in ipairs(game.keywords) do
      if i > 5 then break end
      table.insert(terms, k)
    end
  end

  if #terms == 0 then
    return { games = toarray({}) }
  end

  -- Replace camelCase with spaces for better search matching
  local query_terms = {}
  for _, term in ipairs(terms) do
    local spaced = term:gsub("(%l)(%u)", "%1 %2")
    table.insert(query_terms, spaced)
  end
  local q = table.concat(query_terms, " ")

  -- Build the Meilisearch document ID for the source game so we can exclude it
  local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local function to_doc_id(s)
    local out = {}
    local i = 1
    while i <= #s do
      local a, b2, c = string.byte(s, i, i + 2)
      b2 = b2 or 0
      c = c or 0
      local n = a * 65536 + b2 * 256 + c
      local remaining = #s - i + 1
      table.insert(out, string.sub(b64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
      table.insert(out, string.sub(b64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
      if remaining >= 2 then table.insert(out, string.sub(b64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)) end
      if remaining >= 3 then table.insert(out, string.sub(b64, n % 64 + 1, n % 64 + 1)) end
      i = i + 3
    end
    return table.concat(out)
  end

  -- Filter: games only, exclude the source game, only full games (not DLC/bundles)
  local source_id = to_doc_id(game_uri)
  local filter = 'type = "game" AND id != "' .. source_id .. '" AND applicationType = "game"'

  local body = {
    q = q,
    limit = limit,
    filter = filter,
    attributesToRetrieve = toarray({ "uri" })
  }

  local resp = http.post(SEARCH_URL, {
    headers = SEARCH_HEADERS,
    body = json.encode(body)
  })

  local data = json.decode(resp.body)
  local hits = data.hits or {}

  -- Hydrate each hit from the local DB
  local games = {}
  for _, hit in ipairs(hits) do
    local similar = db.get(hit.uri)
    if similar then
      games[#games + 1] = {
        uri = hit.uri,
        game = similar
      }
    end
  end

  return { games = toarray(games) }
end
