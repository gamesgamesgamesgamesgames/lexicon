-- Standalone tests for src/jobs/slugs.backfill.lua and its procedure, against
-- a stub of the HappyView globals they use.
-- Run: lua tests/slug-backfill/job_test.lua src/jobs/slugs.backfill.lua src/scripts/games/gamesgamesgamesgames/backfillGameSlugs.lua
local JOB, PROC = arg[1], arg[2]
local G = "games.gamesgamesgamesgames.game"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function uri(r) return "at://did:web:catalogue/" .. G .. "/" .. r end

-- opts.games: { [uri] = name }. opts.slugs: { {slug, uri} }. opts.docs: { [uri] = doc }
-- where a doc is { type = "game", slug = ... } or { gutted = true }.
local function run(opts)
  local S = {
    games = opts.games or {}, by_slug = {}, docs = opts.docs or {}, puts = {}, fetches = 0,
    chained = {}, warns = {}, waits = 0, inserts = 0,
  }
  for _, r in ipairs(opts.slugs or {}) do S.by_slug[r[1]] = r[2] end
  local function own(u)
    local best -- shortest, then alphabetical, as the job orders it
    for s, owner in pairs(S.by_slug) do if owner == u and (not best or #s < #best or (#s == #best and s < best)) then best = s end end
    return best
  end

  env = opts.env or { MEILISEARCH_URL = "http://meili", MEILISEARCH_API_KEY = "k" }
  json = {
    -- Bodies stay tables so the fakes can read them; concatenating one (the
    -- log line) yields a placeholder.
    encode = function(x)
      S.last_encoded = x
      if type(x) == "table" and getmetatable(x) == nil then
        setmetatable(x, { __concat = function(a, b)
          return (type(a) == "table" and "<json>" or a) .. (type(b) == "table" and "<json>" or b)
        end })
      end
      return x
    end,
    decode = function(x) return x end,
  }
  toarray = function(x) return x end
  log = function() end
  jobs = { create = function(ty, inp) table.insert(S.chained, { type = ty, input = inp }); return "job-" .. #S.chained end }
  job = {
    input = opts.input,
    should_stop = function() return opts.stop == true end,
    progress = function(p) S.progress = p end,
    warn = function(m) table.insert(S.warns, m) end,
    wait = function() S.waits = S.waits + 1 end,
  }
  http = {
    post = function(url, o)
      assert(url == "http://meili/indexes/records/documents/fetch", "unexpected post " .. url)
      S.fetches = S.fetches + 1
      local results = {}
      for u in o.body.filter:gmatch('"([^"]+)"') do
        local d = S.docs[u]
        if d and not d.gutted then
          table.insert(results, { id = "id:" .. u, uri = u, type = d.type, slug = d.slug })
        end
      end
      return { status = opts.fetch_status or 200, body = { results = results } }
    end,
    put = function(url, o)
      assert(url == "http://meili/indexes/records/documents", "unexpected put " .. url)
      for _, d in ipairs(o.body) do
        table.insert(S.puts, d)
        local u = d.id:gsub("^id:", "")
        S.docs[u].slug = d.slug
      end
      return { status = 202, body = {} }
    end,
  }
  db = { raw = function(sql, b)
    if sql:find("FROM happyview_records r", 1, true) then
      assert(sql:find("NOT EXISTS (SELECT 1 FROM slugs s WHERE s.uri = r.uri)", 1, true))
      local limit = tonumber(sql:match("LIMIT (%d+)"))
      local list = {}
      for u, name in pairs(S.games) do
        if u > b[2] and not own(u) then table.insert(list, { uri = u, name = name }) end
      end
      table.sort(list, function(x, y) return x.uri < y.uri end)
      local out = {}
      for i = 1, math.min(limit, #list) do out[i] = list[i] end
      return out
    elseif sql:find("FROM happyview_records WHERE uri = $1", 1, true) then
      local name = S.games[b[1]]
      return name and { { name = name } } or {}
    elseif sql:find("SELECT slug FROM slugs WHERE uri = $1", 1, true) then
      assert(sql:find("ORDER BY length(slug), slug LIMIT 1", 1, true), "a lookup by uri must be deterministic")
      local s = own(b[1])
      return s and { { slug = s } } or {}
    elseif sql:find("SELECT uri FROM slugs WHERE slug = $1", 1, true) then
      return S.by_slug[b[1]] and { { uri = S.by_slug[b[1]] } } or {}
    elseif sql:find("INSERT INTO slugs", 1, true) then
      assert(sql:find("ON CONFLICT (slug) DO NOTHING", 1, true), "must never repoint a slug")
      S.inserts = S.inserts + 1
      if not S.by_slug[b[1]] then S.by_slug[b[1]] = b[2] end
      return {}
    end
    error("unexpected sql " .. sql)
  end }
  handle = nil
  dofile(JOB)
  local ok, res = pcall(handle)
  return ok, res, S
end

t("a dry run chooses slugs and writes nothing", function()
  local ok, res, S = run({
    input = { dryRun = true },
    games = { [uri("a")] = "Dirt 3", [uri("b")] = "Fallout 2" },
    slugs = { { "fallout-2", uri("x") } },
    docs = { [uri("a")] = { type = "game" }, [uri("b")] = { type = "game" } },
  })
  assert(ok, res)
  local c = res.totals.counts
  eq(c.wouldAssign, 2); eq(c.assigned, 0); eq(c.wouldPush, 2); eq(c.pushed, 0)
  eq(S.inserts, 0); eq(#S.puts, 0)
  local by = {}
  for _, s in ipairs(res.totals.samples.assigned) do by[s.uri] = s.slug end
  eq(by[uri("a")], "dirt-3"); eq(by[uri("b")], "fallout-2-2")
end)

t("a dry run does not give two games in one chunk the same slug", function()
  local ok, res = run({
    input = { dryRun = true },
    games = { [uri("a")] = "Dirt 3", [uri("b")] = "Dirt 3" },
  })
  assert(ok, res)
  local got = {}
  for _, s in ipairs(res.totals.samples.assigned) do got[s.uri] = s.slug end
  eq(got[uri("a")], "dirt-3"); eq(got[uri("b")], "dirt-3-2")
end)

t("a real run assigns, suffixes a taken slug, and pushes only the slug", function()
  local ok, res, S = run({
    input = { dryRun = false },
    games = { [uri("a")] = "Dirt 3", [uri("b")] = "Fallout 2", [uri("c")] = "Fallout 2" },
    slugs = { { "fallout-2", uri("x") } },
    docs = { [uri("a")] = { type = "game" }, [uri("b")] = { type = "game" }, [uri("c")] = { type = "game" } },
  })
  assert(ok, res)
  eq(S.by_slug["dirt-3"], uri("a")); eq(S.by_slug["fallout-2"], uri("x"))
  eq(S.by_slug["fallout-2-2"], uri("b")); eq(S.by_slug["fallout-2-3"], uri("c"))
  eq(res.totals.counts.assigned, 3); eq(res.totals.counts.pushed, 3)
  for _, p in ipairs(S.puts) do
    local n = 0
    for _ in pairs(p) do n = n + 1 end
    eq(n, 2, "a push carries only id and slug:")
  end
  eq(S.docs[uri("b")].slug, "fallout-2-2")
end)

t("missing and gutted search documents are not written, only counted", function()
  local ok, res, S = run({
    input = { dryRun = false },
    games = { [uri("a")] = "Dirt 3", [uri("b")] = "Prey 2" },
    docs = { [uri("b")] = { gutted = true } },
  })
  assert(ok, res)
  eq(#S.puts, 0); eq(res.totals.counts.notInSearch, 2); eq(res.totals.counts.assigned, 2)
  eq(#res.totals.samples.notInSearch, 2)
end)

t("a document that already has the slug is left alone", function()
  local ok, res, S = run({
    input = { dryRun = false, uris = { uri("a") } },
    games = { [uri("a")] = "Dirt 3" },
    slugs = { { "dirt-3", uri("a") } },
    docs = { [uri("a")] = { type = "game", slug = "dirt-3" } },
  })
  assert(ok, res)
  eq(res.totals.counts.hadSlug, 1); eq(res.totals.counts.searchCurrent, 1); eq(#S.puts, 0); eq(S.inserts, 0)
end)

t("listed games that already have a slug get it copied to a stale document", function()
  local ok, res, S = run({
    input = { dryRun = false, uris = { uri("a") } },
    games = { [uri("a")] = "Combat Mission" },
    slugs = { { "combat-mission-x", uri("a") } },
    docs = { [uri("a")] = { type = "game" } },
  })
  assert(ok, res)
  eq(S.inserts, 0, "an existing slug is never replaced:"); eq(#S.puts, 1); eq(S.puts[1].slug, "combat-mission-x")
end)

t("listed URIs that are not games are counted, not assigned", function()
  local ok, res, S = run({ input = { dryRun = false, uris = { uri("gone"), "at://did:web:x/other.collection/r" } } })
  assert(ok, res)
  eq(res.totals.counts.notAGame, 1); eq(res.totals.counts.invalid, 1); eq(S.inserts, 0); eq(S.fetches, 0)
end)

t("a game whose name gives no slug is counted as noName", function()
  local ok, res, S = run({ input = { dryRun = false }, games = { [uri("a")] = "!!!" } })
  assert(ok, res)
  eq(res.totals.counts.noName, 1); eq(S.inserts, 0)
end)

t("a full chunk chains the next job from the last URI", function()
  local games = {}
  for i = 1, 205 do games[uri(string.format("g%03d", i))] = "Game " .. i end
  local ok, res, S = run({ input = { dryRun = true }, games = games })
  assert(ok, res)
  eq(res.totals.processed, 200); eq(#S.chained, 1); eq(S.chained[1].type, "slugs.backfill")
  eq(S.chained[1].input.after, uri("g200")); eq(S.chained[1].input.dryRun, true)
  eq(S.chained[1].input.totals.processed, 200)
end)

t("maxGames caps the chain", function()
  local games = {}
  for i = 1, 30 do games[uri(string.format("g%03d", i))] = "Game " .. i end
  local ok, res, S = run({ input = { dryRun = true, maxGames = 10 }, games = games })
  assert(ok, res)
  eq(res.totals.processed, 10); eq(#S.chained, 0)
end)

t("a short chunk ends the chain", function()
  local ok, res, S = run({ input = { dryRun = true }, games = { [uri("a")] = "Dirt 3" } })
  assert(ok, res)
  eq(#S.chained, 0); eq(res.next, nil)
end)

t("missing search config fails before anything is written", function()
  local ok, err, S = run({ input = { dryRun = false }, games = { [uri("a")] = "Dirt 3" }, env = {} })
  assert(not ok); assert(tostring(err):find("MEILISEARCH_URL", 1, true)); eq(S.inserts, 0)
end)

t("a failed search fetch fails the job", function()
  local ok, err = run({ input = { dryRun = true }, games = { [uri("a")] = "Dirt 3" }, docs = {}, fetch_status = 500 })
  assert(not ok); assert(tostring(err):find("fetching search documents failed", 1, true))
end)

-- Procedure

local function call(caller, body, queue)
  local created
  env = { ADMIN_DIDS = "did:plc:admin" }
  caller_did = caller
  input = body or {}
  jobs = { create = function(ty, inp) created = { type = ty, input = inp }; return "job-1" end }
  db = { raw = function(sql)
    assert(sql:find("job_type = 'slugs.backfill'", 1, true))
    return queue or {}
  end }
  handle = nil
  dofile(PROC)
  local ok, res = pcall(handle)
  return ok, res, created
end

t("only admins can queue a backfill", function()
  local ok, err = call("did:plc:someone", {})
  assert(not ok); assert(tostring(err):find("unauthorized", 1, true))
end)

t("a backfill is a dry run unless dryRun is false", function()
  local ok, res, created = call("did:plc:admin", {})
  assert(ok, res); eq(res.dryRun, true); eq(created.input.dryRun, true)
  ok, res, created = call("did:plc:admin", { dryRun = false })
  assert(ok, res); eq(res.dryRun, false); eq(created.input.dryRun, false)
end)

t("the procedure rejects URIs that are not games", function()
  local ok, err = call("did:plc:admin", { uris = { "at://did:web:x/games.gamesgamesgamesgames.collection/r" } })
  assert(not ok); assert(tostring(err):find("not a game URI", 1, true))
end)

t("a running backfill is reported instead of starting another", function()
  local ok, res, created = call("did:plc:admin", { dryRun = false }, { { id = "job-old", status = "running" } })
  assert(ok, res); eq(res.alreadyQueued, true); eq(res.jobId, "job-old"); eq(created, nil)
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
