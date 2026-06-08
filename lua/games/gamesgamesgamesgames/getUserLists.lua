local SEARCH_URL = env.MEILISEARCH_URL .. "/indexes/records/search"

local SEARCH_HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local PREVIEW_ATTRIBUTES = toarray({
  "uri", "name", "slug", "media"
})

function handle()
  local did = params.did
  if not did or did == "" then
    return { error = "InvalidRequest", message = "did is required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then
    offset = tonumber(params.cursor) or 0
  end

  -- Fetch list records for this user
  local list_rows = db.raw(
    "SELECT uri, record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.feed.list", did, limit + 1, offset}
  )

  local has_more = list_rows and #list_rows > limit
  if has_more then
    table.remove(list_rows, #list_rows)
  end

  if not list_rows or #list_rows == 0 then
    return { lists = toarray({}) }
  end

  local check_game_uri = params.gameUri

  -- Fetch all listItem records for this user once, then process in Lua
  local all_items = db.raw(
    "SELECT record, indexed_at FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC",
    {"games.gamesgamesgamesgames.feed.listItem", did}
  )

  -- Build per-list counts, hasGame lookup, and collect first 4 game URIs per list
  local item_counts = {}
  local has_game_map = {}
  local preview_uris = {}
  local all_game_uris = {}
  for _, item_row in ipairs(all_items or {}) do
    local item_rec = json.decode(item_row.record)
    if item_rec.listUri then
      item_counts[item_rec.listUri] = (item_counts[item_rec.listUri] or 0) + 1
      if check_game_uri and item_rec.gameUri == check_game_uri then
        has_game_map[item_rec.listUri] = true
      end
      -- Collect first 4 game URIs per list for preview
      if item_rec.gameUri then
        if not preview_uris[item_rec.listUri] then
          preview_uris[item_rec.listUri] = {}
        end
        if #preview_uris[item_rec.listUri] < 4 then
          table.insert(preview_uris[item_rec.listUri], item_rec.gameUri)
          all_game_uris[item_rec.gameUri] = true
        end
      end
    end
  end

  -- Batch fetch preview games from Meilisearch
  local games_by_uri = {}
  local uri_list = {}
  for uri, _ in pairs(all_game_uris) do
    uri_list[#uri_list + 1] = '"' .. uri .. '"'
  end

  if #uri_list > 0 then
    local body = {
      q = "",
      limit = #uri_list,
      filter = "uri IN [" .. table.concat(uri_list, ", ") .. "] AND publishedAt IS NOT NULL",
      attributesToRetrieve = PREVIEW_ATTRIBUTES
    }
    local resp = http.post(SEARCH_URL, { headers = SEARCH_HEADERS, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      for _, hit in ipairs(data.hits or {}) do
        games_by_uri[hit.uri] = hit
      end
    end
  end

  -- Build list views
  local lists = {}
  for _, row in ipairs(list_rows) do
    local rec = json.decode(row.record)

    local view = {
      uri = row.uri,
      name = rec.name,
      description = rec.description,
      itemCount = item_counts[row.uri] or 0,
      createdAt = rec.createdAt or row.indexed_at
    }

    if check_game_uri then
      view.hasGame = has_game_map[row.uri] == true
    end

    -- Attach preview items
    local list_previews = preview_uris[row.uri]
    if list_previews and #list_previews > 0 then
      local items = {}
      for _, game_uri in ipairs(list_previews) do
        local game = games_by_uri[game_uri]
        if game then
          table.insert(items, {
            uri = game.uri,
            name = game.name,
            slug = game.slug,
            media = game.media
          })
        end
      end
      if #items > 0 then
        view.previewItems = toarray(items)
      end
    end

    table.insert(lists, view)
  end

  local result = { lists = toarray(lists) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
