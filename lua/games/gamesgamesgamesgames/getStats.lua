function handle()
  local game_rows = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1",
    {"games.gamesgamesgamesgames.game"}
  )
  local totalGames = 0
  if game_rows and #game_rows > 0 then
    totalGames = tonumber(game_rows[1].count) or 0
  end

  local studio_rows = db.raw(
    "SELECT COUNT(DISTINCT json_extract(record, '$.org.uri')) as count FROM records WHERE collection = $1",
    {"games.gamesgamesgamesgames.org.credit"}
  )
  local totalStudios = 0
  if studio_rows and #studio_rows > 0 then
    totalStudios = tonumber(studio_rows[1].count) or 0
  end

  local review_rows = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1",
    {"social.popfeed.feed.review"}
  )
  local totalReviews = 0
  if review_rows and #review_rows > 0 then
    totalReviews = tonumber(review_rows[1].count) or 0
  end

  return {
    totalGames = totalGames,
    totalStudios = totalStudios,
    totalReviews = totalReviews,
  }
end
