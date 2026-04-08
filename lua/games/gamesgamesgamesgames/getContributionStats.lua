local BADGES = {
  { id = "first-contribution", name = "First Contribution", description = "Made their first verified contribution", threshold = 1, field = "totalContributions" },
  { id = "cataloger", name = "Cataloger", description = "10+ corrections to existing games", threshold = 10, field = "corrections" },
  { id = "archivist", name = "Archivist", description = "50+ corrections to existing games", threshold = 50, field = "corrections" },
  { id = "cartographer", name = "Cartographer", description = "5+ new game submissions", threshold = 5, field = "newGames" },
  { id = "trusted-contributor", name = "Trusted Contributor", description = "10+ owner-accepted contributions", threshold = 10, field = "ownerAccepted" },
  { id = "community-pillar", name = "Community Pillar", description = "100+ total verified contributions", threshold = 100, field = "totalContributions" },
}

function handle()
  local target_did = params.did
  if not target_did or target_did == "" then
    error("did is required")
  end

  -- Aggregate stats from contributionVerification records
  local rows = db.raw(
    "SELECT " ..
    "  COUNT(*) as total, " ..
    "  COUNT(DISTINCT record::jsonb->>'subject') as unique_entities, " ..
    "  SUM(CASE WHEN record::jsonb->>'contributionType' = 'correction' THEN 1 ELSE 0 END) as corrections, " ..
    "  SUM(CASE WHEN record::jsonb->>'contributionType' = 'addition' THEN 1 ELSE 0 END) as additions, " ..
    "  SUM(CASE WHEN record::jsonb->>'contributionType' = 'newGame' THEN 1 ELSE 0 END) as new_games, " ..
    "  SUM(CASE WHEN record::jsonb->>'acceptedBy' IN ('owner', 'both') THEN 1 ELSE 0 END) as owner_accepted " ..
    "FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
    "AND record::jsonb->>'contributor' = $1",
    { target_did }
  )

  local stats = {
    totalContributions = 0,
    corrections = 0,
    additions = 0,
    newGames = 0,
    uniqueEntities = 0,
    ownerAccepted = 0,
  }

  if rows and #rows > 0 then
    local r = rows[1]
    stats.totalContributions = tonumber(r.total) or 0
    stats.corrections = tonumber(r.corrections) or 0
    stats.additions = tonumber(r.additions) or 0
    stats.newGames = tonumber(r.new_games) or 0
    stats.uniqueEntities = tonumber(r.unique_entities) or 0
    stats.ownerAccepted = tonumber(r.owner_accepted) or 0
  end

  -- Compute badges from stats
  local earned_badges = {}
  for _, badge_def in ipairs(BADGES) do
    local value = stats[badge_def.field] or 0
    if value >= badge_def.threshold then
      table.insert(earned_badges, {
        id = badge_def.id,
        name = badge_def.name,
        description = badge_def.description,
      })
    end
  end

  return {
    stats = stats,
    badges = toarray(earned_badges),
  }
end
