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

local function is_auto_accept_account(did)
  for d in (env.AUTO_ACCEPT_DIDS or ""):gmatch("[^,]+") do
    if d:match("^%s*(.-)%s*$") == did then
      return true
    end
  end
  return false
end

function handle()
  -- Admins can sweep everything. An auto-accept account (the IGDB sync) can
  -- queue a sweep of its own contributions only: that applies nothing the
  -- per-contribution jobs would not have applied anyway, so it needs no
  -- admin credential.
  local own_only = false
  if not ADMIN_DIDS[caller_did] then
    if not is_auto_accept_account(caller_did) then
      error("unauthorized: only admins and auto-accept accounts can queue auto-accept sweeps")
    end
    own_only = true
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
    author = own_only and caller_did or nil,
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
