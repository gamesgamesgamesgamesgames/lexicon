-- Valid game record fields that contributions can modify
local VALID_FIELDS = {
  name = true,
  summary = true,
  applicationType = true,
  genres = true,
  modes = true,
  themes = true,
  playerPerspectives = true,
  releases = true,
  media = true,
  parent = true,
  storyline = true,
  keywords = true,
  websites = true,
  videos = true,
  alternativeNames = true,
  timeToBeat = true,
  ageRatings = true,
  languageSupports = true,
  multiplayerModes = true,
  engines = true,
  externalIds = true,
  description = true,
  descriptionFacets = true,
  systemRequirements = true,
  platformFeatures = true,
}

function handle()
  -- Validate contributionType
  if not input.contributionType then
    error("contributionType is required")
  end

  local ct = input.contributionType
  if ct ~= "correction" and ct ~= "addition" and ct ~= "newGame" then
    error("contributionType must be 'correction', 'addition', or 'newGame'")
  end

  -- Validate changes
  if not input.changes or type(input.changes) ~= "table" then
    error("changes is required and must be an object")
  end

  -- Validate changes keys are valid game fields
  for k, _ in pairs(input.changes) do
    if not VALID_FIELDS[k] then
      error("invalid field in changes: " .. tostring(k))
    end
  end

  -- For corrections/additions: validate subject exists
  if ct == "correction" or ct == "addition" then
    if not input.subject or input.subject == "" then
      error("subject is required for corrections and additions")
    end
    local subject_record = db.get(input.subject)
    if not subject_record then
      error("subject entity not found: " .. input.subject)
    end
  end

  -- For newGame: validate required game fields
  if ct == "newGame" then
    if not input.changes.name or input.changes.name == "" then
      error("changes.name is required for new game submissions")
    end
    if not input.changes.applicationType or input.changes.applicationType == "" then
      error("changes.applicationType is required for new game submissions")
    end
  end

  -- Rate-limit: max 20 pending contributions per user
  local pending = db.raw(
    "SELECT COUNT(*) as cnt FROM records c " ..
    "WHERE c.collection = 'games.gamesgamesgamesgames.contribution' " ..
    "AND c.did = $1 " ..
    "AND NOT EXISTS (" ..
      "SELECT 1 FROM records r WHERE r.collection = 'games.gamesgamesgamesgames.contributionReview' " ..
      "AND r.record::jsonb->'contribution'->>'uri' = c.uri" ..
    ")",
    { caller_did }
  )
  if pending and #pending > 0 and tonumber(pending[1].cnt) >= 20 then
    error("too many pending contributions (max 20)")
  end

  -- Build contribution record
  local contribution_data = {
    contributionType = ct,
    changes = input.changes,
    createdAt = now(),
  }

  if input.subject then
    contribution_data.subject = input.subject
  end

  if input.message and input.message ~= "" then
    contribution_data.message = input.message
  end

  -- Sign with HappyView's key for inline attestation
  local sig = atproto.sign(contribution_data)
  if sig then
    contribution_data.signatures = toarray({ sig })
  end

  -- Create record in caller's repo
  local contribution = Record.new("games.gamesgamesgamesgames.contribution", contribution_data)
  contribution:save()

  return { uri = contribution._uri }
end
