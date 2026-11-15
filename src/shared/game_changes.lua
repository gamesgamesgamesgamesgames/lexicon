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
