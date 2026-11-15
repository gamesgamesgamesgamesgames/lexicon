-- Standalone tests for src/jobs/catalogue.reindex.lua against a stub of the
-- HappyView globals it uses.
-- Run: lua tests/reindex/job_test.lua src/jobs/catalogue.reindex.lua
local JOB = arg[1]
local P = "did:web:pentaract"
local G = "games.gamesgamesgamesgames.game"

local pass, fail = 0, 0
local function t(name, fn) local ok, err = pcall(fn); if ok then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function copy(x) if type(x) ~= "table" then return x end local o = {} for k, v in pairs(x) do o[k] = copy(v) end return o end
local function uri(r) return "at://" .. P .. "/" .. G .. "/" .. r end

-- S.pds: what the catalogue PDS holds. S.index: HappyView's row (cid only).
local function run(opts)
  local S = { pds = opts.pds or {}, index = opts.index or {}, puts = {}, warns = {}, chained = {}, waits = 0, reads = 0 }
  env = { PENTARACT_DID = P }
  json = { encode = function() return "<json>" end }
  log = function() end
  jobs = { create = function(ty, inp) table.insert(S.chained, { type = ty, input = inp }); return "job-" .. #S.chained end }
  local stop_after = opts.stop_after
  job = {
    input = opts.input,
    should_stop = function() return stop_after ~= nil and S.reads >= stop_after end,
    progress = function(p) S.progress = p end,
    warn = function(m) table.insert(S.warns, m) end,
    wait = function(s) S.waits = S.waits + 1; S.last_wait = s end,
  }
  local repo = { did = P, status = opts.status or "active" }
  function repo:call(nsid, o)
    assert(nsid == "com.atproto.repo.getRecord", "unexpected call " .. tostring(nsid))
    S.reads = S.reads + 1
    local u = "at://" .. o.params.repo .. "/" .. o.params.collection .. "/" .. o.params.rkey
    if opts.read_error and opts.read_error[u] then error(opts.read_error[u]) end
    local r = S.pds[u]
    if not r then error('com.atproto.repo.getRecord failed: 400 {"error":"RecordNotFound","message":"Could not locate record: ' .. u .. '"}') end
    return { uri = u, cid = r.cid, value = copy(r.value) }
  end
  function repo:put_record(o)
    local u = "at://" .. P .. "/" .. o.collection .. "/" .. o.rkey
    table.insert(S.puts, { uri = u, record = copy(o.record), swap = o.swap_cid })
    local cur = S.pds[u]
    if o.swap_cid and cur and cur.cid ~= o.swap_cid then error("put_record: InvalidSwap") end
    -- An identical record is a no-op that returns the current CID, unless the
    -- test says this one doesn't round-trip.
    local cid = (opts.recommit and opts.recommit[u]) or cur.cid
    S.pds[u] = { cid = cid, value = copy(o.record) }
    if not (opts.mirror_fails and opts.mirror_fails[u]) then S.index[u] = cid end
    return { uri = u, cid = cid }
  end
  linked_repos = { get = function(did)
    if opts.no_grant then return nil end
    return repo
  end }
  db = { raw = function(sql, b)
    assert(sql:find("SELECT cid FROM happyview_records WHERE uri = $1", 1, true), "unexpected sql " .. sql)
    return S.index[b[1]] and { { cid = S.index[b[1]] } } or {}
  end }
  handle = nil
  dofile(JOB)
  local ok, res = pcall(handle)
  return ok, res, S
end

local function game(cid, name) return { cid = cid, value = { ["$type"] = G, name = name or "Dirt 3" } } end

t("a stale row is put back unchanged with the PDS CID as the swap", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("cidNew") }, index = { [uri("a")] = "cidOld" } })
  assert(ok, res)
  eq(res.counts.reindexed, 1); eq(#S.puts, 1); eq(S.puts[1].swap, "cidNew"); eq(S.puts[1].record.name, "Dirt 3")
  eq(S.puts[1].record["$type"], G); eq(S.index[uri("a")], "cidNew")
end)

t("a row that already matches is not written", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("c1") }, index = { [uri("a")] = "c1" } })
  assert(ok, res); eq(res.counts.already_current, 1); eq(#S.puts, 0)
end)

t("a row missing from the index is put too", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("c1") } })
  assert(ok, res); eq(res.counts.reindexed, 1); eq(S.index[uri("a")], "c1")
end)

t("dry run reads and compares but never writes", function()
  local ok, res, S = run({ input = { uris = { uri("a"), uri("b") }, dryRun = true },
    pds = { [uri("a")] = game("n"), [uri("b")] = game("same") }, index = { [uri("a")] = "o", [uri("b")] = "same" } })
  assert(ok, res); eq(res.counts.would_reindex, 1); eq(res.counts.already_current, 1); eq(#S.puts, 0); eq(S.index[uri("a")], "o")
end)

t("running it twice writes nothing the second time", function()
  local pds, index = { [uri("a")] = game("n") }, { [uri("a")] = "o" }
  local ok, res = run({ input = { uris = { uri("a") } }, pds = pds, index = index })
  assert(ok, res); eq(res.counts.reindexed, 1)
  local ok2, res2, S2 = run({ input = { uris = { uri("a") } }, pds = pds, index = index })
  assert(ok2, res2); eq(res2.counts.already_current, 1); eq(#S2.puts, 0)
end)

t("a put that makes a real commit is counted and logged", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("n") }, index = { [uri("a")] = "o" }, recommit = { [uri("a")] = "n2" } })
  assert(ok, res); eq(res.counts.committed, 1); eq(res.counts.reindexed, 0)
  assert(S.warns[1]:find("made a real commit", 1, true) and S.warns[1]:find("n -> n2", 1, true), S.warns[1])
end)

t("an index the mirror did not update is reported, not counted as done", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("n") }, index = { [uri("a")] = "o" }, mirror_fails = { [uri("a")] = true } })
  assert(ok, res); eq(res.counts.index_not_updated, 1); eq(res.counts.reindexed, 0)
  assert(S.warns[1]:find("still at o", 1, true), S.warns[1])
end)

t("a game the PDS no longer has is counted and left alone", function()
  local ok, res, S = run({ input = { uris = { uri("gone") } }, index = { [uri("gone")] = "o" } })
  assert(ok, res); eq(res.counts.missing_on_pds, 1); eq(#S.puts, 0); eq(S.index[uri("gone")], "o")
end)

t("a PDS read failure fails that record only, and writes nothing for it", function()
  local ok, res, S = run({ input = { uris = { uri("a"), uri("b") } },
    pds = { [uri("a")] = game("n"), [uri("b")] = game("n") }, index = { [uri("a")] = "o", [uri("b")] = "o" },
    read_error = { [uri("a")] = "com.atproto.repo.getRecord failed: 502 Bad Gateway" } })
  assert(ok, res); eq(res.counts.failed, 1); eq(res.counts.reindexed, 1); eq(#S.puts, 1); eq(S.puts[1].uri, uri("b"))
end)

t("a dead grant fails the job before anything is read", function()
  local ok, err, S = run({ input = { uris = { uri("a") } }, status = "needs_reauth", pds = { [uri("a")] = game("n") } })
  eq(ok, false); assert(tostring(err):find("needs reauthorization", 1, true), err); eq(S.reads, 0)
end)

t("a URI outside the catalogue's games is skipped", function()
  local ok, res, S = run({ input = { uris = { "at://did:plc:else/" .. G .. "/x", "at://" .. P .. "/games.gamesgamesgamesgames.contribution/x" } } })
  assert(ok, res); eq(res.counts.invalid, 2); eq(S.reads, 0); eq(#S.puts, 0)
end)

t("works 200 at a time and chains the rest with the same settings", function()
  local uris, pds, index = {}, {}, {}
  for i = 1, 450 do local u = uri("g" .. i); uris[i] = u; pds[u] = game("c" .. i); index[u] = "c" .. i end
  local ok, res, S = run({ input = { uris = uris, dryRun = true, delay = 0.25 }, pds = pds, index = index })
  assert(ok, res); eq(res.processed, 200); eq(res.remaining, 250); eq(#S.chained, 1)
  eq(S.chained[1].type, "catalogue.reindex"); eq(#S.chained[1].input.uris, 250); eq(S.chained[1].input.uris[1], uri("g201"))
  eq(S.chained[1].input.dryRun, true); eq(S.chained[1].input.delay, 0.25); eq(res.next, "job-1")
end)

t("the last chunk chains nothing", function()
  local ok, res, S = run({ input = { uris = { uri("a") } }, pds = { [uri("a")] = game("c") }, index = { [uri("a")] = "c" } })
  assert(ok, res); eq(#S.chained, 0); eq(res.next, nil); eq(res.remaining, 0)
end)

t("paces between records, half a second by default", function()
  local ok, res, S = run({ input = { uris = { uri("a"), uri("b"), uri("c") } },
    pds = { [uri("a")] = game("c"), [uri("b")] = game("c"), [uri("c")] = game("c") }, index = { [uri("a")] = "c", [uri("b")] = "c", [uri("c")] = "c" } })
  assert(ok, res); eq(S.waits, 2); eq(S.last_wait, 0.5)
end)

t("a stop request ends the chunk without chaining, so nothing runs on unasked", function()
  local uris, pds, index = {}, {}, {}
  for i = 1, 300 do local u = uri("s" .. i); uris[i] = u; pds[u] = game("c"); index[u] = "c" end
  local ok, res, S = run({ input = { uris = uris }, pds = pds, index = index, stop_after = 3 })
  assert(ok, res); eq(res.stopped, true); eq(res.processed, 3); eq(res.remaining, 297); eq(#S.chained, 0)
end)

t("needs uris", function()
  local ok, err = run({ input = {} })
  eq(ok, false); assert(tostring(err):find("uris is required", 1, true), err)
end)

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
