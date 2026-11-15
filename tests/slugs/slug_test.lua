-- Standalone tests for slug assignment in game.lua's index hook and in
-- createGame, against a stub of the HappyView globals they use.
-- Run: lua tests/slugs/slug_test.lua src/scripts/games/gamesgamesgamesgames
local DIR = arg[1]
local G = "games.gamesgamesgamesgames.game"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function uri(r) return "at://did:web:catalogue/" .. G .. "/" .. r end

-- A slugs table: slug is the primary key, a uri may own several rows.
local function new_slugs(rows)
  local S = { by_slug = {}, order = {}, inserts = 0, fail = false }
  for _, r in ipairs(rows or {}) do S.by_slug[r[1]] = r[2]; table.insert(S.order, r[1]) end
  function S.of(u)
    local out = {}
    for _, s in ipairs(S.order) do if S.by_slug[s] == u then table.insert(out, s) end end
    return out
  end
  -- Runs before each INSERT; lets a test play the part of a concurrent writer.
  S.before_insert = nil
  return S
end

local VERIFIED = { ["did:plc:verified"] = true }

local function install_db(S, extra)
  db = { backlinks = function() return { records = {} } end, raw = function(sql, b)
    if S.fail then error("db is down") end
    if not extra and sql:find("dev.cartridge.graph.verification", 1, true) then
      assert(b[1] == "did:plc:verifier", "verification must come from VERIFIER_DID")
      S.verify_checks = (S.verify_checks or 0) + 1
      return VERIFIED[b[2]] and { { uri = "v" } } or {}
    end
    if extra then
      local handled, res = extra(sql, b)
      if handled then return res end
    end
    if sql:find("SELECT slug FROM slugs WHERE uri = $1", 1, true) then
      assert(sql:find("ORDER BY length(slug), slug LIMIT 1", 1, true), "a lookup by uri must be deterministic")
      local own = S.of(b[1])
      table.sort(own, function(x, y) if #x ~= #y then return #x < #y end return x < y end)
      return own[1] and { { slug = own[1] } } or {}
    elseif sql:find("SELECT uri FROM slugs WHERE slug = $1", 1, true) then
      local owner = S.by_slug[b[1]]
      return owner and { { uri = owner } } or {}
    elseif sql:find("INSERT INTO slugs", 1, true) then
      if S.before_insert then local f = S.before_insert; S.before_insert = nil; f() end
      S.inserts = S.inserts + 1
      local existing = S.by_slug[b[1]]
      if sql:find("DO NOTHING", 1, true) then
        if not existing then S.by_slug[b[1]] = b[2]; table.insert(S.order, b[1]) end
      else
        assert(sql:find("DO UPDATE SET uri = $2", 1, true), "unexpected insert " .. sql)
        if not existing then table.insert(S.order, b[1]) end
        S.by_slug[b[1]] = b[2]
      end
      return {}
    elseif sql:find("DELETE FROM slugs WHERE uri = $1 AND slug <> $2", 1, true) then
      for s, u in pairs(S.by_slug) do if u == b[1] and s ~= b[2] then S.by_slug[s] = nil end end
      local kept = {}
      for _, s in ipairs(S.order) do if S.by_slug[s] then table.insert(kept, s) end end
      S.order = kept
      return {}
    elseif sql:find("INSERT INTO external_ids", 1, true) then
      return {}
    end
    error("unexpected sql " .. sql)
  end }
end

-- Run game.lua's hook for one record. Returns the document it posted.
local function hook(S, target, record, act, repo_did)
  local posted, logs = nil, {}
  env = { MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili", PENTARACT_DID = "did:web:catalogue", VERIFIER_DID = "did:plc:verifier" }
  json = { encode = function(x) posted = x; return "<json>" end }
  toarray = function(x) return x end
  log = function(m) table.insert(logs, m) end
  http = { post = function() return { status = 202 } end, delete = function() return { status = 202 } end }
  install_db(S)
  action, did = act or "create", repo_did or "did:web:catalogue"
  _G.uri = target
  _G.record = record
  handle = nil
  dofile(DIR .. "/game.lua")
  local ok, res = pcall(handle)
  assert(ok, res)
  return posted and posted[1], logs
end

t("a game with no slug gets one from its name", function()
  local S = new_slugs()
  local doc = hook(S, uri("a"), { name = "Soccer Tsuku 2002" })
  eq(doc.slug, "soccer-tsuku-2002")
  eq(S.by_slug["soccer-tsuku-2002"], uri("a"))
end)

t("an existing slug is kept and nothing is written", function()
  local S = new_slugs({ { "old-slug", uri("a") } })
  local doc = hook(S, uri("a"), { name = "A New Name" })
  eq(doc.slug, "old-slug"); eq(S.inserts, 0); eq(#S.of(uri("a")), 1)
end)

t("a slug another game holds gets a numeric suffix, never repointed", function()
  local S = new_slugs({ { "fallout-2", uri("x") }, { "fallout-2-2", uri("y") } })
  local doc = hook(S, uri("a"), { name = "Fallout 2" })
  eq(doc.slug, "fallout-2-3")
  eq(S.by_slug["fallout-2"], uri("x")); eq(S.by_slug["fallout-2-2"], uri("y"))
end)

t("punctuation and accents follow createGame's rule", function()
  local S = new_slugs()
  eq(hook(S, uri("a"), { name = "Omelet's Quest: Part II" }).slug, "omelets-quest-part-ii")
  eq(hook(S, uri("b"), { name = "Löwenzahn 3" }).slug, "lowenzahn-3")
end)

t("a name with nothing sluggable leaves the game without a slug", function()
  local S = new_slugs()
  local doc = hook(S, uri("a"), { name = "!!!" })
  eq(doc.slug, nil); eq(S.inserts, 0)
end)

t("an update to a game with no slug assigns one too", function()
  local S = new_slugs()
  eq(hook(S, uri("a"), { name = "Dirt 3" }, "update").slug, "dirt-3")
end)

t("a delete does not touch slugs", function()
  local S = new_slugs()
  hook(S, uri("a"), nil, "delete")
  eq(S.inserts, 0)
end)

t("a procedure that takes the slug mid-way leaves the game with that one slug", function()
  local S = new_slugs()
  -- Between the hook's checks and its insert, a procedure assigns the same
  -- slug to the same game.
  S.before_insert = function() S.by_slug["dirt-3"] = uri("a"); table.insert(S.order, "dirt-3") end
  local doc = hook(S, uri("a"), { name = "Dirt 3" })
  eq(doc.slug, "dirt-3"); eq(#S.of(uri("a")), 1)
end)

t("another game taking the slug mid-way moves this one to the next suffix", function()
  local S = new_slugs()
  S.before_insert = function() S.by_slug["dirt-3"] = uri("z"); table.insert(S.order, "dirt-3") end
  local doc = hook(S, uri("a"), { name = "Dirt 3" })
  eq(doc.slug, "dirt-3-2"); eq(S.by_slug["dirt-3"], uri("z"))
end)

t("a slug failure still indexes the game, without a slug", function()
  local S = new_slugs()
  local posted, logs
  env = { MEILISEARCH_API_KEY = "k", MEILISEARCH_URL = "http://meili", PENTARACT_DID = "did:web:catalogue" }
  json = { encode = function(x) posted = x; return "<json>" end }
  toarray = function(x) return x end
  logs = {}
  log = function(m) table.insert(logs, m) end
  http = { post = function() return { status = 202 } end }
  db = { backlinks = function() return { records = {} } end, raw = function(sql)
    if sql:find("INSERT INTO slugs", 1, true) then error("slugs is locked") end
    return {}
  end }
  action, _G.uri, did, _G.record = "create", uri("a"), "did:web:catalogue", { name = "Dirt 3" }
  handle = nil
  dofile(DIR .. "/game.lua")
  local ok, err = pcall(handle)
  assert(ok, err)
  eq(posted[1].slug, nil); eq(posted[1].name, "Dirt 3")
  assert(logs[1] and logs[1]:find("could not assign a slug", 1, true), "should log the failure")
end)

-- createGame, verified path: Record.new():save() creates the game. `hook_first`
-- runs game.lua's assignment inside the save, as if the firehose event had
-- been indexed before createGame got to its own slug write.
local function create_game(S, body, hook_first)
  local new_uri = uri("new")
  env = { VERIFIER_DID = "did:plc:verifier" }
  json = { encode = function() return "<json>" end, decode = function() return {} end }
  http = { get = function() return { status = 404 } end }
  caller_did = "did:plc:dev"
  log = function() end
  input = body
  now = function() return "2026-11-15T00:00:00Z" end
  install_db(S, function(sql)
    if sql:find("dev.cartridge.graph.verification", 1, true) then return true, { { uri = "v" } } end
  end)
  Record = { new = function(_, data)
    return { save = function(self)
      self._uri, self._cid = new_uri, "cid"
      if hook_first then
        S.inserts = S.inserts + 1
        local base = hook_first
        if not S.by_slug[base] then S.by_slug[base] = new_uri; table.insert(S.order, base) end
      end
    end }
  end }
  handle = nil
  dofile(DIR .. "/createGame.lua")
  local ok, res = pcall(handle)
  assert(ok, res)
  return new_uri
end

t("createGame still assigns a generated slug when the hook has not run", function()
  local S = new_slugs()
  local u = create_game(S, { name = "Dirt 3", applicationType = "game" })
  eq(S.by_slug["dirt-3"], u); eq(#S.of(u), 1)
end)

t("createGame keeps the hook's generated slug instead of adding a second", function()
  local S = new_slugs({ { "dirt-3", uri("x") } })
  -- The hook found dirt-3 taken and assigned dirt-3-2 first.
  local u = create_game(S, { name = "Dirt 3", applicationType = "game" }, "dirt-3-2")
  eq(#S.of(u), 1); eq(S.of(u)[1], "dirt-3-2"); eq(S.by_slug["dirt-3"], uri("x"))
end)

t("createGame's explicit slug replaces the hook's generated one", function()
  local S = new_slugs()
  local u = create_game(S, { name = "Dirt 3", slug = "dirt-three", applicationType = "game" }, "dirt-3")
  eq(#S.of(u), 1); eq(S.of(u)[1], "dirt-three"); eq(S.by_slug["dirt-3"], nil)
end)

t("createGame's explicit slug is set when the hook has not run", function()
  local S = new_slugs()
  local u = create_game(S, { name = "Dirt 3", slug = "dirt-three", applicationType = "game" })
  eq(#S.of(u), 1); eq(S.of(u)[1], "dirt-three")
end)

t("a game with two slugs is indexed under the shortest, then alphabetical", function()
  local S = new_slugs({ { "fire-emblem-the-blazing-blade", uri("a") }, { "fire-emblem", uri("a") }, { "fire-emblex", uri("a") } })
  eq(hook(S, uri("a"), { name = "Fire Emblem" }).slug, "fire-emblem")
end)

t("createGame's generated slug never takes another game's slug", function()
  local S = new_slugs({ { "dirt-3", uri("x") } })
  local u = create_game(S, { name = "Dirt 3", applicationType = "game" })
  eq(S.by_slug["dirt-3"], uri("x")); eq(#S.of(u), 1); eq(S.of(u)[1], "dirt-3-2")
end)

t("createGame does not fail when its slug write fails", function()
  local S = new_slugs()
  S.before_insert = function() error("slugs is locked") end
  create_game(S, { name = "Dirt 3", applicationType = "game" })
end)

local function dev_uri(d, r) return "at://" .. d .. "/" .. G .. "/" .. r end

t("accented letters fold to plain ASCII", function()
  local S = new_slugs()
  eq(hook(S, uri("a"), { name = "Löwenzahn 3" }).slug, "lowenzahn-3")
  eq(hook(S, uri("b"), { name = "Pokémon: Édition Ñandú" }).slug, "pokemon-edition-nandu")
  eq(hook(S, uri("c"), { name = "ĐẠI VIỆT" }).slug, "ai-viet")
end)

t("the catalogue repo gets a slug without a verification lookup", function()
  local S = new_slugs()
  eq(hook(S, uri("a"), { name = "Dirt 3" }).slug, "dirt-3"); eq(S.verify_checks, nil)
end)

t("a verified developer's game gets a slug", function()
  local S = new_slugs()
  local u = dev_uri("did:plc:verified", "g")
  eq(hook(S, u, { name = "Dirt 3" }, "create", "did:plc:verified").slug, "dirt-3"); eq(S.by_slug["dirt-3"], u)
end)

t("another account's game gets no automatic slug", function()
  local S = new_slugs()
  local doc = hook(S, dev_uri("did:plc:someone", "g"), { name = "Elden Ring" }, "create", "did:plc:someone")
  eq(doc.slug, nil); eq(S.inserts, 0)
end)

t("another account's game keeps a slug a procedure gave it", function()
  local S = new_slugs({ { "folk", dev_uri("did:plc:someone", "folk") } })
  local doc = hook(S, dev_uri("did:plc:someone", "folk"), { name = "FOLK" }, "update", "did:plc:someone")
  eq(doc.slug, "folk"); eq(S.inserts, 0)
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
