-- Standalone tests for officialScore and popularityBucket in the shared game
-- document builder (src/shared/game_index.lua).
-- Run: lua tests/official/signals_test.lua
local F = dofile("tests/search-reindex/fake.lua")

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local GAME = "at://did:web:cat/games.gamesgamesgamesgames.game/oot"
local NINTENDO, FANS = "at://did:plc:n/games.gamesgamesgamesgames.org.profile/self", "at://did:plc:f/games.gamesgamesgamesgames.org.profile/self"

local function credit(org, roles, game)
  return { uri = "at://c/" .. org, org = { uri = org, cid = "c" }, game = { uri = game or GAME, cid = "c" }, roles = roles }
end

local function build(record, opts)
  F.install(opts or {})
  local src = io.open("src/shared/game_index.lua"):read("a")
  local b = assert(load(src .. "\nreturn build_game_doc"))()
  local d = b(GAME, "did:web:cat", record)
  return d.officialScore, d.popularityBucket
end

local function game(extra)
  local r = { name = "The Legend of Zelda: Ocarina of Time", applicationType = "game", externalIds = { igdb = "1029" } }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local FULL = {
  credits = { [GAME] = { credit(NINTENDO, { "developer", "publisher" }) } },
  publisher_counts = { [NINTENDO] = 500 },
  wikidata = { ["1029"] = { sitelinks = 42, has_publisher = 1 } },
}

t("an established publisher, an age rating and a Wikidata item score 4", function()
  local s, p = build(game({ ageRatings = { { organization = "esrb", rating = "E" } } }), FULL)
  eq(s, 4); eq(p, 7)
end)

t("a game with no signals scores 1", function()
  local s, p = build(game({ externalIds = {} }))
  eq(s, 1); eq(p, 0)
end)

t("mods and forks score 0 whatever else they have", function()
  eq((build(game({ applicationType = "mod" }), FULL)), 0)
  eq((build(game({ applicationType = "fork" }), FULL)), 0)
end)

t("a fan keyword scores 0, in any case", function()
  eq((build(game({ keywords = { "Zelda", "Fan Game" } }), FULL)), 0)
  eq((build(game({ keywords = { "romhack" } }))), 0)
end)

t("a Wikidata mod or fan game class scores 0", function()
  local s = build(game(), { wikidata = { ["1029"] = { sitelinks = 3, has_publisher = 0, veto_class = "Q865493" } } })
  eq(s, 0)
end)

t("a publisher with fewer than 10 games does not count", function()
  local s = build(game({ externalIds = {} }), { credits = { [GAME] = { credit(FANS, { "publisher" }) } }, publisher_counts = { [FANS] = 2 } })
  eq(s, 1)
end)

t("a developer-only credit does not count as a publisher", function()
  local s = build(game({ externalIds = {} }), { credits = { [GAME] = { credit(NINTENDO, { "developer" }) } }, publisher_counts = { [NINTENDO] = 500 } })
  eq(s, 1)
end)

t("ESRB rating pending is not an age rating", function()
  eq((build(game({ externalIds = {}, ageRatings = { { organization = "esrb", rating = "RP" } } }))), 1)
end)

t("a Wikidata item with a publisher but no sitelinks still counts, with no popularity", function()
  local s, p = build(game(), { wikidata = { ["1029"] = { sitelinks = 0, has_publisher = 1 } } })
  eq(s, 2); eq(p, 0)
end)

t("popularityBucket is floor(log2(1 + 5 * sitelinks)), capped at 10", function()
  local function bucket(n) local _, p = build(game(), { wikidata = { ["1029"] = { sitelinks = n, has_publisher = 0 } } }); return p end
  eq(bucket(1), 2); eq(bucket(15), 6); eq(bucket(42), 7); eq(bucket(5000), 10)
end)

t("a missing wikidata_games table means no Wikidata signal, not an error", function()
  local s, p = build(game({ externalIds = { igdb = "1029" } }), { wikidata_missing = true })
  eq(s, 1); eq(p, 0)
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
