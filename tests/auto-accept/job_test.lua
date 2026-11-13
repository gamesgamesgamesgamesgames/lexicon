-- Standalone tests for src/jobs/contribution.auto-accept.lua against a stub of
-- the HappyView globals it uses. Run: lua tests/auto-accept/job_test.lua src/jobs/contribution.auto-accept.lua
-- Kept apart from tests/lua so it does not depend on (or collide with) a shared harness.
local JOB = arg[1]
local P = "did:web:pentaract"
local SYS = "did:plc:scraper"

local function copy(t) if type(t) ~= "table" then return t end local o = {} for k,v in pairs(t) do o[k]=copy(v) end return o end

local function setup(opts)
  opts = opts or {}
  local S = { records = {}, slugs = {}, ext = {}, writes = {}, logs = {}, deferrals = {}, clock_h = 0, cid_n = 0, grant_status = opts.grant_status or "active", missing_blobs = opts.missing_blobs or {} }
  local function put(uri, rec) S.cid_n = S.cid_n + 1; S.records[uri] = { cid = "cid" .. S.cid_n, record = copy(rec), collection = uri:match("^at://[^/]+/([^/]+)/"), did = uri:match("^at://([^/]+)/") } end
  S.put = put
  env = { PENTARACT_DID = P, AUTO_ACCEPT_DIDS = SYS .. ", did:plc:other", AUTO_ACCEPT_WRITES = opts.writes_env,
    AUTO_ACCEPT_MEDIA_MAX_ATTEMPTS = opts.max_attempts, AUTO_ACCEPT_MEDIA_MAX_DAYS = opts.max_days, AUTO_ACCEPT_MEDIA_RETRY_HOURS = opts.retry_hours }
  json = { decode = function(s) return copy(s) end, encode = function(t) return "<json>" end }
  toarray = function(t) return t end
  now = function() return "2026-11-13T00:00:00Z" end
  log = function(m) table.insert(S.logs, m) end
  job = { input = opts.input or {}, should_stop = function() return false end, progress = function(p) S.progress = p end, warn = function(m) table.insert(S.logs, "WARN " .. m) end }
  local function check_blobs(rec)
    for _, m in ipairs(rec.media or {}) do
      if S.missing_blobs[m.blob] then error("create_record: BlobNotFound: Could not find blob: " .. m.blob) end
    end
  end
  local repo = { did = P, status = opts.repo_status or S.grant_status }
  function repo:create_record(o)
    if opts.fail_collection == o.collection then error("create_record: PDS 500") end
    check_blobs(o.record)
    local rkey = o.rkey or ("tid" .. (#S.writes + 1))
    local uri = "at://" .. P .. "/" .. o.collection .. "/" .. rkey
    if S.records[uri] then error("create_record: record already exists") end
    put(uri, o.record); table.insert(S.writes, { op = "create", uri = uri, record = copy(o.record) })
    if o.collection == "games.gamesgamesgamesgames.game" and o.record.externalIds and o.record.externalIds.igdb then S.ext[tostring(o.record.externalIds.igdb)] = uri end
    return { uri = uri, cid = S.records[uri].cid }
  end
  function repo:put_record(o)
    local uri = "at://" .. P .. "/" .. o.collection .. "/" .. o.rkey
    if opts.fail_put_uri == uri then error("put_record: InvalidSwap: Record was at bafy-other") end
    if o.swap_cid and S.records[uri] and S.records[uri].cid ~= o.swap_cid then error("put_record: InvalidSwap") end
    check_blobs(o.record)
    put(uri, o.record); table.insert(S.writes, { op = "put", uri = uri, record = copy(o.record) })
    return { uri = uri, cid = S.records[uri].cid }
  end
  linked_repos = { get = function(did)
    if opts.no_grant then return nil end
    if S.grant_status == "needs_reauth" then error("linked repo " .. did .. " needs reauthorization: boom") end
    return repo end }
  db = { raw = function(sql, b)
    if sql:find("FROM contribution_deferrals WHERE uri") and sql:find("^SELECT") then
      local d = S.deferrals[b[1]]
      if not d then return {} end
      return {{ attempts = tostring(d.attempts), age_days = tostring((S.clock_h - d.first) / 24), since_hours = tostring(S.clock_h - d.last) }}
    end
    if sql:find("INSERT INTO contribution_deferrals") then
      local d = S.deferrals[b[1]]
      if d then d.attempts = d.attempts + 1; d.last = S.clock_h else S.deferrals[b[1]] = { attempts = 1, first = S.clock_h, last = S.clock_h } end
      return {}
    end
    if sql:find("DELETE FROM contribution_deferrals") then S.deferrals[b[1]] = nil return {} end
    if sql:find("DELETE FROM slugs") then if S.slugs[b[1]] == b[2] then S.slugs[b[1]] = nil end return {} end
    if sql:find("FROM slugs WHERE uri") then for s,u in pairs(S.slugs) do if u == b[1] then return {{slug=s}} end end return {} end
    if sql:find("FROM slugs WHERE slug") then return S.slugs[b[1]] and {{uri=S.slugs[b[1]]}} or {} end
    if sql:find("INSERT INTO slugs") then if not S.slugs[b[1]] then S.slugs[b[1]] = b[2] end return {} end
    if sql:find("FROM external_ids") then return S.ext[b[1]] and {{uri=S.ext[b[1]]}} or {} end
    if sql:find("SELECT uri, cid, record FROM happyview_records WHERE uri") then local r = S.records[b[1]]; return r and {{uri=b[1], cid=r.cid, record=r.record}} or {} end
    if sql:find("record::jsonb%->'contribution'%->>'uri' = %$3 LIMIT 1") then
      local by_did = sql:find("AND did = %$2") ~= nil
      for u, r in pairs(S.records) do if r.collection == b[1] and (not by_did or r.did == b[2]) and r.record.contribution and r.record.contribution.uri == b[3] then return {{uri=u}} end end return {} end
    local function key(u, r) return (r.record.createdAt or "") .. "\0" .. u end
    local function dids_of(list) local d = {} for x in list:gmatch("[^,]+") do d[x] = true end return d end
    if sql:find("record::jsonb%->>'subject' = %$2") then
      assert(sql:find("AND did = %$1"), "newer_contribution must filter by author")
      local dids = dids_of(b[1]); local best
      for u, r in pairs(S.records) do
        if r.collection == "games.gamesgamesgamesgames.contribution" and dids[r.did] and r.record.subject == b[2] and key(u, r) > (b[3] .. "\0" .. b[4]) then
          if not best or key(u, r) > best[1] then best = { key(u, r), u } end
        end
      end
      return best and {{uri=best[2]}} or {}
    end
    if sql:find("'igdb' = %$2") or sql:find("%->>'igdb' = %$2") then
      assert(sql:find("AND did = %$1"), "newer_contribution must filter by author")
      local dids = dids_of(b[1]); local best
      for u, r in pairs(S.records) do
        local ig = r.record.changes and r.record.changes.externalIds and r.record.changes.externalIds.igdb
        if r.collection == "games.gamesgamesgamesgames.contribution" and dids[r.did] and r.record.contributionType == "newGame" and ig and tostring(ig) == b[2] and key(u, r) > (b[3] .. "\0" .. b[4]) then
          if not best or key(u, r) > best[1] then best = { key(u, r), u } end
        end
      end
      return best and {{uri=best[2]}} or {}
    end
    if sql:find("ORDER BY COALESCE") then
      local dids = dids_of(b[1])
      local out = {}
      for u, r in pairs(S.records) do
        if r.collection == "games.gamesgamesgamesgames.contribution" and dids[r.did] and key(u, r) > (b[2] .. "\0" .. b[3]) then
          local reviewed = false
          for _, r2 in pairs(S.records) do if r2.collection == "games.gamesgamesgamesgames.contributionReview" and r2.did == b[4] and r2.record.contribution.uri == u then reviewed = true end end
          if not reviewed then table.insert(out, {uri=u, created=r.record.createdAt or "", k=key(u, r)}) end
        end
      end
      table.sort(out, function(a,c) return a.k < c.k end)
      while #out > b[5] do table.remove(out) end
      return out
    end
    error("unmocked sql: " .. sql)
  end }
  return S
end

local function run(S)
  handle = nil
  dofile(JOB)
  local ok, res = pcall(handle)
  return ok, res
end

local GAME = "at://" .. P .. "/games.gamesgamesgamesgames.game/g1"
local function contrib(S, rkey, author, rec)
  local uri = "at://" .. author .. "/games.gamesgamesgamesgames.contribution/" .. rkey
  S.put(uri, rec); return uri, S.records[uri].cid
end
local function count(S, coll) local n = 0 for _, w in ipairs(S.writes) do if w.uri:find(coll, 1, true) then n = n + 1 end end return n end

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local function base(opts)
  local S = setup(opts)
  S.put(GAME, { name = "Portal", applicationType = "game", genres = {"puzzle"}, releases = {{ platformURI = "p", releaseDates = {{ releasedAt = "TBD" }} }}, media = {{ blob = "b1" }} })
  return S
end

t("correction applies only real changes, writes verification + review", function()
  local S = base()
  local u, c = contrib(S, "a1", SYS, { contributionType = "correction", subject = GAME, changes = { genres = {"puzzle"}, summary = "new", releases = {{ releaseDates = {{ releasedAt = "TBD" }}, platformURI = "p" }} } })
  job.input = { uri = u, cid = c }
  S.writes = {}
  local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(#res.fields, 1); eq(res.fields[1], "summary")
  eq(S.records[GAME].record.summary, "new"); eq(S.records[GAME].record.name, "Portal")
  eq(count(S, "gamesgamesgamesgames.game/"), 1); eq(count(S, "contributionVerification"), 1); eq(count(S, "contributionReview"), 1)
end)

t("rerun after review exists is skipped (idempotent)", function()
  local S = base()
  local u, c = contrib(S, "a1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "new" } })
  job.input = { uri = u, cid = c }; assert(run(S))
  local n = #S.writes
  local ok, res = run(S); assert(ok, res)
  eq(res.status, "skipped"); eq(res.reason, "already reviewed"); eq(#S.writes, n)
end)

t("noop writes only a review", function()
  local S = base()
  local u, c = contrib(S, "a2", SYS, { contributionType = "correction", subject = GAME, changes = { name = "Portal" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "noop"); eq(count(S, "gamesgamesgamesgames.game/"), 0); eq(count(S, "contributionVerification"), 0); eq(count(S, "contributionReview"), 1)
end)

t("review failure after game write converges on rerun without a second game write", function()
  local S = base({ fail_collection = "games.gamesgamesgamesgames.contributionReview" })
  local u, c = contrib(S, "a3", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok = run(S); eq(ok, false)
  eq(S.records[GAME].record.summary, "x")
  -- rerun against the same data with a healthy PDS
  local S2 = setup(); S2.records = S.records; S2.cid_n = 1000
  job.input = { uri = u, cid = c }
  local ok2, res = run(S2); assert(ok2, res)
  eq(res.status, "noop"); eq(count(S2, "gamesgamesgamesgames.game/"), 0); eq(count(S2, "contributionReview"), 1)
end)

t("human contributions are skipped", function()
  local S = base()
  local u, c = contrib(S, "h1", "did:plc:human", { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "skipped"); eq(#S.writes, 0)
end)

t("dead grant fails before any write", function()
  local S = base({ grant_status = "needs_reauth" })
  local u, c = contrib(S, "a4", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, err = run(S)
  eq(ok, false); assert(tostring(err):find("needs reauthorization"), err); eq(#S.writes, 0)
end)

t("a grant that is not active fails before any write", function()
  local S = base({ repo_status = "revoked" })
  local u, c = contrib(S, "a4b", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, err = run(S)
  eq(ok, false); assert(tostring(err):find("needs reauthorization"), err); eq(#S.writes, 0)
end)

t("missing grant fails clearly", function()
  local S = base({ no_grant = true })
  local u, c = contrib(S, "a5", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, err = run(S)
  eq(ok, false); assert(tostring(err):find("no linked repo grant"), err)
end)

t("minimal mode writes the game and the review, no verification", function()
  local S = base({ writes_env = "minimal" })
  local u, c = contrib(S, "a6", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(#S.writes, 2); eq(count(S, "contributionVerification"), 0); eq(count(S, "contributionReview"), 1)
end)

t("empty AUTO_ACCEPT_WRITES falls back to full", function()
  local S = base({ writes_env = "" })
  local u, c = contrib(S, "a6e", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(count(S, "contributionVerification"), 1)
end)

t("input writes overrides env", function()
  local S = base({ writes_env = "full" })
  local u, c = contrib(S, "a6b", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c, writes = "minimal" }; local ok, res = run(S); assert(ok, res)
  eq(count(S, "contributionVerification"), 0)
end)

t("invalid writes value errors", function()
  local S = base()
  job.input = { uri = "x", writes = "everything" }; local ok, err = run(S)
  eq(ok, false); assert(tostring(err):find("writes must be"), err)
end)

t("dry run writes nothing", function()
  local S = base()
  local u, c = contrib(S, "a7", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c, dryRun = true }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(#S.writes, 0); eq(S.records[GAME].record.summary, nil)
end)

t("missing media blob applies nothing and leaves it pending", function()
  local S = base({ missing_blobs = { b2 = true } })
  local u, c = contrib(S, "a8", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x", media = {{ blob = "b1" }, { blob = "b2" }} } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "deferred"); eq(S.records[GAME].record.summary, nil); eq(#S.writes, 0)
  -- too soon to retry
  local okw, resw = run(S); assert(okw, resw); eq(resw.status, "waiting")
  -- once the blob exists and the retry is due, it applies in full
  S.missing_blobs.b2 = nil; S.clock_h = 7
  local ok2, res2 = run(S); assert(ok2, res2)
  eq(res2.status, "applied"); eq(#S.records[GAME].record.media, 2); eq(S.records[GAME].record.summary, "x")
  eq(count(S, "contributionReview"), 1); eq(S.deferrals[u], nil, "deferral cleared")
end)

t("after 3 deferred attempts it applies without media and says so", function()
  local S = base({ missing_blobs = { b2 = true } })
  local u, c = contrib(S, "cap1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x", media = {{ blob = "b2" }} } })
  job.input = { uri = u, cid = c }
  for i = 1, 3 do
    S.clock_h = (i - 1) * 7
    local ok, res = run(S); assert(ok, res); eq(res.status, "deferred", "attempt " .. i)
  end
  S.clock_h = 21
  local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(res.mediaDropped, true)
  eq(S.records[GAME].record.summary, "x"); eq(S.records[GAME].record.media[1].blob, "b1", "media kept")
  local review; for _, w in ipairs(S.writes) do if w.uri:find("contributionReview") then review = w.record end end
  eq(review.status, "approved"); assert(review.reason:find("media unavailable in catalogue repo"), review.reason)
  eq(count(S, "contributionVerification"), 1)
end)

t("7 days after the first deferral it applies without media even with attempts left", function()
  local S = base({ missing_blobs = { b2 = true }, max_attempts = "10", retry_hours = "200" })
  local u, c = contrib(S, "cap2", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x", media = {{ blob = "b2" }} } })
  job.input = { uri = u, cid = c }
  local ok, res = run(S); assert(ok, res); eq(res.status, "deferred")
  S.clock_h = 24 * 3; ok, res = run(S); assert(ok, res); eq(res.status, "waiting")
  S.clock_h = 24 * 7; ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(res.mediaDropped, true)
end)

t("a media-only change given up on writes no game and no verification", function()
  local S = base({ missing_blobs = { b2 = true }, max_attempts = "1" })
  local u, c = contrib(S, "cap3", SYS, { contributionType = "correction", subject = GAME, changes = { media = {{ blob = "b2" }} } })
  job.input = { uri = u, cid = c }
  local ok, res = run(S); assert(ok, res); eq(res.status, "deferred")
  S.clock_h = 7; ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(count(S, "gamesgamesgamesgames.game/"), 0); eq(count(S, "contributionVerification"), 0); eq(count(S, "contributionReview"), 1)
end)

t("a newGame given up on is created without media", function()
  local S = base({ missing_blobs = { bx = true }, max_attempts = "1" })
  local u, c = contrib(S, "cap4", SYS, { contributionType = "newGame", changes = { name = "Late Art", applicationType = "game", media = {{ blob = "bx" }}, externalIds = { igdb = "77" } } })
  job.input = { uri = u, cid = c }
  local ok, res = run(S); assert(ok, res); eq(res.status, "deferred")
  S.clock_h = 7; ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); local g = S.records["at://" .. P .. "/games.gamesgamesgamesgames.game/igdb-77"]
  assert(g, "created"); eq(g.record.media, nil)
end)

t("cid mismatch is skipped", function()
  local S = base()
  local u = contrib(S, "a9", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = "stale" }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "skipped")
end)

t("subject owned by someone else is skipped", function()
  local S = base()
  local other = "at://did:plc:studio/games.gamesgamesgamesgames.game/s1"
  S.put(other, { name = "Owned" })
  local u, c = contrib(S, "a10", SYS, { contributionType = "correction", subject = other, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "skipped"); eq(#S.writes, 0)
end)

t("newGame creates at igdb rkey with slug first and publishedAt", function()
  local S = base()
  local u, c = contrib(S, "n1", SYS, { contributionType = "newGame", changes = { name = "New Game!", applicationType = "game", externalIds = { igdb = "777" } } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(res.created, true)
  local uri = "at://" .. P .. "/games.gamesgamesgamesgames.game/igdb-777"
  assert(S.records[uri], "game created"); eq(S.records[uri].record.publishedAt, "2026-11-13T00:00:00Z")
  eq(S.slugs["new-game"], uri)
end)

t("newGame rerun after partial failure updates instead of duplicating", function()
  local S = base({ fail_collection = "games.gamesgamesgamesgames.contributionVerification" })
  local u, c = contrib(S, "n2", SYS, { contributionType = "newGame", changes = { name = "Dup", applicationType = "game", externalIds = { igdb = "888" } } })
  job.input = { uri = u, cid = c }; local ok = run(S); eq(ok, false)
  local keep = S.records; local slugs = S.slugs
  local S2 = setup(); S2.records = keep; S2.slugs = slugs; S2.cid_n = 500
  job.input = { uri = u, cid = c }; local ok2, res = run(S2); assert(ok2, res)
  eq(res.status, "noop"); eq(count(S2, "gamesgamesgamesgames.game/"), 0)
  local n = 0; for s, _ in pairs(S2.slugs) do n = n + 1 end; eq(n, 1, "one slug")
end)

t("newGame for an igdb id already mapped becomes an update", function()
  local S = base()
  S.ext["123"] = GAME
  local u, c = contrib(S, "n3", SYS, { contributionType = "newGame", changes = { name = "Portal", applicationType = "game", summary = "s", externalIds = { igdb = "123" } } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied"); eq(res.created, nil); eq(S.records[GAME].record.summary, "s")
end)

t("sweep processes pending system contributions, skips reviewed, reports cursor", function()
  local S = base()
  local G2 = "at://" .. P .. "/games.gamesgamesgamesgames.game/g2"
  S.put(G2, { name = "Other" })
  contrib(S, "s1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "1" } })
  contrib(S, "s2", SYS, { contributionType = "correction", subject = G2, changes = { name = "Other" } })
  contrib(S, "s3", "did:plc:human", { contributionType = "correction", subject = GAME, changes = { summary = "h" } })
  job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
  eq(res.counts.applied, 1); eq(res.counts.noop, 1); eq(res.done, true)
  job.input = { sweep = true, limit = 10 }; local ok2, res2 = run(S); assert(ok2, res2)
  eq(res2.counts.applied, 0); eq(res2.counts.noop, 0)
end)

t("sweep isolates per-item failures (swap conflict) but stops on grant errors", function()
  local S = base()
  contrib(S, "t1", SYS, { contributionType = "correction", subject = "at://" .. P .. "/games.gamesgamesgamesgames.game/missing", changes = { summary = "1" } })
  contrib(S, "t2", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "2" } })
  job.input = { sweep = true, limit = 1 }; local ok, res = run(S); assert(ok, res)
  eq(res.counts.skipped, 1); eq(res.done, false)
  job.input = { sweep = true, limit = 10, after = res.after }; local ok2, res2 = run(S); assert(ok2, res2)
  eq(res2.counts.applied, 1)
end)

t("sweep counts a failed put and keeps going", function()
  local G2 = "at://" .. P .. "/games.gamesgamesgamesgames.game/g2"
  local S = base({ fail_put_uri = G2 })
  S.put(G2, { name = "Other" })
  contrib(S, "u1", SYS, { contributionType = "correction", subject = G2, changes = { summary = "1" } })
  contrib(S, "u2", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "2" } })
  job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
  eq(res.counts.failed, 1); eq(res.counts.applied, 1); eq(#res.failures, 1)
end)

t("sweep stops on a grant error mid-run", function()
  local S = base()
  contrib(S, "v1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "1" } })
  local repo = linked_repos.get(P)
  job.input = { sweep = true, limit = 10 }
  handle = nil; dofile(JOB)
  repo.put_record = function() error("put_record: linked repo did:web:pentaract needs reauthorization: x") end
  linked_repos.get = function() return repo end
  local ok, err = pcall(handle)
  eq(ok, false); assert(tostring(err):find("stopped at"), err)
end)

-- ===== igdb-review R1-R9 (R5/R6 put createdAt on the record, where real contributions carry it) =====
t("R1 swap_cid is passed on put", function()
  local S = base()
  local u, c = contrib(S, "r1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  local seen
  local repo = linked_repos.get(P)
  local orig = repo.put_record
  repo.put_record = function(self, o) seen = o.swap_cid; return orig(self, o) end
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(seen, "cid1", "swap_cid")
end)

t("R2 dry run newGame writes nothing and assigns no slug", function()
  local S = base()
  local u, c = contrib(S, "r2", SYS, { contributionType = "newGame", changes = { name = "Fresh", applicationType = "game", externalIds = { igdb = "9" } } })
  job.input = { uri = u, cid = c, dryRun = true }; local ok, res = run(S); assert(ok, res)
  eq(#S.writes, 0); eq(S.slugs["fresh"], nil, "slug")
end)

t("R3 subject in Pentaract repo but not a game is skipped", function()
  local S = base()
  local plat = "at://" .. P .. "/games.gamesgamesgamesgames.platform/p1"
  S.put(plat, { name = "PS5" })
  local u, c = contrib(S, "r3", SYS, { contributionType = "correction", subject = plat, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "skipped"); eq(#S.writes, 0)
end)

t("R4 BlobNotFound with no media change fails instead of applying", function()
  local S = base({ missing_blobs = { b1 = true } })
  local u, c = contrib(S, "r4", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }; local ok = run(S); eq(ok, false)
  eq(#S.writes, 0)
end)

t("R5 minimal + later sweep never reverts a newer value", function()
  local S = base({ writes_env = "minimal" })
  local old = contrib(S, "zzz-old", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "June value" } })
  job.input = { uri = old }; assert(run(S))
  local new = contrib(S, "aaa-new", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "November value" } })
  job.input = { uri = new }; assert(run(S))
  eq(S.records[GAME].record.summary, "November value")
  job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
  eq(S.records[GAME].record.summary, "November value", "after sweep")
end)

t("R6 sweep over two pending contributions keeps the newest value", function()
  local S = base()
  contrib(S, "zzz-old", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "June value" } })
  contrib(S, "aaa-new", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "November value" } })
  job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
  eq(S.records[GAME].record.summary, "November value", "after sweep")
  eq(res.counts.superseded, 1); eq(res.counts.applied, 1)
end)

t("R7 a review from another repo does not block auto-accept", function()
  local S = base()
  local u, c = contrib(S, "r7", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  S.put("at://did:plc:troll/games.gamesgamesgamesgames.contributionReview/1", { contribution = { uri = u }, status = "denied" })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied", "status")
end)

t("R7b a foreign review does not hide a contribution from the sweep", function()
  local S = base()
  local u = contrib(S, "r7b", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  S.put("at://did:plc:troll/games.gamesgamesgamesgames.contributionReview/1", { contribution = { uri = u }, status = "denied" })
  job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
  eq(res.counts.applied, 1)
end)

t("R8 externalIds merge keeps ids IGDB does not know", function()
  local S = base()
  S.records[GAME].record.externalIds = { igdb = "1", twitch = "555" }
  local u, c = contrib(S, "r8", SYS, { contributionType = "correction", subject = GAME, changes = { externalIds = { igdb = "1", steam = "400" } } })
  job.input = { uri = u, cid = c }; assert(run(S))
  eq(S.records[GAME].record.externalIds.twitch, "555", "twitch kept")
  eq(S.records[GAME].record.externalIds.steam, "400", "steam added")
end)

t("R8b externalIds that add nothing new are a no-op", function()
  local S = base()
  S.records[GAME].record.externalIds = { igdb = "1", twitch = "555" }
  local u, c = contrib(S, "r8b", SYS, { contributionType = "correction", subject = GAME, changes = { externalIds = { igdb = "1" } } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "noop")
end)

t("R9 media-only change with missing blobs: no game put, no verification, no review", function()
  local S = base({ missing_blobs = { b2 = true } })
  local u, c = contrib(S, "r9", SYS, { contributionType = "correction", subject = GAME, changes = { media = {{ blob = "b1" }, { blob = "b2" }} } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "deferred")
  eq(count(S, "contributionVerification"), 0, "verification")
  eq(count(S, "gamesgamesgamesgames.game/"), 0, "identical game put")
  eq(count(S, "contributionReview"), 0, "review")
end)

-- ===== new behaviour =====
t("superseded newGame for the same igdb id is denied, newest creates", function()
  local S = base()
  local old = contrib(S, "ng-old", SYS, { contributionType = "newGame", createdAt = "2026-06-14T00:00:00Z", changes = { name = "Old Name", applicationType = "game", externalIds = { igdb = "42" } } })
  contrib(S, "ng-new", SYS, { contributionType = "newGame", createdAt = "2026-11-14T00:00:00Z", changes = { name = "New Name", applicationType = "game", externalIds = { igdb = "42" } } })
  job.input = { uri = old }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "superseded"); eq(S.records["at://" .. P .. "/games.gamesgamesgamesgames.game/igdb-42"], nil)
  local review; for _, w in ipairs(S.writes) do if w.uri:find("contributionReview") then review = w.record end end
  eq(review.status, "denied")
end)

t("superseded check ignores contributions from non-auto-accept accounts", function()
  local S = base()
  local u, c = contrib(S, "sa1", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "IGDB" } })
  contrib(S, "sa2", "did:plc:human", { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "human" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied")
end)

t("SYSTEM_DIDS alone does not enable auto-accept", function()
  local S = base()
  env.AUTO_ACCEPT_DIDS = nil
  env.SYSTEM_DIDS = SYS
  local u, c = contrib(S, "sd1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  job.input = { uri = u, cid = c }
  handle = nil; dofile(JOB)
  local ok, res = pcall(handle); assert(ok, res)
  eq(res.status, "skipped"); eq(#S.writes, 0)
end)

t("failed newGame create removes the slug it inserted", function()
  local S = base({ fail_collection = "games.gamesgamesgamesgames.game" })
  local u, c = contrib(S, "sl1", SYS, { contributionType = "newGame", changes = { name = "Slug Me", applicationType = "game", externalIds = { igdb = "55" } } })
  job.input = { uri = u, cid = c }; local ok = run(S); eq(ok, false)
  eq(S.slugs["slug-me"], nil)
end)

t("newGame with blobs missing is deferred, no game, no slug", function()
  local S = base({ missing_blobs = { bx = true } })
  local u, c = contrib(S, "nb1", SYS, { contributionType = "newGame", changes = { name = "Blobby", applicationType = "game", media = {{ blob = "bx" }}, externalIds = { igdb = "66" } } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "deferred"); eq(S.slugs["blobby"], nil); eq(#S.writes, 0)
end)

t("a concurrent job that reviewed first turns a failure into a skip", function()
  local S = base()
  local u, c = contrib(S, "cc1", SYS, { contributionType = "correction", subject = GAME, changes = { summary = "x" } })
  local repo = linked_repos.get(P)
  job.input = { uri = u, cid = c }
  handle = nil; dofile(JOB)
  repo.put_record = function()
    -- the other job lands its review, then our swap fails
    S.put("at://" .. P .. "/games.gamesgamesgamesgames.contributionReview/other", { contribution = { uri = u }, status = "approved" })
    error("put_record: InvalidSwap")
  end
  linked_repos.get = function() return repo end
  local ok, res = pcall(handle); assert(ok, res)
  eq(res.status, "skipped"); eq(res.reason, "reviewed by a concurrent job")
end)

t("sweep cursor resumes by createdAt then uri", function()
  local S = base()
  local G2 = "at://" .. P .. "/games.gamesgamesgamesgames.game/g2"
  S.put(G2, { name = "Other" })
  contrib(S, "b", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-01T00:00:00Z", changes = { summary = "1" } })
  contrib(S, "a", SYS, { contributionType = "correction", subject = G2, createdAt = "2026-07-01T00:00:00Z", changes = { summary = "2" } })
  job.input = { sweep = true, limit = 1 }; local ok, res = run(S); assert(ok, res)
  eq(S.records[GAME].record.summary, "1"); eq(S.records[G2].record.summary, nil)
  assert(res.after:find("^2026%-06%-01"), res.after)
  job.input = { sweep = true, limit = 5, after = res.after }; local ok2, res2 = run(S); assert(ok2, res2)
  eq(S.records[G2].record.summary, "2"); eq(res2.done, true)
end)

t("bad sweep cursor errors clearly", function()
  local S = base()
  job.input = { sweep = true, after = "at://not-a-cursor" }; local ok, err = run(S)
  eq(ok, false); assert(tostring(err):find("cursor"), err)
end)

t("a rerun after a failed review approves, even with a newer contribution waiting", function()
  local S = base({ fail_collection = "games.gamesgamesgamesgames.contributionReview" })
  local u, c = contrib(S, "rr1", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "A" } })
  job.input = { uri = u, cid = c }; local ok = run(S); eq(ok, false)
  eq(S.records[GAME].record.summary, "A")
  contrib(S, "rr2", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "B" } })
  local S2 = setup(); S2.records = S.records; S2.cid_n = 900
  job.input = { uri = u, cid = c }; local ok2, res = run(S2); assert(ok2, res)
  eq(res.status, "noop")
  local review; for _, w in ipairs(S2.writes) do if w.uri:find("contributionReview") then review = w.record end end
  eq(review.status, "approved")
end)

-- ===== igdb-review round 2 =====
t("Q1 deferred contribution re-applies its other fields over a later edit on every sweep", function()
  local S = base({ missing_blobs = { b9 = true } })
  local u, c = contrib(S, "d1", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "IGDB Nov", media = {{ blob = "b9" }} } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res); eq(res.status, "deferred")
  -- a moderator-approved human edit (or admin putGame) lands later
  local rec = S.records[GAME].record; rec.summary = "Human fix Dec"; S.put(GAME, rec)
  job.input = { sweep = true, limit = 10 }; local ok2, res2 = run(S); assert(ok2, res2)
  eq(S.records[GAME].record.summary, "Human fix Dec", "summary after sweep")
end)

t("Q2 supersede writes a Pentaract review on an owner-held game's contribution", function()
  local S = base()
  local owned = "at://did:plc:studio/games.gamesgamesgamesgames.game/s1"
  S.put(owned, { name = "Owned" })
  local u, c = contrib(S, "o1", SYS, { contributionType = "correction", subject = owned, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "x" } })
  contrib(S, "o2", SYS, { contributionType = "correction", subject = owned, createdAt = "2026-11-14T00:00:00Z", changes = { summary = "y" } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(#S.writes, 0, "writes for an owner-held game")
end)

t("Q3 a newer contribution from a different auto-accept account supersedes one it does not carry", function()
  local S = base()
  local u, c = contrib(S, "x1", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-06-14T00:00:00Z", changes = { summary = "IGDB summary" } })
  contrib(S, "x2", "did:plc:other", { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { websites = {{ url = "https://x" }} } })
  job.input = { uri = u, cid = c }; local ok, res = run(S); assert(ok, res)
  eq(res.status, "applied", "status")
end)

t("Q4 deferred-forever: every sweep re-attempts the put and nothing ever finishes it", function()
  local S = base({ missing_blobs = { b9 = true } })
  local u, c = contrib(S, "f1", SYS, { contributionType = "correction", subject = GAME, createdAt = "2026-11-14T00:00:00Z", changes = { media = {{ blob = "b9" }} } })
  local attempts = 0
  for i = 1, 3 do
    job.input = { sweep = true, limit = 10 }; local ok, res = run(S); assert(ok, res)
    attempts = attempts + (res.counts.deferred or 0)
  end
  eq(attempts, 1, "deferred count across 3 sweeps")
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
