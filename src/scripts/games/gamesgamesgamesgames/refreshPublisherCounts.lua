-- Queues a search.publisher-counts job, which recounts the games each
-- publisher is credited on. The search builder's officialScore reads those
-- counts. Meant to run weekly, before a search.reindex. Admins only, plus any
-- account an admin lists in MAINTENANCE_DIDS (the scheduled maintenance
-- account; unset by default).

local function did_set(raw)
  local dids = {}
  for did in (raw or ""):gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

function handle()
  if not did_set(env.ADMIN_DIDS)[caller_did] and not did_set(env.MAINTENANCE_DIDS)[caller_did] then
    error("unauthorized: only admins can refresh publisher counts")
  end

  local existing = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'search.publisher-counts' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if existing and #existing > 0 then
    return { jobId = existing[1].id, alreadyQueued = true, status = existing[1].status }
  end

  return { jobId = jobs.create("search.publisher-counts", { dryRun = input.dryRun == true }), alreadyQueued = false }
end
