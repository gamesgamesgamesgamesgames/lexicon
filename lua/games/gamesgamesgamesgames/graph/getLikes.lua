function handle()
  local uri = params.uri

  -- Count total likes for this game
  local count_rows = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1 AND record->>'subject' = $2",
    {"games.gamesgamesgamesgames.graph.like", uri}
  )

  local count = 0
  if count_rows and #count_rows > 0 then
    count = tonumber(count_rows[1].count) or 0
  end

  -- Check if the authenticated user has liked this game
  local liked = false
  if did and did ~= "" then
    local user_rows = db.raw(
      "SELECT uri FROM records WHERE collection = $1 AND did = $2 AND record->>'subject' = $3 LIMIT 1",
      {"games.gamesgamesgamesgames.graph.like", did, uri}
    )
    if user_rows and #user_rows > 0 then
      liked = true
    end
  end

  return { count = count, liked = liked }
end
