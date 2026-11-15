-- Brings stale index rows for catalogue games back in line with the catalogue
-- PDS. Queued by reindexCatalogueGames.
--
-- For each URI the job reads the game from the catalogue PDS and compares its
-- CID with the index. A row that already matches is left alone. Otherwise the
-- job puts the record back unchanged, with swapRecord set to the PDS CID. The
-- PDS sees an identical record and makes no commit, and HappyView mirrors the
-- record and CID it returns into the index. The catalogue repo is not changed.
--
-- If the put does produce a new CID (the record did not round-trip to the same
-- bytes), the PDS made a real commit with the same content. That is harmless,
-- but it is logged and counted as `committed`.
--
-- This updates the index only. record.index hooks (game.lua's search push) do
-- not run, because no firehose event is produced.
--
-- Input:
--   uris      catalogue game URIs, at most 5000. Each job takes the first
--             CHUNK and chains a follow-up job with the rest.
--   dryRun    read and compare only; report what would be reindexed
--   delay     seconds to wait between records (default 0.5, about 2 a second)

local GAME_COLLECTION = "games.gamesgamesgamesgames.game"
local CHUNK = 200

local function did_of(uri)
  return uri and uri:match("^at://([^/]+)/")
end

local function collection_of(uri)
  return uri and uri:match("^at://[^/]+/([^/]+)/")
end

local function rkey_of(uri)
  return uri and uri:match("/([^/]+)$")
end

local function is_grant_error(err)
  local s = tostring(err)
  return s:find("needs reauthorization", 1, true)
    or s:find("has not been authorized", 1, true)
    or s:find("no linked repo grant", 1, true)
    or s:find("is gone", 1, true)
end

local function pentaract_repo()
  local did = env.PENTARACT_DID
  if not did or did == "" then
    error("PENTARACT_DID is not configured")
  end
  local repo = linked_repos.get(did)
  if not repo then
    error("no linked repo grant for " .. did .. " — an admin must link that account")
  end
  if repo.status ~= "active" then
    error("linked repo " .. did .. " needs reauthorization (status " .. tostring(repo.status) .. ")")
  end
  return repo
end

-- The game as the catalogue PDS holds it, or nil if the PDS has no such
-- record. Any other failure is an error: the job must not guess.
local function read_game(pentaract, uri)
  local ok, res = pcall(function()
    return pentaract:call("com.atproto.repo.getRecord", {
      params = { repo = did_of(uri), collection = collection_of(uri), rkey = rkey_of(uri) },
    })
  end)
  if not ok then
    local msg = tostring(res)
    if msg:find("RecordNotFound", 1, true) or msg:find("Could not locate record", 1, true) then
      return nil
    end
    error("could not read " .. uri .. " from the catalogue PDS: " .. msg)
  end
  if type(res) ~= "table" or type(res.value) ~= "table" or not res.cid then
    error("the catalogue PDS returned no record for " .. uri)
  end
  return { cid = res.cid, record = res.value }
end

local function index_cid(uri)
  local rows = db.raw("SELECT cid FROM happyview_records WHERE uri = $1 LIMIT 1", { uri })
  return rows and rows[1] and rows[1].cid or nil
end

local function reindex_one(pentaract, uri, dry_run)
  local game = read_game(pentaract, uri)
  if not game then
    return "missing_on_pds"
  end
  local before = index_cid(uri)
  if before == game.cid then
    return "already_current"
  end
  if dry_run then
    return "would_reindex"
  end

  local res = pentaract:put_record({
    collection = GAME_COLLECTION,
    rkey = rkey_of(uri),
    record = game.record,
    swap_cid = game.cid,
  })
  local after_put = res and res.cid
  if after_put ~= game.cid then
    job.warn("identical put of " .. uri .. " made a real commit: " .. tostring(game.cid) .. " -> " .. tostring(after_put))
    return "committed"
  end
  if index_cid(uri) ~= game.cid then
    job.warn("index for " .. uri .. " still at " .. tostring(index_cid(uri)) .. " after the put; the PDS has " .. game.cid)
    return "index_not_updated"
  end
  return "reindexed"
end

local function valid_uri(uri)
  return type(uri) == "string"
    and did_of(uri) == env.PENTARACT_DID
    and collection_of(uri) == GAME_COLLECTION
    and (rkey_of(uri) or "") ~= ""
end

function handle()
  local input = job.input or {}
  local uris = input.uris
  if type(uris) ~= "table" or #uris == 0 then
    error("uris is required")
  end
  local dry_run = input.dryRun == true
  local delay = tonumber(input.delay) or 0.5

  -- Checked first, so a dead grant fails the job before anything is written.
  local pentaract = pentaract_repo()

  local counts = {
    reindexed = 0, already_current = 0, would_reindex = 0, committed = 0,
    missing_on_pds = 0, index_not_updated = 0, invalid = 0, failed = 0,
  }
  local processed, stopped = 0, false
  local n = math.min(#uris, CHUNK)

  for i = 1, n do
    if job.should_stop() then
      stopped = true
      break
    end
    local uri = uris[i]
    processed = i
    if not valid_uri(uri) then
      counts.invalid = counts.invalid + 1
      job.warn("skipping " .. tostring(uri) .. ": not a catalogue game URI")
    else
      local ok, res = pcall(reindex_one, pentaract, uri, dry_run)
      if ok then
        counts[res] = counts[res] + 1
      elseif is_grant_error(res) then
        error(res)
      else
        counts.failed = counts.failed + 1
        job.warn("failed " .. uri .. ": " .. tostring(res))
      end
      if delay > 0 and i < n then
        job.wait(delay)
      end
    end
    if i % 50 == 0 then
      job.progress({ processed = processed, counts = counts })
    end
  end

  local next_job
  if not stopped and #uris > n then
    local rest = {}
    for i = n + 1, #uris do
      table.insert(rest, uris[i])
    end
    next_job = jobs.create("catalogue.reindex", { uris = rest, dryRun = dry_run, delay = delay })
  end

  local out = { processed = processed, remaining = #uris - processed, counts = counts, stopped = stopped, next = next_job }
  job.progress(out)
  log("catalogue.reindex: " .. json.encode(counts) .. " remaining=" .. tostring(#uris - processed) .. (next_job and (" next=" .. next_job) or ""))
  return out
end
