-- Queues a wikidata.sync job, which copies what Wikidata knows about our
-- games (sitelinks, publisher, mod and fan game classes, English Wikipedia
-- article) into the wikidata_games table. Meant to run weekly. Admins only,
-- plus the scheduled maintenance account in MAINTENANCE_DIDS (unset by default).

local function did_set(raw)
  local dids = {}
  for did in (raw or ""):gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

function handle()
  if not did_set(env.ADMIN_DIDS)[caller_did] and not did_set(env.MAINTENANCE_DIDS)[caller_did] then
    error("unauthorized: only admins can queue a Wikidata sync")
  end

  -- One sync at a time: the steps share the staging table.
  local existing = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'wikidata.sync' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if existing and #existing > 0 then
    return { jobId = existing[1].id, alreadyQueued = true, status = existing[1].status }
  end

  local job_input = { dryRun = input.dryRun == true, force = input.force == true }
  return { jobId = jobs.create("wikidata.sync", job_input), alreadyQueued = false }
end
