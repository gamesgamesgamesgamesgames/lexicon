function handle()
  local did = params.did

  local count_rows = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1 AND did = $2",
    {"social.popfeed.feed.list", did}
  )

  local count = 0
  if count_rows and #count_rows > 0 then
    count = tonumber(count_rows[1].count) or 0
  end

  return { count = count }
end
