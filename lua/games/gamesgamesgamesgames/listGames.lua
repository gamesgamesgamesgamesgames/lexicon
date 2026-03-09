function find_slug(target_uri)
  local rows = db.raw(
    "SELECT record FROM records WHERE collection = $1 AND record->>'ref' = $2 LIMIT 1",
    {"games.gamesgamesgamesgames.slug", target_uri}
  )
  if rows and #rows > 0 and rows[1].record then
    return rows[1].record.slug
  end
  return nil
end

function handle()
  local limit = tonumber(params.limit) or 20
  local cursor = tonumber(params.cursor) or 0

  local query_opts = {
    collection = "games.gamesgamesgamesgames.game",
    limit = limit,
    offset = cursor
  }

  if params.did then
    query_opts.did = params.did
  end

  if params.sort then
    query_opts.sort = params.sort
  end
  if params.sortDirection then
    query_opts.sortDirection = params.sortDirection
  end

  local result = db.query(query_opts)

  local games = {}
  for _, record in ipairs(result.records or {}) do
    table.insert(games, {
      ["$type"] = "games.gamesgamesgamesgames.defs#gameSummaryView",
      uri = record.uri,
      name = record.name,
      summary = record.summary,
      media = record.media,
      slug = find_slug(record.uri)
    })
  end

  local response = { games = toarray(games) }
  if result.cursor then
    response.cursor = result.cursor
  end

  return response
end
