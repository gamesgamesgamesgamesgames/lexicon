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

t.test("ordering many indistinguishable patches does not raise", function()
  -- `table.sort` raises "invalid order function for sorting" when the comparator
  -- is not a strict order. Equal elements are the case that catches a `<=`, so
  -- pin a batch of them: same createdAt, same uri, nothing to tell them apart.
  local s = shared()
  local patches = {}
  for index = 1, 64 do
    table.insert(patches, { uri = "at://p/c/same", createdAt = "2026-01-01T00:00:00Z", index = index })
  end
  local ordered = s.order_patches(patches)
  t.eq(#ordered, 64, "every patch survived the sort")
end)

-- A `db` stub that records the SQL it was handed, so the tests can assert on
-- the repo guard as well as the result.
local function db_stub(rows)
  local calls = {}
  return {
    calls = calls,
    db = {
      raw = function(sql, bind)
        table.insert(calls, { sql = sql, bind = bind })
        return rows
      end,
    },
  }
end

local JSON_STUB = {
  decode = function(value)
    -- The stub stores records as tables already; decode is the identity.
    return value
  end,
}

local function with_db(rows, pentaract)
  local stub = db_stub(rows)
  local shared = t.load_shared(
    SOURCE,
    { "GAME_FIELDS", "apply_changes", "order_patches", "apply_patches", "deep_copy",
      "load_patches_by_subject", "overlay_game" },
    { db = stub.db, json = JSON_STUB, env = { PENTARACT_DID = pentaract } }
  )
  return shared, stub
end

t.test("patch loading constrains the repo to Pentaract", function()
  local s, stub = with_db({}, "did:web:pentaract")
  s.load_patches_by_subject({ "at://did:plc:owner/games.gamesgamesgamesgames.game/1" })

  t.eq(#stub.calls, 1, "one query")
  t.truthy(stub.calls[1].sql:find("did = $1", 1, true), "did is filtered")
  t.eq(stub.calls[1].bind[1], "did:web:pentaract", "filtered to the Pentaract repo")
end)

t.test("patch loading groups by subject", function()
  local s = with_db({
    { uri = "at://p/c/1", record = { subject = "at://a/g/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "A" } } },
    { uri = "at://p/c/2", record = { subject = "at://a/g/2", createdAt = "2026-01-02T00:00:00Z", changes = { name = "B" } } },
    { uri = "at://p/c/3", record = { subject = "at://a/g/1", createdAt = "2026-01-03T00:00:00Z", changes = { summary = "C" } } },
  }, "did:web:pentaract")

  local by_subject = s.load_patches_by_subject({ "at://a/g/1", "at://a/g/2" })
  t.eq(#by_subject["at://a/g/1"], 2, "two patches on the first game")
  t.eq(#by_subject["at://a/g/2"], 1, "one on the second")
end)

t.test("patch loading binds one placeholder per uri", function()
  local s, stub = with_db({}, "did:web:pentaract")
  s.load_patches_by_subject({ "at://a/g/1", "at://a/g/2" })

  t.truthy(stub.calls[1].sql:find("IN ($2, $3)", 1, true), "placeholders")
  t.eq(#stub.calls[1].bind, 3, "did plus two subjects")
end)

t.test("patch loading short-circuits on no uris", function()
  local s, stub = with_db({}, "did:web:pentaract")
  t.deep_eq(s.load_patches_by_subject({}), {}, "empty result")
  t.eq(#stub.calls, 0, "no query issued")
end)

t.test("patch loading returns nothing when PENTARACT_DID is unset", function()
  -- Without the guard an unconfigured instance would overlay patches from any
  -- repo on the network.
  local s, stub = with_db({ { uri = "at://p/c/1", record = { subject = "at://a/g/1", changes = { name = "X" } } } }, nil)
  t.deep_eq(s.load_patches_by_subject({ "at://a/g/1" }), {}, "no patches")
  t.eq(#stub.calls, 0, "no query issued")
end)

t.test("patch loading returns nothing when PENTARACT_DID is empty", function()
  -- An empty string is what a misconfigured deploy actually produces, and it is
  -- truthy in Lua: it has to be rejected by value, not by presence. Were it
  -- passed through, `did = ''` would match no repo today, but the guard is the
  -- thing being pinned, not the accident that it currently fails closed anyway.
  local s, stub = with_db({ { uri = "at://p/c/1", record = { subject = "at://a/g/1", changes = { name = "X" } } } }, "")
  t.deep_eq(s.load_patches_by_subject({ "at://a/g/1" }), {}, "no patches")
  t.eq(#stub.calls, 0, "no query issued")
end)

t.test("overlay_game applies the live patches", function()
  local s = with_db({
    { uri = "at://p/c/1", record = { subject = "at://a/g/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "Patched" } } },
  }, "did:web:pentaract")

  local overlaid = s.overlay_game({ name = "Stored", summary = "Stored" }, "at://a/g/1")
  t.eq(overlaid.name, "Patched", "patched field")
  t.eq(overlaid.summary, "Stored", "unpatched field")
end)

t.test("overlay_game never mutates its input", function()
  -- A record handler's return value replaces what gets stored, so mutating the
  -- record here would persist the overlay into the index row.
  local s = with_db({
    { uri = "at://p/c/1", record = { subject = "at://a/g/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "Patched" } } },
  }, "did:web:pentaract")

  local stored = { name = "Stored", releases = { { platform = "pc" } } }
  local overlaid = s.overlay_game(stored, "at://a/g/1")
  t.eq(stored.name, "Stored", "input untouched")
  t.eq(overlaid.name, "Patched", "copy patched")
  overlaid.releases[1].platform = "switch"
  t.eq(stored.releases[1].platform, "pc", "nested tables copied too")
end)

t.test("overlay_game can exclude a patch that is being deleted", function()
  -- A record handler runs before the row is removed, so the patch being deleted
  -- is still in the index when the reindex happens.
  local s = with_db({
    { uri = "at://p/c/1", record = { subject = "at://a/g/1", createdAt = "2026-01-01T00:00:00Z", changes = { name = "Going" } } },
    { uri = "at://p/c/2", record = { subject = "at://a/g/1", createdAt = "2026-01-02T00:00:00Z", changes = { summary = "Staying" } } },
  }, "did:web:pentaract")

  local overlaid = s.overlay_game({ name = "Stored", summary = "Stored" }, "at://a/g/1", "at://p/c/1")
  t.eq(overlaid.name, "Stored", "excluded patch reverted")
  t.eq(overlaid.summary, "Staying", "other patch still applied")
end)

t.test("overlay_game returns a copy even with no patches", function()
  local s = with_db({}, "did:web:pentaract")
  local stored = { name = "Stored" }
  local overlaid = s.overlay_game(stored, "at://a/g/1")
  overlaid.name = "Changed"
  t.eq(stored.name, "Stored", "caller's record untouched")
end)

t.report()
