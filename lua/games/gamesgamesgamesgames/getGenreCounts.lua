function handle()
  local rows = db.raw(
    "SELECT je.value AS genre, COUNT(*) AS count FROM records, json_each(record, '$.genres') AS je WHERE collection = $1 GROUP BY je.value ORDER BY count DESC",
    {"games.gamesgamesgamesgames.game"}
  )

  local genres = {}
  if rows then
    for _, row in ipairs(rows) do
      genres[#genres + 1] = {
        genre = row.genre,
        count = tonumber(row.count) or 0,
      }
    end
  end

  return { genres = toarray(genres) }
end
