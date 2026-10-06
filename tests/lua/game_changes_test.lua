package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local SOURCE = "src/shared/game_changes.lua"
local EXPORTS = { "GAME_FIELDS", "apply_changes", "order_patches", "apply_patches", "deep_copy" }

local function shared()
  return t.load_shared(SOURCE, EXPORTS, {})
end

t.test("the allowlist is exactly the 25 agreed fields", function()
  local s = shared()
  t.eq(#s.GAME_FIELDS, 25, "field count")
  local seen = {}
  for _, field in ipairs(s.GAME_FIELDS) do seen[field] = true end
  t.truthy(seen.name, "name")
  t.truthy(seen.platformFeatures, "platformFeatures")
  t.truthy(seen.descriptionFacets, "descriptionFacets")
end)

t.test("only allowlisted fields are copied", function()
  local s = shared()
  local record = { name = "Old", createdAt = "2026-01-01T00:00:00Z" }
  s.apply_changes(record, {
    name = "New",
    ["$type"] = "games.gamesgamesgamesgames.contribution",
    createdAt = "1999-01-01T00:00:00Z",
    publishedAt = "1999-01-01T00:00:00Z",
    somethingInvented = true,
  })

  t.eq(record.name, "New", "allowlisted field applied")
  t.eq(record.createdAt, "2026-01-01T00:00:00Z", "createdAt is not writable")
  t.eq(record["$type"], nil, "$type is not writable")
  t.eq(record.publishedAt, nil, "publishedAt is not writable")
  t.eq(record.somethingInvented, nil, "unknown keys ignored")
end)

t.test("a field absent from changes is left alone", function()
  local s = shared()
  local record = { name = "Keep", summary = "Keep too" }
  s.apply_changes(record, { name = "Changed" })
  t.eq(record.summary, "Keep too", "untouched field")
end)

t.test("an empty string overwrites", function()
  -- Pinned deliberately: the `~= nil` check means clearing a field is a real
  -- edit, not a no-op. Changing this is a product decision, not a refactor.
  local s = shared()
  local record = { summary = "Something" }
  s.apply_changes(record, { summary = "" })
  t.eq(record.summary, "", "empty string applied")
end)

t.test("array fields replace wholesale rather than merging", function()
  local s = shared()
  local record = { genres = { "rpg", "strategy" } }
  s.apply_changes(record, { genres = { "puzzle" } })
  t.deep_eq(record.genres, { "puzzle" }, "genres replaced")
end)

t.test("patches order oldest first, uri breaking ties", function()
  local s = shared()
  local ordered = s.order_patches({
    { uri = "at://p/c/b", createdAt = "2026-02-01T00:00:00Z" },
    { uri = "at://p/c/a", createdAt = "2026-01-01T00:00:00Z" },
    { uri = "at://p/c/c", createdAt = "2026-01-01T00:00:00Z" },
  })
  t.eq(ordered[1].uri, "at://p/c/a", "oldest first")
  t.eq(ordered[2].uri, "at://p/c/c", "tie broken by uri")
  t.eq(ordered[3].uri, "at://p/c/b", "newest last")
end)

t.test("patches on disjoint fields compose", function()
  local s = shared()
  local record = { name = "Base", summary = "Base" }
  s.apply_patches(record, {
    { uri = "at://p/c/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "Named" } },
    { uri = "at://p/c/2", createdAt = "2026-02-01T00:00:00Z", changes = { summary = "Summarised" } },
  })
  t.eq(record.name, "Named", "first patch")
  t.eq(record.summary, "Summarised", "second patch")
end)

t.test("two patches on one field resolve by createdAt", function()
  local s = shared()
  local record = { name = "Base" }
  s.apply_patches(record, {
    { uri = "at://p/c/2", createdAt = "2026-02-01T00:00:00Z", changes = { name = "Newer" } },
    { uri = "at://p/c/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "Older" } },
  })
  t.eq(record.name, "Newer", "newest wins regardless of input order")
end)

t.test("a patch with no changes is harmless", function()
  local s = shared()
  local record = { name = "Base" }
  s.apply_patches(record, { { uri = "at://p/c/1", createdAt = "2026-01-01T00:00:00Z" } })
  t.eq(record.name, "Base", "nothing applied")
end)

t.test("deep_copy leaves the original alone", function()
  local s = shared()
  local original = { name = "Base", releases = { { platform = "pc" } } }
  local copy = s.deep_copy(original)
  copy.name = "Changed"
  copy.releases[1].platform = "switch"
  t.eq(original.name, "Base", "scalar untouched")
  t.eq(original.releases[1].platform, "pc", "nested table untouched")
end)

t.report()
