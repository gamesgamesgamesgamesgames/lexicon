function handle()
  local rows = db.raw(
    "SELECT genre, count FROM genre_counts_cache ORDER BY count DESC",
    {}
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
