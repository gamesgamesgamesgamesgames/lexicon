-- Queues a catalogue.reindex job for a list of catalogue game URIs. Admins
-- only, plus any account an admin lists in REINDEX_DIDS (unset by default).
-- The job only puts back what the catalogue PDS already holds, so it cannot
-- change a game; it corrects the index.

local MAX_URIS = 5000

local function did_set(raw)
  local dids = {}
  for did in (raw or ""):gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

function handle()
  if not did_set(env.ADMIN_DIDS)[caller_did] and not did_set(env.REINDEX_DIDS)[caller_did] then
    error("unauthorized: only admins can queue a catalogue reindex")
  end

  local uris = input.uris
  if type(uris) ~= "table" or #uris == 0 then
    error("uris is required")
  end
  if #uris > MAX_URIS then
    error("at most " .. MAX_URIS .. " uris per call")
  end
  local prefix = "at://" .. tostring(env.PENTARACT_DID) .. "/games.gamesgamesgamesgames.game/"
  for i, uri in ipairs(uris) do
    if type(uri) ~= "string" or uri:sub(1, #prefix) ~= prefix or not uri:sub(#prefix + 1):match("^[%w%._:~%-]+$") then
      error("uris[" .. i .. "] is not a catalogue game URI: " .. tostring(uri))
    end
  end

  local per_second = input.perSecond
  if per_second ~= nil and (type(per_second) ~= "number" or per_second % 1 ~= 0 or per_second < 1 or per_second > 5) then
    error("perSecond must be a whole number from 1 to 5")
  end

  -- One reindex chain at a time: a second call while one is pending or
  -- running reports that job instead of starting a parallel chain.
  local existing = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'catalogue.reindex' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if existing and #existing > 0 then
    return { jobId = existing[1].id, alreadyQueued = true, status = existing[1].status, count = 0 }
  end

  local job_input = { uris = uris, dryRun = input.dryRun == true }
  if per_second ~= nil then
    job_input.delay = 1 / per_second
  end
  return { jobId = jobs.create("catalogue.reindex", job_input), alreadyQueued = false, count = #uris }
end
