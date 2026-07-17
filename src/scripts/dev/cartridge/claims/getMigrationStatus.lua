function handle()
  local job_id = params.jobId
  if not job_id or job_id == "" then
    error("jobId is required")
  end

  local rows = db.raw(
    "SELECT id, status, input, progress, result, error FROM happyview_jobs WHERE id = $1 AND created_by = $2 LIMIT 1",
    { job_id, caller_did }
  )

  if not rows or #rows == 0 then
    error("job not found")
  end

  local row = rows[1]
  local response = {
    jobId = row.id,
    status = row.status,
  }

  local job_input = json.decode(row.input or "{}")
  local input_total = job_input.approved_games and #job_input.approved_games or 0

  if row.progress then
    local progress = json.decode(row.progress)
    response.progress = {
      total = progress.total or input_total,
      processed = progress.processed or 0,
      orgProfileDone = progress.org_profile_done,
    }
  else
    response.progress = {
      total = input_total,
      processed = 0,
    }
  end

  if row.status == "completed" and row.result then
    local result = json.decode(row.result)
    if result.results then
      response.results = toarray(result.results)
    end
  end

  if row.status == "failed" and row.error then
    response.error = row.error
  end

  return response
end
