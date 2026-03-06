function handle()
  local slug = params.slug
  local limit = tonumber(params.limit) or 10

  local rows = db.raw(
    "SELECT uri, did, record FROM records WHERE collection = $1 AND rkey = $2 LIMIT $3",
    {"games.gamesgamesgamesgames.slug", slug, limit}
  )

  local slugs = {}
  for _, row in ipairs(rows) do
    local ref = nil
    if row.record and row.record.ref then
      ref = row.record.ref
    end
    table.insert(slugs, {
      did = row.did,
      slug = slug,
      ref = ref
    })
  end

  return { slugs = toarray(slugs) }
end
