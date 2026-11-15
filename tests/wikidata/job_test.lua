-- Standalone tests for src/jobs/wikidata.sync.lua and the syncWikidata
-- procedure, against stubs of HappyView's globals. The SQL was checked against
-- Postgres 17 with a full sync from Wikidata; here the database is a stub that
-- records what was sent.
-- Run: lua tests/wikidata/job_test.lua
local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local E = "http://www.wikidata.org/entity/"

-- csv: the body Wikidata answers with. counts: what COUNT(*) queries return,
-- in order. apply_row: what the apply statement returns.
local function run(input, opts)
  opts = opts or {}
  local S = { sql = {}, binds = {}, chained = {}, warns = {}, posts = {} }
  local counts = opts.counts or {}
  json = { encode = function() return "{}" end }
  log = function() end
  http = { post = function(url, o)
    table.insert(S.posts, { url = url, opts = o })
    return { status = opts.status or 200, body = opts.csv or "", headers = opts.headers or {} }
  end }
  db = { raw = function(sql, b)
    table.insert(S.sql, sql); table.insert(S.binds, b)
    if sql:find("SELECT COUNT(*) AS n", 1, true) then return { { n = table.remove(counts, 1) or 0 } } end
    if sql:find("^WITH s AS") then return { opts.apply_row or { inserted = 0, updated = 0, deleted = 0 } } end
    return {}
  end }
  jobs = { create = function(ty, inp) table.insert(S.chained, { type = ty, input = inp }); return "job-" .. #S.chained end }
  job = { input = input, should_stop = function() return opts.stop end, progress = function() end, warn = function(m) table.insert(S.warns, m) end }
  handle = nil
  dofile("src/jobs/wikidata.sync.lua")
  local ok, res = pcall(handle)
  return ok, res, S
end

local function staged_rows(S)
  local rows = {}
  for i, sql in ipairs(S.sql) do
    if sql:find("INSERT INTO wikidata_games_staging", 1, true) then
      local b = S.binds[i]
      for j = 1, #b, 3 do table.insert(rows, { b[j], b[j + 1], b[j + 2] }) end
    end
  end
  return rows
end

t("the first step empties staging, stages sitelinks and chains the publisher step", function()
  local csv = "num,item,links\r\n1029," .. E .. "Q213911,42\r\n1030," .. E .. "Q732943,38\r\n"
  local ok, res, S = run({}, { csv = csv })
  assert(ok, res)
  eq(S.sql[1], "DELETE FROM wikidata_games_staging")
  local rows = staged_rows(S)
  eq(#rows, 2); eq(rows[1][1], "1029"); eq(rows[1][2], "Q213911"); eq(rows[1][3], 42)
  eq(res.totals.sitelinks, 2)
  eq(S.chained[1].input.step, "publisher"); eq(S.chained[1].input.dryRun, false)
  local p = S.posts[1]
  eq(p.opts.headers.accept, "text/csv"); assert(p.opts.body:find("^query=SELECT"), p.opts.body)
  assert(p.opts.headers["user-agent"]:find("CartridgeSearch", 1, true))
end)

t("two items claiming one IGDB ID: the better-linked wins, then the lower QID", function()
  local csv = "num,item,links\n7," .. E .. "Q500,3\n7," .. E .. "Q20,9\n8," .. E .. "Q100,4\n8," .. E .. "Q99,4\n"
  local ok, res, S = run({}, { csv = csv })
  assert(ok, res)
  local rows = staged_rows(S)
  eq(#rows, 2); eq(rows[1][2], "Q20"); eq(rows[2][2], "Q99")
end)

local function many(n, extra)
  local lines = { "num,item,links" }
  for i = 1, n do table.insert(lines, i .. "," .. E .. "Q" .. i .. ",3") end
  for _, l in ipairs(extra or {}) do table.insert(lines, l) end
  return table.concat(lines, "\n") .. "\n"
end

t("a few rows without a numeric IGDB ID are skipped and reported", function()
  local ok, res, S = run({}, { csv = many(200, { "abc," .. E .. "Q9999,3" }) })
  assert(ok, res); eq(#staged_rows(S), 200); eq(res.totals.sitelinksSkipped, 1); eq(#S.warns, 1)
end)

t("a step that skips more than 1% of its rows fails before staging", function()
  local ok, err, S = run({}, { csv = many(50, { "abc," .. E .. "Q1,3", "x," .. E .. "Q2,3" }) })
  eq(ok, false); assert(tostring(err):find("refusing to stage a suspect answer", 1, true), err)
  eq(#staged_rows(S), 0); eq(#S.chained, 0)
end)

t("a step well under the last sync's count fails as truncated", function()
  -- counts: the step's current-column count comes first
  local ok, err, S = run({ step = "publisher" }, { counts = { 42214 }, csv = "num,item\n1," .. E .. "Q1\n" })
  eq(ok, false); assert(tostring(err):find("refusing to stage a truncated answer", 1, true), err)
  eq(#staged_rows(S), 0); eq(#S.chained, 0)
end)

t("the truncation guard covers the small veto column too", function()
  local ok, err = run({ step = "veto" }, { counts = { 225 }, csv = "num,item,veto\n1," .. E .. "Q1," .. E .. "Q865493\n" })
  eq(ok, false); assert(tostring(err):find("truncated", 1, true), err)
end)

t("force stages a short answer anyway", function()
  local ok, res = run({ step = "publisher", force = true }, { counts = { 42214 }, csv = "num,item\n1," .. E .. "Q1\n" })
  assert(ok, res)
end)

t("a 429 fails the step cleanly and reports Retry-After", function()
  local ok, err, S = run({ step = "enwiki" }, { status = 429, headers = { ["retry-after"] = "120" }, csv = "" })
  eq(ok, false); assert(tostring(err):find("rate-limited", 1, true) and tostring(err):find("retry after 120", 1, true), err)
  eq(#S.chained, 0)
end)

t("the enwiki step keeps the article title, quoted CSV fields included", function()
  local csv = 'num,item,en\n5982,' .. E .. 'Q167330,"https://en.wikipedia.org/wiki/Pirates_of_the_Caribbean_(video_game),_x"\n'
  local ok, res, S = run({ step = "enwiki" }, { csv = csv })
  assert(ok, res)
  local rows = staged_rows(S)
  eq(rows[1][3], "Pirates_of_the_Caribbean_(video_game),_x")
  eq(S.sql[1]:find("DELETE", 1, true), nil, "only the first step empties staging")
  eq(S.chained[1].input.step, "apply")
end)

t("the veto step stores the class", function()
  local ok, res, S = run({ step = "veto" }, { csv = "num,item,veto\n48211," .. E .. "Q5054142," .. E .. "Q123012190\n" })
  assert(ok, res); eq(staged_rows(S)[1][3], "Q123012190")
end)

t("a non-200 answer fails the step and chains nothing", function()
  local ok, err, S = run({ step = "publisher" }, { status = 503, csv = "busy" })
  eq(ok, false); assert(tostring(err):find("Wikidata answered 503", 1, true), err); eq(#S.chained, 0)
end)

t("an answer without the CSV header fails the step", function()
  local ok, err = run({ step = "publisher" }, { csv = "<html>error</html>" })
  eq(ok, false); assert(tostring(err):find("no CSV header", 1, true), err)
end)

t("apply swaps the staged rows in with one statement and empties staging", function()
  local ok, res, S = run({ step = "apply" }, { counts = { 52763, 52700 }, apply_row = { inserted = 63, updated = 40, deleted = 0 } })
  assert(ok, res)
  eq(res.totals.inserted, 63); eq(res.totals.updated, 40); eq(res.done, true); eq(#S.chained, 0)
  local swap = S.sql[3]
  assert(swap:find("IS DISTINCT FROM", 1, true), "writes only changed rows")
  eq(S.sql[4], "DELETE FROM wikidata_games_staging")
end)

t("apply refuses when far fewer rows were staged than the table holds", function()
  local ok, err, S = run({ step = "apply" }, { counts = { 1000, 52763 } })
  eq(ok, false); assert(tostring(err):find("refusing to apply", 1, true), err)
  for _, sql in ipairs(S.sql) do eq(sql:find("^WITH s AS"), nil) end
end)

t("force applies anyway", function()
  local ok, res = run({ step = "apply", force = true }, { counts = { 1000, 52763 } })
  assert(ok, res)
end)

t("a dry-run apply only counts", function()
  local ok, res, S = run({ step = "apply", dryRun = true }, { counts = { 52763, 52700, 63, 40, 0 } })
  assert(ok, res)
  eq(res.totals.wouldInsert, 63); eq(res.totals.wouldUpdate, 40); eq(res.totals.wouldDelete, 0)
  for _, sql in ipairs(S.sql) do eq(sql:find("^WITH s AS"), nil); eq(sql:find("DELETE", 1, true), nil) end
end)

t("dryRun and the totals carry through the chain", function()
  local ok, res, S = run({ step = "publisher", dryRun = true, totals = { sitelinks = 5 } }, { csv = "num,item\n1," .. E .. "Q1\n" })
  assert(ok, res)
  eq(S.chained[1].input.dryRun, true); eq(S.chained[1].input.totals.sitelinks, 5); eq(S.chained[1].input.totals.publisher, 1)
end)

t("a stop request ends the chain", function()
  local ok, res, S = run({ step = "veto" }, { stop = true })
  assert(ok, res); eq(res.stopped, true); eq(#S.chained, 0); eq(#S.posts, 0)
end)

-- syncWikidata ---------------------------------------------------------------

local function call(caller, body, active)
  local created
  env = { ADMIN_DIDS = "did:plc:admin", REINDEX_DIDS = "did:plc:bot" }
  caller_did, input = caller, body
  jobs = { create = function(ty, inp) created = { type = ty, input = inp }; return "job-1" end }
  db = { raw = function(sql)
    assert(sql:find("job_type = 'wikidata.sync'", 1, true), sql)
    return active or {}
  end }
  handle = nil
  dofile("src/scripts/games/gamesgamesgamesgames/syncWikidata.lua")
  local ok, res = pcall(handle)
  return ok, res, created
end

t("an admin queues a sync", function()
  local ok, res, created = call("did:plc:admin", { dryRun = true })
  assert(ok, res); eq(created.type, "wikidata.sync"); eq(created.input.dryRun, true); eq(created.input.force, false)
end)

t("a REINDEX_DIDS account may queue one; anyone else may not", function()
  assert((call("did:plc:bot", {})))
  local ok, err = call("did:plc:human", {})
  eq(ok, false); assert(tostring(err):find("unauthorized", 1, true), err)
end)

t("a running sync is reported instead of starting another", function()
  local ok, res, created = call("did:plc:admin", {}, { { id = "job-0", status = "pending" } })
  assert(ok, res); eq(res.alreadyQueued, true); eq(created, nil)
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
