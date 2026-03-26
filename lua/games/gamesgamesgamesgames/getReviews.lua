function handle()
  local limit = tonumber(params.limit) or 20
  local cursor = tonumber(params.cursor) or 0

  local game = db.get(params.uri)
  if not game then
    return { reviews = toarray({}) }
  end

  local igdb_id = game.externalIds and game.externalIds.igdb
  if not igdb_id or igdb_id == "" then
    return { reviews = toarray({}) }
  end

  local rows = db.raw(
    "SELECT uri, did, record FROM records WHERE collection = $1 AND record::jsonb->'identifiers'->>'igdbId' = $2 ORDER BY record::jsonb->>'createdAt' DESC LIMIT $3 OFFSET $4",
    {"social.popfeed.feed.review", igdb_id, limit, cursor}
  )

  local reviews = {}
  for _, row in ipairs(rows) do
    local rec = json.decode(row.record)
    table.insert(reviews, {
      ["$type"] = "games.gamesgamesgamesgames.getReviews#popfeedReview",
      uri = row.uri,
      did = row.did,
      rating = rec.rating,
      text = rec.text,
      facets = rec.facets,
      title = rec.title,
      tags = rec.tags,
      createdAt = rec.createdAt,
      containsSpoilers = rec.containsSpoilers,
    })
  end

  local response = { reviews = toarray(reviews) }
  if #reviews == limit then
    response.cursor = tostring(cursor + limit)
  end

  return response
end
