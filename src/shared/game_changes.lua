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
