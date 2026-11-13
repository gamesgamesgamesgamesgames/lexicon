function handle()
  local did = params.did

  -- A missing did can't match anything. Answer zero instead of running the
  -- query: db.raw drops a nil parameter, which binds one value against $1/$2
  -- and fails the request with a 500.
  if not did or did == "" then
    return { count = 0 }
  end

  local count_rows = db.raw(
    "SELECT COUNT(*) as count FROM happyview_records WHERE collection = $1 AND did = $2",
    {"games.gamesgamesgamesgames.feed.list", did}
  )

  local count = 0
  if count_rows and #count_rows > 0 then
    count = tonumber(count_rows[1].count) or 0
  end

  return { count = count }
end
