-- >>> generated from src/shared/game_changes.lua — do not edit
-- Canonical merge logic for game contributions.
--
-- THIS FILE IS A SOURCE, NOT A HANDLER. `bun run generate:shared` inlines it
-- into every handler that marks a slot for it. Do not edit the copies.
--
-- Why generation: HappyView resolves `require` to built-in Rust modules and
-- installed library plugins only, so one deployed script cannot load another.
-- A library plugin would turn each call into an async JSON dispatch, which is
-- the wrong cost for a pure function on the index-write and getGame paths. The
-- same block therefore has to exist in several files, and a generator plus a CI
-- check is what keeps the copies honest.
--
-- To stay inlineable this file contains declarations only: no `return`, no
-- `function handle()`. It may read the handler globals `db`, `json` and `env`.

-- `changes` is an unknown-typed blob, and linked-repo writes are not validated
-- against the game lexicon, so only these fields may be copied onto a game.
local GAME_FIELDS = {
  "name", "summary", "applicationType", "genres", "modes", "themes",
  "playerPerspectives", "releases", "media", "parent", "storyline", "keywords",
  "websites", "videos", "alternativeNames", "timeToBeat", "ageRatings",
  "languageSupports", "multiplayerModes", "engines", "externalIds",
  "description", "descriptionFacets", "systemRequirements", "platformFeatures",
}

local PATCH_COLLECTION = "games.gamesgamesgamesgames.contributionPatch"

-- Whole-field replace, in place. Only a missing key means "no change": an empty
-- string is an edit that clears the field.
--
-- A table-valued field is assigned, not copied, so the result shares that table
-- with whatever owned `changes`. Safe as things stand: overlay_game deep-copies
-- its argument, the sharing runs changes->output and never output->argument, and
-- load_patches_by_subject decodes fresh tables per call. It stops being safe the
-- moment anything caches or reuses patches across records — if you add that,
-- copy on assignment here in the same change.
local function apply_changes(record, changes)
  for _, field in ipairs(GAME_FIELDS) do
    if changes[field] ~= nil then
      record[field] = changes[field]
    end
  end
  return record
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- Oldest first, so the newest patch wins per field. `uri` breaks ties, because
-- two patches written in the same second would otherwise sort unpredictably and
-- the public would see one version while the owner committed another.
local function order_patches(patches)
  table.sort(patches, function(a, b)
    local a_at, b_at = a.createdAt or "", b.createdAt or ""
    if a_at == b_at then
      return (a.uri or "") < (b.uri or "")
    end
    return a_at < b_at
  end)
  return patches
end

-- Whole-field replace means concurrent patches overwrite rather than conflict.
-- Patches on disjoint fields compose; patches on the same field resolve by
-- order. No conflict detection and no blocking, deliberately.
local function apply_patches(record, patches)
  for _, patch in ipairs(order_patches(patches)) do
    apply_changes(record, patch.changes or {})
  end
  return record
end

-- Live patches for the given game URIs, grouped by subject.
--
-- `did = PENTARACT_DID` is a security filter, not an optimisation.
-- happyview_records indexes every subscribed collection across the whole
-- network, so any account can publish a contributionPatch naming someone
-- else's game. Only a patch in the Pentaract repo was written by a moderator,
-- and only those may reach a public read.
local function load_patches_by_subject(uris)
  local by_subject = {}

  if not uris or #uris == 0 then
    return by_subject
  end

  -- Fail closed. An unconfigured instance overlays nothing rather than
  -- overlaying whatever the network happens to have published.
  local pentaract_did = env.PENTARACT_DID
  if not pentaract_did or pentaract_did == "" then
    return by_subject
  end

  local bind = { pentaract_did }
  local placeholders = {}
  for _, uri in ipairs(uris) do
    table.insert(bind, uri)
    table.insert(placeholders, "$" .. #bind)
  end

  local rows = db.raw(
    "SELECT uri, record FROM happyview_records " ..
    "WHERE collection = '" .. PATCH_COLLECTION .. "' AND did = $1 " ..
    "AND record::jsonb->>'subject' IN (" .. table.concat(placeholders, ", ") .. ")",
    bind
  )

  for _, row in ipairs(rows or {}) do
    local patch = json.decode(row.record)
    if patch and patch.subject then
      local list = by_subject[patch.subject]
      if not list then
        list = {}
        by_subject[patch.subject] = list
      end
      table.insert(list, {
        uri = row.uri,
        createdAt = patch.createdAt,
        changes = patch.changes,
      })
    end
  end

  return by_subject
end

-- The public view of one game: the stored record with every live patch applied.
--
-- Always a copy. A record handler's return value replaces what gets stored, so
-- an in-place overlay would write the provisional version into the index row
-- and the owner's decision would no longer mean anything.
--
-- `exclude_patch_uri` covers the reindex that happens while a patch is being
-- deleted: the record handler runs before the row goes away.
local function overlay_game(record, uri, exclude_patch_uri)
  local overlaid = deep_copy(record)
  local patches = load_patches_by_subject({ uri })[uri]

  if not patches then
    return overlaid
  end

  if exclude_patch_uri then
    local kept = {}
    for _, patch in ipairs(patches) do
      if patch.uri ~= exclude_patch_uri then
        table.insert(kept, patch)
      end
    end
    patches = kept
  end

  return apply_patches(overlaid, patches)
end
-- <<< generated from src/shared/game_changes.lua

function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 ORDER BY length(slug), slug LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function resolve_release_platforms(releases)
  if not releases then return nil end

  for _, release in ipairs(releases) do
    local platform_uri = release.platformUri or release.platformURI
    if platform_uri and not release.platform then
      local platform_record = db.get(platform_uri)
      if platform_record then
        release.platform = platform_record.name
      end
    end
  end

  return releases
end

function resolve_slug(slug)
  local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", {slug})
  if rows and #rows > 0 then return rows[1].uri end
  return nil
end

function resolve_external_id(service, value)
  local rows = db.raw(
    "SELECT uri FROM external_ids WHERE service = $1 AND external_id = $2 LIMIT 1",
    { service, value }
  )
  if rows and #rows > 0 then return rows[1].uri end
  return nil
end

function handle()
  local uri = params.uri

  if params.slug and params.slug ~= "" then
    uri = resolve_slug(params.slug)
    if not uri then
      return { game = nil }
    end
  end

  -- Check external ID params if no uri or slug was provided
  if not uri or uri == "" then
    if params.igdbId and params.igdbId ~= "" then uri = resolve_external_id("igdb", params.igdbId)
    elseif params.steamId and params.steamId ~= "" then uri = resolve_external_id("steam", params.steamId)
    elseif params.gogId and params.gogId ~= "" then uri = resolve_external_id("gog", params.gogId)
    elseif params.epicGamesId and params.epicGamesId ~= "" then uri = resolve_external_id("epicGames", params.epicGamesId)
    elseif params.humbleBundleId and params.humbleBundleId ~= "" then uri = resolve_external_id("humbleBundle", params.humbleBundleId)
    elseif params.playStationId and params.playStationId ~= "" then uri = resolve_external_id("playStation", params.playStationId)
    elseif params.xboxId and params.xboxId ~= "" then uri = resolve_external_id("xbox", params.xboxId)
    elseif params.nintendoEshopId and params.nintendoEshopId ~= "" then uri = resolve_external_id("nintendoEshop", params.nintendoEshopId)
    elseif params.appleAppStoreId and params.appleAppStoreId ~= "" then uri = resolve_external_id("appleAppStore", params.appleAppStoreId)
    elseif params.googlePlayId and params.googlePlayId ~= "" then uri = resolve_external_id("googlePlay", params.googlePlayId)
    else return { game = nil }
    end
    if not uri then return { game = nil } end
  end

  -- Redirect resolution: check if this URI has been redirected
  local redirected_from = nil
  local redirect_rows = db.raw(
    "SELECT record FROM happyview_records WHERE collection = 'games.gamesgamesgamesgames.redirect' AND record::jsonb->>'sourceUri' = $1 LIMIT 1",
    { uri }
  )
  if redirect_rows and #redirect_rows > 0 then
    redirected_from = uri
    local redirect_rec = json.decode(redirect_rows[1].record)
    uri = redirect_rec.targetUri
  end

  local stored = db.get(uri)

  if not stored then
    return { game = nil }
  end

  -- The detail page is a public read path, so it shows the provisional version
  -- while a moderator-approved patch is live. `uri` here is already the
  -- redirect-resolved target, which is also what the patch's subject points at
  -- after a claim migration.
  local record = overlay_game(stored, uri)
  record.uri = stored.uri

  local game = {
    ["$type"] = "games.gamesgamesgamesgames.defs#gameDetailView",
    uri = record.uri,
    name = record.name,
    summary = record.summary,
    applicationType = record.applicationType,
    createdAt = record.createdAt,
    publishedAt = record.publishedAt,
    parent = record.parent,
    storyline = record.storyline,
    genres = record.genres,
    modes = record.modes,
    themes = record.themes,
    playerPerspectives = record.playerPerspectives,
    releases = resolve_release_platforms(record.releases),
    media = record.media,
    keywords = record.keywords,
    websites = record.websites,
    videos = record.videos,
    alternativeNames = record.alternativeNames,
    timeToBeat = record.timeToBeat,
    ageRatings = record.ageRatings,
    languageSupports = record.languageSupports,
    multiplayerModes = record.multiplayerModes,
    engines = record.engines,
    externalIds = record.externalIds,
    slug = find_slug(record.uri),
    redirectedFrom = redirected_from,
  }

  -- Build collections by finding collection records that reference this game
  local backlinks = db.backlinks({
    collection = "games.gamesgamesgamesgames.collection",
    uri = record.uri,
    limit = 100
  })
  if backlinks and backlinks.records and #backlinks.records > 0 then
    local coll_uris = {}
    for _, coll in ipairs(backlinks.records) do
      table.insert(coll_uris, coll.uri)
    end
    game.collections = coll_uris
  end

  -- Organization credits
  if params.includeOrgCredits == true or params.includeOrgCredits == "true" then
    local org_backlinks = db.backlinks({
      collection = "games.gamesgamesgamesgames.org.credit",
      uri = record.uri,
      limit = 100
    })
    if org_backlinks and org_backlinks.records and #org_backlinks.records > 0 then
      local org_credits = {}
      for _, credit in ipairs(org_backlinks.records) do
        table.insert(org_credits, {
          ["$type"] = "games.gamesgamesgamesgames.defs#orgCreditView",
          uri = credit.uri,
          orgUri = credit.org and credit.org.uri or nil,
          displayName = credit.displayName,
          roles = credit.roles
        })
      end
      game.orgCredits = org_credits
    end
  end

  -- Actor credits
  if params.includeActorCredits == true or params.includeActorCredits == "true" then
    local actor_backlinks = db.backlinks({
      collection = "games.gamesgamesgamesgames.actor.credit",
      uri = record.uri,
      limit = 500
    })
    if actor_backlinks and actor_backlinks.records and #actor_backlinks.records > 0 then
      local actor_credits = {}
      for _, credit in ipairs(actor_backlinks.records) do
        table.insert(actor_credits, {
          ["$type"] = "games.gamesgamesgamesgames.defs#actorCreditView",
          uri = credit.uri,
          actorUri = credit.actor and credit.actor.uri or nil,
          displayName = credit.displayName,
          credits = credit.credits
        })
      end
      game.actorCredits = actor_credits
    end
  end

  -- Verified owner lookup
  local VERIFIER_DID = env.VERIFIER_DID
  local PENTARACT_DID = env.PENTARACT_DID
  local game_owner_did = record.uri:match("^at://([^/]+)/")

  if VERIFIER_DID and VERIFIER_DID ~= "" and game_owner_did and game_owner_did ~= PENTARACT_DID then
    local v_rows = db.raw(
      "SELECT record FROM happyview_records WHERE collection = 'dev.cartridge.graph.verification' AND did = $1 AND record::jsonb->>'subject' = $2 LIMIT 1",
      { VERIFIER_DID, game_owner_did }
    )
    if v_rows and #v_rows > 0 then
      local v_record = json.decode(v_rows[1].record)
      game.verifiedOwner = {
        did = game_owner_did,
        accountType = v_record.accountType,
      }
    end
  end

  return { game = game }
end
