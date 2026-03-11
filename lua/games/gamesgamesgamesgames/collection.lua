local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local INDEX_URL = env.MEILISEARCH_URL .. "/indexes/records/documents"

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function to_doc_id(s)
  local out = {}
  local i = 1
  while i <= #s do
    local a, b, c = string.byte(s, i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 65536 + b * 256 + c
    local remaining = #s - i + 1
    table.insert(out, string.sub(b64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
    table.insert(out, string.sub(b64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if remaining >= 2 then table.insert(out, string.sub(b64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)) end
    if remaining >= 3 then table.insert(out, string.sub(b64, n % 64 + 1, n % 64 + 1)) end
    i = i + 3
  end
  return table.concat(out)
end

function handle()
  if action == "delete" then
    http.delete(INDEX_URL .. "/" .. to_doc_id(uri), { headers = HEADERS })
    return true
  end

  -- Look up slug from the slugs table
  local slug = nil
  local slug_rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {uri})
  if slug_rows and #slug_rows > 0 then
    slug = slug_rows[1].slug
  end

  local doc = {
    id = to_doc_id(uri),
    type = "collection",
    did = did,
    uri = uri,
    name = record.name,
    description = record.description,
    collectionType = record.type,
    slug = slug
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })

  -- Update game documents in Meilisearch with this collection membership
  if record.games then
    local game_updates = {}
    for _, game_uri in ipairs(record.games) do
      -- For each game, we need to add this collection to its collections array.
      -- We do a partial update — Meilisearch merges fields on PUT.
      -- First, find all collections that reference this game.
      local collections_for_game = { uri }

      -- Check other collection records that reference this game
      local backlinks = db.backlinks({
        collection = "games.gamesgamesgamesgames.collection",
        uri = game_uri,
        limit = 100
      })
      if backlinks and backlinks.records then
        for _, coll in ipairs(backlinks.records) do
          if coll.uri ~= uri then
            table.insert(collections_for_game, coll.uri)
          end
        end
      end

      table.insert(game_updates, {
        id = to_doc_id(game_uri),
        collections = collections_for_game
      })
    end

    if #game_updates > 0 then
      http.post(INDEX_URL, {
        headers = HEADERS,
        body = json.encode(toarray(game_updates))
      })
    end
  end

  return record
end
