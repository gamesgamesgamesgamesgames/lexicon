-- Queues a contribution.auto-accept sweep. Admin only.

local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

function handle()
  if not ADMIN_DIDS[caller_did] then
    error("unauthorized: only admins can queue auto-accept sweeps")
  end

  local limit = input.limit or 500
  if type(limit) ~= "number" or limit < 1 or limit > 5000 then
    error("limit must be between 1 and 5000")
  end

  if input.writes and input.writes ~= "" and input.writes ~= "full" and input.writes ~= "minimal" then
    error("writes must be 'full' or 'minimal'")
  end

  local job_input = {
    sweep = true,
    limit = limit,
    dryRun = input.dryRun == true,
  }
  if input.after and input.after ~= "" then
    job_input.after = input.after
  end
  if input.writes and input.writes ~= "" then
    job_input.writes = input.writes
  end

  return { jobId = jobs.create("contribution.auto-accept", job_input) }
end
