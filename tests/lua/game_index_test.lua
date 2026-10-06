package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local SOURCE = "src/shared/game_index.lua"
local EXPORTS = {
  "to_doc_id", "parse_release_date", "get_release_info",
  "derive_release_year", "derive_release_decade", "build_age_rating_descriptions",
  "index_game", "delete_game_index",
}

local function shared(extra_env)
  local environment = {
    env = { MEILISEARCH_API_KEY = "key", MEILISEARCH_URL = "http://meili" },
  }
  for k, v in pairs(extra_env or {}) do
    environment[k] = v
  end
  return t.load_shared(SOURCE, EXPORTS, environment)
end

t.test("release dates parse every accepted shape", function()
  local s = shared()
  t.eq(s.parse_release_date("2026-03-14"), 20260314, "full date")
  t.eq(s.parse_release_date("2026-03"), 20260301, "year and month")
  t.eq(s.parse_release_date("2026-Q3"), 20260701, "quarter")
  t.eq(s.parse_release_date("2026"), 20260101, "year only")
  t.eq(s.parse_release_date("TBD"), nil, "TBD")
  t.eq(s.parse_release_date(nil), nil, "missing")
end)

t.test("the earliest release date wins", function()
  local s = shared()
  local earliest, cancelled = s.get_release_info({
    { releaseDates = { { releasedAt = "2027-01-01" }, { releasedAt = "2026-06-01" } } },
  })
  t.eq(earliest, 20260601, "earliest")
  t.falsy(cancelled, "not cancelled")
end)

t.test("a wholly cancelled game is flagged with the sentinel", function()
  local s = shared()
  local earliest, cancelled = s.get_release_info({
    { releaseDates = { { releasedAt = "2026-01-01", status = "cancelled" } } },
  })
  t.eq(earliest, 10000101, "sentinel")
  t.truthy(cancelled, "cancelled")
end)

t.test("decades read the way a sentence does", function()
  local s = shared()
  t.eq(s.derive_release_year(20260314), 2026, "year")
  t.eq(s.derive_release_decade(2026), "in the mid 2020s (20s)", "mid decade")
  t.eq(s.derive_release_decade(2000), "in the early 2000s (2000s)", "century boundary")
end)

t.test("age rating descriptions join into one sentence", function()
  local s = shared()
  t.eq(
    s.build_age_rating_descriptions({ "esrb:T" }),
    "Rated ESRB T for Teen (ages 13+, North America).",
    "single rating"
  )
  t.eq(s.build_age_rating_descriptions({}), nil, "no ratings")
  t.eq(s.build_age_rating_descriptions({ "nonsense:X" }), nil, "unknown rating")
end)

t.test("document ids are stable and url-safe", function()
  local s = shared()
  local id = s.to_doc_id("at://did:plc:owner/games.gamesgamesgamesgames.game/abc")
  t.eq(id, s.to_doc_id("at://did:plc:owner/games.gamesgamesgamesgames.game/abc"), "stable")
  t.falsy(id:find("[^A-Za-z0-9_-]"), "url-safe alphabet only")
end)

t.test("index_game posts one document for the record it is given", function()
  local posts = {}
  local s = shared({
    db = { raw = function() return {} end },
    json = { encode = function(value) return value end },
    http = { post = function(url, options) table.insert(posts, { url = url, body = options.body }) end },
    toarray = function(value) return value end,
  })

  s.index_game("at://did:plc:owner/games.gamesgamesgamesgames.game/1", "did:plc:owner", {
    name = "Overlaid Name",
    applicationType = "game",
  })

  t.eq(#posts, 1, "one post")
  t.eq(posts[1].body[1].name, "Overlaid Name", "indexes the record it was handed")
  t.eq(posts[1].body[1].did, "did:plc:owner", "carries the did")
end)

t.test("delete_game_index removes the document", function()
  local deletes = {}
  local s = shared({
    http = { delete = function(url) table.insert(deletes, url) end },
  })

  s.delete_game_index("at://did:plc:owner/games.gamesgamesgamesgames.game/1")
  t.eq(#deletes, 1, "one delete")
  t.truthy(deletes[1]:find("/indexes/records/documents/", 1, true), "documents endpoint")
end)

t.report()
