function handle()
  local slug = params.slug
  local limit = tonumber(params.limit) or 10

  local rows = db.raw(
    "SELECT slug, uri FROM slugs WHERE slug = $1 LIMIT $2",
    {slug, limit}
  )

  local slugs = {}
  for _, row in ipairs(rows) do
    table.insert(slugs, {
      slug = row.slug,
      ref = row.uri
    })
  end

  return { slugs = toarray(slugs) }
end
