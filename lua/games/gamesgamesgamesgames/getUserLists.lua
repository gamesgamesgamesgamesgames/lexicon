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
    {"social.popfeed.feed.list", did, limit + 1, offset}
  )

  local has_more = list_rows and #list_rows > limit
  if has_more then
    table.remove(list_rows, #list_rows)
  end

  if not list_rows or #list_rows == 0 then
    return { lists = toarray({}) }
  end

  -- Resolve game URI to IGDB ID if gameUri param is provided
  local check_igdb_id = nil
  if params.gameUri and params.gameUri ~= "" then
    local search_url = env.MEILISEARCH_URL .. "/indexes/records/search"
    local search_headers = {
      ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
      ["content-type"] = "application/json"
    }
    local body = {
      q = "",
      limit = 1,
      filter = "uri = \"" .. params.gameUri .. "\"",
      attributesToRetrieve = toarray({ "externalIds" })
    }
    local resp = http.post(search_url, { headers = search_headers, body = json.encode(body) })
    if resp.status == 200 then
      local data = json.decode(resp.body)
      if data.hits and #data.hits > 0 and data.hits[1].externalIds then
        check_igdb_id = data.hits[1].externalIds.igdb
      end
    end
  end

  -- Build list views with item counts and optional hasGame
  local lists = {}
  for _, row in ipairs(list_rows) do
    local rec = json.decode(row.record)

    -- Count items in this list (video_game only)
    local count_rows = db.raw(
      "SELECT COUNT(*) as count FROM records WHERE collection = $1 AND did = $2 AND json_extract(record, '$.listUri') = $3 AND json_extract(record, '$.creativeWorkType') = 'video_game'",
      {"social.popfeed.feed.listItem", did, row.uri}
    )
    local item_count = 0
    if count_rows and #count_rows > 0 then
      item_count = tonumber(count_rows[1].count) or 0
    end

    local view = {
      uri = row.uri,
      name = rec.name,
      description = rec.description,
      itemCount = item_count,
      createdAt = rec.createdAt or row.indexed_at
    }

    -- Check if the specified game is in this list
    if check_igdb_id then
      local has_rows = db.raw(
        "SELECT COUNT(*) as count FROM records WHERE collection = $1 AND did = $2 AND json_extract(record, '$.listUri') = $3 AND json_extract(record, '$.identifiers.igdbId') = $4 AND json_extract(record, '$.creativeWorkType') = 'video_game'",
        {"social.popfeed.feed.listItem", did, row.uri, check_igdb_id}
      )
      view.hasGame = has_rows and #has_rows > 0 and tonumber(has_rows[1].count) > 0
    end

    table.insert(lists, view)
  end

  local result = { lists = toarray(lists) }
  if has_more then
    result.cursor = tostring(offset + limit)
  end
  return result
end
