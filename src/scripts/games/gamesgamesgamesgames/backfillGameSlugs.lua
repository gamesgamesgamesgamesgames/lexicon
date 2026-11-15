-- Queues a slugs.backfill job, which gives games with no slug one and puts it
-- on their search document. Admins only. A dry run unless dryRun is false.
-- Existing slugs are never changed.

local MAX_URIS = 5000
local GAME_NSID = "games.gamesgamesgamesgames.game"

local function did_set(raw)
  local dids = {}
  for did in (raw or ""):gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

function handle()
  if not did_set(env.ADMIN_DIDS)[caller_did] then
    error("unauthorized: only admins can queue a slug backfill")
  end

  local uris = input.uris
  if uris ~= nil then
    if type(uris) ~= "table" or #uris == 0 then
      error("uris, when given, must be a non-empty list")
    end
    if #uris > MAX_URIS then
      error("at most " .. MAX_URIS .. " uris per call")
    end
    for i, uri in ipairs(uris) do
      if type(uri) ~= "string" or uri:match("^at://[^/]+/([^/]+)/[%w%._:~%-]+$") ~= GAME_NSID then
        error("uris[" .. i .. "] is not a game URI: " .. tostring(uri))
      end
    end
  end

  local max_games = input.maxGames
  if max_games ~= nil and (type(max_games) ~= "number" or max_games % 1 ~= 0 or max_games < 1) then
    error("maxGames must be a whole number of at least 1")
  end

  -- One backfill chain at a time: a second call while one is pending or
  -- running reports that job instead of starting a parallel chain.
  local existing = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'slugs.backfill' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if existing and #existing > 0 then
    return { jobId = existing[1].id, alreadyQueued = true, status = existing[1].status, dryRun = input.dryRun ~= false }
  end

  local dry_run = input.dryRun ~= false
  local job_input = { dryRun = dry_run, uris = uris, maxGames = max_games }
  return { jobId = jobs.create("slugs.backfill", job_input), alreadyQueued = false, dryRun = dry_run }
end
