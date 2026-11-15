-- Queues a search.reindex job, which finds games whose Meilisearch document
-- is missing, gutted or stale and writes the document game.lua would write.
-- Admins only, plus any account an admin lists in REINDEX_DIDS (unset by
-- default). Run it with dryRun first: that reads and compares only.

local MAX_URIS = 5000
local GAME_PATTERN = "^at://[^/]+/games%.gamesgamesgamesgames%.game/[%w%._:~%-]+$"

local function did_set(raw)
  local dids = {}
  for did in (raw or ""):gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

function handle()
  if not did_set(env.ADMIN_DIDS)[caller_did] and not did_set(env.REINDEX_DIDS)[caller_did] then
    error("unauthorized: only admins can queue a search reindex")
  end

  local uris = input.uris
  if uris ~= nil then
    if type(uris) ~= "table" or #uris == 0 then
      error("uris must be a non-empty list when given")
    end
    if #uris > MAX_URIS then
      error("at most " .. MAX_URIS .. " uris per call")
    end
    for i, uri in ipairs(uris) do
      if type(uri) ~= "string" or not uri:match(GAME_PATTERN) then
        error("uris[" .. i .. "] is not a game URI: " .. tostring(uri))
      end
    end
  end

  local after = input.after
  if after ~= nil then
    if uris ~= nil then
      error("after resumes a full scan; it cannot be combined with uris")
    end
    if type(after) ~= "string" or not after:match(GAME_PATTERN) then
      error("after must be a game URI, such as the after of a stopped run")
    end
  end

  local max_games = input.maxGames
  if max_games ~= nil and (type(max_games) ~= "number" or max_games % 1 ~= 0 or max_games < 1) then
    error("maxGames must be a whole number of at least 1")
  end

  -- search.reindex builds documents from the index rows, so a catalogue
  -- reindex that is still correcting those rows has to finish first.
  local catalogue = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'catalogue.reindex' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if catalogue and #catalogue > 0 then
    error("a catalogue reindex (" .. tostring(catalogue[1].id) .. ") is " .. tostring(catalogue[1].status) .. "; wait for it to finish, since search.reindex reads the rows it corrects")
  end

  -- One search reindex chain at a time: a second call while one is pending or
  -- running reports that job instead of starting a parallel chain.
  local existing = db.raw(
    "SELECT id, status FROM happyview_jobs WHERE job_type = 'search.reindex' AND status IN ('pending', 'running') ORDER BY created_at LIMIT 1",
    {}
  )
  if existing and #existing > 0 then
    return { jobId = existing[1].id, alreadyQueued = true, status = existing[1].status }
  end

  local job_input = { dryRun = input.dryRun == true, uris = uris, after = after, maxGames = max_games }
  return { jobId = jobs.create("search.reindex", job_input), alreadyQueued = false }
end
