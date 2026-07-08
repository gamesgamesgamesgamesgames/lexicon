function handle()
  local rows = db.raw(
    "SELECT key, value FROM stats_cache WHERE key IN ('totalGames', 'totalStudios', 'totalReviews')",
    {}
  )

  local stats = { totalGames = 0, totalStudios = 0, totalReviews = 0 }
  if rows then
    for _, row in ipairs(rows) do
      stats[row.key] = tonumber(row.value) or 0
    end
  end

  return stats
end
