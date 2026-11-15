-- Standalone tests for src/scripts/games/gamesgamesgamesgames/search.lua
-- against a stub of the HappyView globals it uses.
-- Run: lua tests/search/search_test.lua src/scripts/games/gamesgamesgamesgames/search.lua
local SCRIPT = arg[1]

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

-- Runs one search. `hits` is what Meilisearch returns for the main query and
-- `coll_hits` for the collection query. Returns the result and the main query
-- body that was sent.
local function run(p, hits, coll_hits)
  local S = {}
  env = { MEILISEARCH_URL = "http://meili", MEILISEARCH_API_KEY = "k" }
  params = p
  toarray = function(x) return x end
  json = {
    encode = function(x) S.sent = x; return "<json>" end,
    decode = function() return S.reply end,
  }
  http = { post = function(url)
    if url:find("multi%-search") then
      S.reply = { results = { { hits = hits or {} }, { hits = coll_hits or {} } } }
    else
      S.reply = { hits = hits or {} }
    end
    return { status = 200, body = "<json>" }
  end }
  dofile(SCRIPT)
  local res = handle()
  local body = S.sent.queries and S.sent.queries[1] or S.sent
  return res, body
end

local function ratio(q, extra)
  local p = { q = q }
  for k, v in pairs(extra or {}) do p[k] = v end
  local _, body = run(p)
  return body.hybrid and body.hybrid.semanticRatio
end

t("a title-length query is keyword only", function()
  eq(ratio("doom"), 0)
  eq(ratio("half-life 2"), 0)
  eq(ratio("ocarina of time"), 0)
  eq(ratio("the witcher 3 wild"), 0)
end)

t("a five-word query keeps half semantic weight", function()
  eq(ratio("the legend of zelda ocarina"), 0.5)
end)

t("six words or more lean semantic, as before", function()
  eq(ratio("a cozy game about running a farm"), 0.7)
end)

t("an age or region hint keeps half semantic weight on a short query", function()
  eq(ratio("games for kids"), 0.5)
  eq(ratio("japanese rpg"), 0.5)
end)

t("an empty query is keyword only", function()
  eq(ratio(""), 0)
end)

t("a games-free type filter sends no hybrid block", function()
  local _, body = run({ q = "nintendo", types = "profile" })
  eq(body.hybrid, nil)
end)

local C = "at://c/coll/1"
local function game(name, date, in_coll)
  return { type = "game", uri = "at://g/" .. name, name = name, firstReleaseDate = date, collections = in_coll and { C } or nil }
end

t("the collection boost keeps Meilisearch's order among boosted games", function()
  local res = run({ q = "ocarina of time" }, {
    game("fan", 20140101, false),
    game("original", 19981121, true),
    game("remake", 20110616, true),
    game("sequel", 20230512, true),
  }, { { uri = C } })
  local names = {}
  for _, r in ipairs(res.results or res.items or res) do table.insert(names, r.name) end
  eq(table.concat(names, ","), "original,remake,sequel,fan")
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
