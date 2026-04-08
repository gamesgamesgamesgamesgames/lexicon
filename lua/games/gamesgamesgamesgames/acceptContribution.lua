function handle()
  -- Validate input
  if not input.contributionPatch or input.contributionPatch == "" then
    error("contributionPatch URI is required")
  end

  -- Load the patch record
  local patch_rows = db.raw(
    "SELECT uri, record FROM records WHERE uri = $1 AND collection = 'games.gamesgamesgamesgames.contributionPatch' LIMIT 1",
    { input.contributionPatch }
  )

  if not patch_rows or #patch_rows == 0 then
    error("contributionPatch not found: " .. input.contributionPatch)
  end

  local patch_record = json.decode(patch_rows[1].record)
  local subject_uri = patch_record.subject

  -- Verify the subject entity belongs to the caller
  local subject_did = subject_uri:match("^at://([^/]+)/")
  if subject_did ~= caller_did then
    error("unauthorized: you do not own the subject entity")
  end

  -- Load the actual entity record
  local entity = Record.load(subject_uri)
  if not entity then
    error("subject entity not found: " .. subject_uri)
  end

  -- Apply patch changes (same partial-update pattern as putGame.lua)
  local changes = patch_record.changes
  if changes.name ~= nil then entity.name = changes.name end
  if changes.summary ~= nil then entity.summary = changes.summary end
  if changes.applicationType ~= nil then entity.applicationType = changes.applicationType end
  if changes.genres ~= nil then entity.genres = changes.genres end
  if changes.modes ~= nil then entity.modes = changes.modes end
  if changes.themes ~= nil then entity.themes = changes.themes end
  if changes.playerPerspectives ~= nil then entity.playerPerspectives = changes.playerPerspectives end
  if changes.releases ~= nil then entity.releases = changes.releases end
  if changes.media ~= nil then entity.media = changes.media end
  if changes.parent ~= nil then entity.parent = changes.parent end
  if changes.storyline ~= nil then entity.storyline = changes.storyline end
  if changes.keywords ~= nil then entity.keywords = changes.keywords end
  if changes.websites ~= nil then entity.websites = changes.websites end
  if changes.videos ~= nil then entity.videos = changes.videos end
  if changes.alternativeNames ~= nil then entity.alternativeNames = changes.alternativeNames end
  if changes.timeToBeat ~= nil then entity.timeToBeat = changes.timeToBeat end
  if changes.ageRatings ~= nil then entity.ageRatings = changes.ageRatings end
  if changes.languageSupports ~= nil then entity.languageSupports = changes.languageSupports end
  if changes.multiplayerModes ~= nil then entity.multiplayerModes = changes.multiplayerModes end
  if changes.engines ~= nil then entity.engines = changes.engines end
  if changes.externalIds ~= nil then entity.externalIds = changes.externalIds end
  if changes.description ~= nil then entity.description = changes.description end
  if changes.descriptionFacets ~= nil then entity.descriptionFacets = changes.descriptionFacets end
  if changes.systemRequirements ~= nil then entity.systemRequirements = changes.systemRequirements end
  if changes.platformFeatures ~= nil then entity.platformFeatures = changes.platformFeatures end

  entity:save()

  -- Update contributionVerification: set acceptedBy to "both"
  local contribution_uri = patch_record.contribution.uri
  local verification_rows = db.raw(
    "SELECT uri, record FROM records WHERE collection = 'games.gamesgamesgamesgames.contributionVerification' " ..
    "AND record::jsonb->'contribution'->>'uri' = $1 LIMIT 1",
    { contribution_uri }
  )

  if verification_rows and #verification_rows > 0 then
    local verification = Record.load(verification_rows[1].uri)
    if verification then
      verification.acceptedBy = "both"
      verification:save()
    end
  end

  -- Delete the patch record (it's been merged)
  local patch_rkey = input.contributionPatch:match("/([^/]+)$")
  if patch_rkey then
    local PENTARACT_DID = env.PENTARACT_DID
    pcall(function()
      db.raw(
        "DELETE FROM records WHERE uri = $1",
        { input.contributionPatch }
      )
    end)
  end

  return { uri = entity._uri }
end
