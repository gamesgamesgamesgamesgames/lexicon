function find_slug_for(did, collection)
  local rows = db.raw(
    "SELECT record FROM records WHERE collection = $1 AND did = $2 AND record->>'ref' LIKE $3 LIMIT 1",
    {"games.gamesgamesgamesgames.slug", did, "%" .. collection .. "%"}
  )
  if rows and #rows > 0 and rows[1].record then
    return rows[1].record.slug
  end
  return nil
end

function handle()
  local q = params.q
  local limit = tonumber(params.limit) or 10

  -- Search both collections by displayName
  local actor_results = db.search({
    collection = "games.gamesgamesgamesgames.actor.profile",
    field = "displayName",
    query = q,
    limit = limit
  })
  local org_results = db.search({
    collection = "games.gamesgamesgamesgames.org.profile",
    field = "displayName",
    query = q,
    limit = limit
  })

  -- Build unified results with profileType discriminator
  local profiles = {}
  for _, record in ipairs(actor_results.records or {}) do
    local did = string.match(record.uri, "at://([^/]+)/")
    table.insert(profiles, {
      ["$type"] = "games.gamesgamesgamesgames.defs#profileSummaryView",
      uri = record.uri,
      did = did,
      profileType = "actor",
      displayName = record.displayName,
      slug = find_slug_for(did, "games.gamesgamesgamesgames.actor.profile"),
      avatar = record.avatar
    })
  end
  for _, record in ipairs(org_results.records or {}) do
    local did = string.match(record.uri, "at://([^/]+)/")
    table.insert(profiles, {
      ["$type"] = "games.gamesgamesgamesgames.defs#profileSummaryView",
      uri = record.uri,
      did = did,
      profileType = "org",
      displayName = record.displayName,
      slug = find_slug_for(did, "games.gamesgamesgamesgames.org.profile"),
      avatar = record.avatar
    })
  end

  -- Sort by relevance: exact > prefix > contains, then alphabetical
  local q_lower = string.lower(q)
  table.sort(profiles, function(a, b)
    local a_name = string.lower(a.displayName or "")
    local b_name = string.lower(b.displayName or "")
    local a_score = (a_name == q_lower and 0) or (string.find(a_name, q_lower, 1, true) == 1 and 1) or 2
    local b_score = (b_name == q_lower and 0) or (string.find(b_name, q_lower, 1, true) == 1 and 1) or 2
    if a_score ~= b_score then return a_score < b_score end
    return a_name < b_name
  end)

  -- Trim to limit
  while #profiles > limit do
    table.remove(profiles)
  end
  return { profiles = toarray(profiles) }
end
