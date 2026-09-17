function generate_slug(str)
  if not str or str == "" then
    return nil
  end

  local slug = str:lower()
  slug = slug:gsub("[^%w%s%-]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")

  if slug == "" then
    return nil
  end

  return slug
end

function resolve_twitch_id(igdb_id)
  if not igdb_id or igdb_id == "" then return nil end
  if not env.TWITCH_CLIENT_ID or not env.TWITCH_ACCESS_TOKEN then return nil end

  local resp = http.get("https://api.twitch.tv/helix/games?igdb_id=" .. igdb_id, {
    headers = {
      ["Client-ID"] = env.TWITCH_CLIENT_ID,
      ["Authorization"] = "Bearer " .. env.TWITCH_ACCESS_TOKEN,
    }
  })

  if resp and resp.status == 200 then
    local body = json.decode(resp.body)
    if body and body.data and #body.data > 0 then
      return body.data[1].id
    end
  end

  return nil
end

function handle()
  -- Enrich externalIds: resolve Twitch ID from IGDB ID if missing
  local external_ids = input.externalIds
  if external_ids then
    if external_ids.igdb and (not external_ids.twitch or external_ids.twitch == "") then
      external_ids.twitch = resolve_twitch_id(external_ids.igdb)
    end
  end

  local game_data = {
    name = input.name,
    summary = input.summary,
    applicationType = input.applicationType,
    genres = input.genres,
    modes = input.modes,
    themes = input.themes,
    playerPerspectives = input.playerPerspectives,
    releases = input.releases,
    media = input.media,
    parent = input.parent,
    storyline = input.storyline,
    keywords = input.keywords,
    websites = input.websites,
    videos = input.videos,
    alternativeNames = input.alternativeNames,
    timeToBeat = input.timeToBeat,
    ageRatings = input.ageRatings,
    languageSupports = input.languageSupports,
    multiplayerModes = input.multiplayerModes,
    engines = input.engines,
    externalIds = external_ids,
    createdAt = now()
  }

  if input.shouldPublish then
    game_data.publishedAt = now()
  end

  -- The game lexicon requires applicationType but the createGame input schema
  -- does not, so check it here. Record.new():save() would catch this on the
  -- verified path; the linked-repo path has no schema to validate against.
  if not game_data.applicationType then
    error("applicationType is required")
  end

  -- Check if the caller is verified (has a dev.cartridge.graph.verification record from the trusted verifier)
  local VERIFIER_DID = env.VERIFIER_DID
  local PENTARACT_DID = env.PENTARACT_DID

  local is_verified = false
  if VERIFIER_DID and VERIFIER_DID ~= "" then
    local verification_rows = db.raw(
      "SELECT uri FROM happyview_records WHERE collection = 'dev.cartridge.graph.verification' AND did = $1 AND record::jsonb->>'subject' = $2 LIMIT 1",
      { VERIFIER_DID, caller_did }
    )
    is_verified = verification_rows and #verification_rows > 0
  end

  local uri, cid

  if is_verified or not PENTARACT_DID or PENTARACT_DID == "" then
    -- Verified author: the game lives in their own repo, written with their
    -- own credentials.
    local game = Record.new("games.gamesgamesgamesgames.game", game_data)
    game:save()
    uri, cid = game._uri, game._cid
  else
    -- Unverified author: the instance publishes on their behalf into the
    -- Pentaract repo. That needs a linked-repo grant — HappyView can only
    -- write to a repo it holds a session for, and the caller's credentials
    -- are not credentials for someone else's repo.
    local pentaract = linked_repos.get(PENTARACT_DID)
    if not pentaract then
      error("cannot publish on your behalf: no linked repo grant for " .. PENTARACT_DID ..
            " — an admin must link that account")
    end

    game_data["$type"] = "games.gamesgamesgamesgames.game"
    local result = pentaract:create_record({
      collection = "games.gamesgamesgamesgames.game",
      record = game_data,
    })
    uri, cid = result.uri, result.cid
  end

  local slug_value = input.slug or generate_slug(input.name)
  if slug_value then
    db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO UPDATE SET uri = $2",
      {slug_value, uri})
  end

  return { uri = uri, cid = cid }
end
