function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function handle()
  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then
    offset = tonumber(params.cursor) or 0
  end

  local where_parts = {
    "collection = $1",
    "record::jsonb->>'publishedAt' IS NOT NULL",
  }
  local bind = {"games.gamesgamesgamesgames.game"}

  if params.did then
    table.insert(where_parts, "did = $" .. (#bind + 1))
    table.insert(bind, params.did)
  end

  local order_col = "indexed_at"
  local order_dir = "DESC"
  if params.sort then
    order_col = params.sort
  end
  if params.sortDirection and params.sortDirection:lower() == "asc" then
    order_dir = "ASC"
  end

  local sql = "SELECT uri, record FROM records WHERE "
    .. table.concat(where_parts, " AND ")
    .. " ORDER BY " .. order_col .. " " .. order_dir
    .. " LIMIT $" .. (#bind + 1)
    .. " OFFSET $" .. (#bind + 2)
  table.insert(bind, limit + 1)
  table.insert(bind, offset)

  local rows = db.raw(sql, bind)

  local has_more = rows and #rows > limit

  local games = {}
  for i = 1, math.min(#(rows or {}), limit) do
    local record = json.decode(rows[i].record)
    table.insert(games, {
      ["$type"] = "games.gamesgamesgamesgames.defs#gameSummaryView",
      uri = rows[i].uri,
      name = record.name,
      summary = record.summary,
      media = record.media,
      slug = find_slug(rows[i].uri)
    })
  end

  local response = { games = toarray(games) }
  if has_more then
    response.cursor = tostring(offset + limit)
  end

  return response
end
