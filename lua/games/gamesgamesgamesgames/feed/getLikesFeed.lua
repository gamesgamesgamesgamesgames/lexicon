function handle()
  if not did or did == "" then
    return { error = "Authentication required" }
  end

  local limit = tonumber(params.limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local cursor = params.cursor
  local offset = 0
  if cursor then
    offset = tonumber(cursor) or 0
  end

  -- Get the user's likes ordered by most recent
  local likes = db.raw(
    "SELECT record, uri AS like_uri FROM records WHERE collection = $1 AND did = $2 ORDER BY indexed_at DESC LIMIT $3 OFFSET $4",
    {"games.gamesgamesgamesgames.graph.like", did, limit + 1, offset}
  )

  if not likes then
    return { games = {} }
  end

  -- Check if there's a next page
  local has_more = #likes > limit
  local next_cursor = nil
  if has_more then
    next_cursor = tostring(offset + limit)
  end

  local games = {}
  for i = 1, math.min(#likes, limit) do
    local like = likes[i]
    local subject = like.record.subject

    -- Fetch the game record
    local game = db.get(subject)
    if game then
      games[#games + 1] = {
        uri = subject,
        game = game,
        likedAt = like.record.createdAt
      }
    end
  end

  local result = { games = games }
  if next_cursor then
    result.cursor = next_cursor
  end
  return result
end
