-- Copies what Wikidata knows about our games into the wikidata_games table,
-- keyed by IGDB game ID. Queued by syncWikidata; meant to run weekly. The
-- search document builder reads the table for its official and popularity
-- signals. Wikidata's data is CC0.
--
-- Tables: sql/wikidata_games.sql (run it before the first sync).
--
-- Wikidata links an item to IGDB with P5794, the IGDB slug, and gives the
-- numeric game ID as that statement's P9043 qualifier. That number is what
-- our records carry in externalIds.igdb, so it is the key.
--
-- The sync runs as a chain of jobs, one step each, so no job holds more than
-- one Wikidata result in memory:
--
--   sitelinks  items with at least one sitelink, and how many
--   publisher  items with a publisher (P123)
--   veto       items whose instance-of (P31) is a mod or fan game class
--   enwiki     the English Wikipedia article of each item
--   apply      replace wikidata_games with the staged rows in one statement
--
-- The first step empties wikidata_games_staging. The query steps fill it, and
-- apply swaps it in, writing only rows that changed. Apply refuses to run if
-- the staged set is less than half the size of the current table, which is
-- what a truncated or failed Wikidata answer would look like.
--
-- Each query step also refuses an answer that skips more than 1% of its rows,
-- or that is under 80% of the last applied sync's count for its column.
--
-- Wikidata's slowest query here (enwiki) took about 13 s. HappyView's HTTP
-- client gives up after 30 s with no data, so there is roughly 2x headroom;
-- a timeout fails the step cleanly, like any other error.
--
-- Input:
--   dryRun   fill the staging table and report what apply would change,
--            without touching wikidata_games
--   step     set by the chain
--   totals   running counts, carried through the chain
--   force    apply even when the staged set looks too small

local ENDPOINT = "https://query.wikidata.org/sparql"
-- Wikimedia's policy asks for a contact in the User-Agent; a URL is accepted.
local USER_AGENT = "CartridgeSearch/1.0 (https://cartridge.dev; wikidata.sync job)"
local BATCH = 100
local MIN_STAGED_SHARE = 0.5
-- A step fails rather than stage a suspect answer: when it skips more than
-- MAX_SKIPPED_SHARE of its rows, or returns less than MIN_STEP_SHARE of what
-- the last applied sync had for the same column (once that is at least
-- MIN_GUARDED_ROWS, so the small veto column is guarded too).
local MAX_SKIPPED_SHARE = 0.01
local MIN_STEP_SHARE = 0.8
local MIN_GUARDED_ROWS = 50

-- What the last applied sync holds for each step's column.
local CURRENT_COUNT = {
  sitelinks = "SELECT COUNT(*) AS n FROM wikidata_games WHERE sitelinks > 0",
  publisher = "SELECT COUNT(*) AS n FROM wikidata_games WHERE has_publisher = 1",
  veto = "SELECT COUNT(*) AS n FROM wikidata_games WHERE veto_class IS NOT NULL",
  enwiki = "SELECT COUNT(*) AS n FROM wikidata_games WHERE enwiki_title IS NOT NULL",
}

local STEPS = { "sitelinks", "publisher", "veto", "enwiki", "apply" }

-- Instance-of classes that mark a game as a mod or a fan game.
local VETO_CLASSES = {
  "Q865493",   -- video game mod
  "Q1395577",  -- fan game
  "Q61456428", -- total conversion mod
  "Q123012190", -- unlicensed video game
}

local LINK = "?item p:P5794 ?st . ?st pq:P9043 ?num . "

local function veto_values()
  local parts = {}
  for _, q in ipairs(VETO_CLASSES) do table.insert(parts, "wd:" .. q) end
  return table.concat(parts, " ")
end

local QUERIES = {
  sitelinks = "SELECT ?num ?item ?links WHERE { " .. LINK .. "?item wikibase:sitelinks ?links . FILTER(?links > 0) }",
  publisher = "SELECT DISTINCT ?num ?item WHERE { " .. LINK .. "?item wdt:P123 ?p }",
  veto = "SELECT ?num ?item ?veto WHERE { VALUES ?veto { " .. veto_values() .. " } ?item wdt:P31 ?veto . " .. LINK .. "}",
  enwiki = "SELECT ?num ?item ?en WHERE { " .. LINK .. "?en schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> }",
}

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Splits one CSV line, honouring double-quoted fields.
local function csv_fields(line)
  local fields, i, n = {}, 1, #line
  while i <= n + 1 do
    if line:sub(i, i) == '"' then
      local buf, j = {}, i + 1
      while j <= n do
        local c = line:sub(j, j)
        if c == '"' then
          if line:sub(j + 1, j + 1) == '"' then table.insert(buf, '"'); j = j + 2
          else j = j + 1; break end
        else
          table.insert(buf, c); j = j + 1
        end
      end
      table.insert(fields, table.concat(buf))
      i = j + 1
    else
      local k = line:find(",", i, true) or (n + 1)
      table.insert(fields, line:sub(i, k - 1))
      i = k + 1
    end
  end
  return fields
end

-- Runs one query and returns its rows as tables keyed by column name.
-- Anything but a 200 with the expected header is an error, so a failed or
-- truncated answer never reaches the staging table as if it were complete.
local function sparql(step)
  local resp = http.post(ENDPOINT, {
    headers = {
      ["accept"] = "text/csv",
      ["content-type"] = "application/x-www-form-urlencoded",
      ["user-agent"] = USER_AGENT,
    },
    body = "query=" .. urlencode(QUERIES[step]),
  })
  local status = resp and resp.status or 0
  if status == 429 then
    -- Rate limited. Fail the step cleanly; the chain stops and nothing is
    -- applied. Retry-After says when Wikidata will take queries again.
    local after = resp.headers and (resp.headers["retry-after"] or resp.headers["Retry-After"])
    error("Wikidata rate-limited the " .. step .. " query (429); retry after " .. tostring(after or "an unspecified wait") .. "; nothing was applied")
  end
  if status ~= 200 then
    error("Wikidata answered " .. tostring(status) .. " to the " .. step .. " query: " .. string.sub(resp and resp.body or "", 1, 300))
  end
  local rows, header = {}, nil
  for line in (resp.body or ""):gmatch("[^\r\n]+") do
    if not header then
      header = csv_fields(line)
    else
      local f, row = csv_fields(line), {}
      for i, name in ipairs(header) do row[name] = f[i] end
      table.insert(rows, row)
    end
  end
  if not header or header[1] ~= "num" then
    error("Wikidata's answer to the " .. step .. " query has no CSV header")
  end
  return rows
end

local function qid_of(u)
  return u and u:match("/entity/(Q%d+)$")
end

local function title_of(u)
  return u and u:match("^https://en%.wikipedia%.org/wiki/(.+)$")
end

-- QIDs in numeric order, so "Q99" sorts before "Q100".
local function qid_less(a, b)
  local x, y = tonumber(a:sub(2)), tonumber(b:sub(2))
  if x ~= y then return x < y end
  return a < b
end

-- When two Wikidata items claim the same IGDB ID, keep the better-linked one,
-- then the lower QID. Wikidata returns rows in no fixed order, so without a
-- rule like this every sync would flip some rows back and forth.
local function prefer(step, qid, value, cur)
  if step == "sitelinks" and value ~= cur.value then return value > cur.value end
  if qid ~= cur.qid then return qid_less(qid, cur.qid) end
  if type(value) == "string" then return value < cur.value end
  return false
end

-- Turns query rows into one entry per IGDB ID: { igdb_id, qid, value }.
local function entries(step, rows)
  local by_id, order, skipped = {}, {}, 0
  for _, r in ipairs(rows) do
    local id, qid = r.num, qid_of(r.item)
    local value
    if step == "sitelinks" then value = tonumber(r.links)
    elseif step == "publisher" then value = 1
    elseif step == "veto" then value = qid_of(r.veto)
    elseif step == "enwiki" then value = title_of(r.en) end
    if not (id and id:match("^%d+$") and qid and value) then
      skipped = skipped + 1
    else
      local cur = by_id[id]
      if not cur then
        cur = { igdb_id = id, qid = qid, value = value }
        by_id[id] = cur
        table.insert(order, cur)
      elseif prefer(step, qid, value, cur) then
        cur.qid, cur.value = qid, value
      end
    end
  end
  return order, skipped
end

local UPSERT = {
  sitelinks = { col = "sitelinks", set = "qid = EXCLUDED.qid, sitelinks = EXCLUDED.sitelinks" },
  publisher = { col = "has_publisher", set = "has_publisher = 1, qid = COALESCE(wikidata_games_staging.qid, EXCLUDED.qid)" },
  veto = { col = "veto_class", set = "veto_class = EXCLUDED.veto_class, qid = COALESCE(wikidata_games_staging.qid, EXCLUDED.qid)" },
  enwiki = { col = "enwiki_title", set = "enwiki_title = EXCLUDED.enwiki_title, qid = COALESCE(wikidata_games_staging.qid, EXCLUDED.qid)" },
}

local function stage(step, list)
  local u = UPSERT[step]
  for start = 1, #list, BATCH do
    local values, binds = {}, {}
    for i = start, math.min(#list, start + BATCH - 1) do
      local e, b = list[i], #binds
      table.insert(values, "($" .. (b + 1) .. ", $" .. (b + 2) .. ", $" .. (b + 3) .. ")")
      table.insert(binds, e.igdb_id); table.insert(binds, e.qid); table.insert(binds, e.value)
    end
    db.raw(
      "INSERT INTO wikidata_games_staging (igdb_id, qid, " .. u.col .. ") VALUES " .. table.concat(values, ", ") ..
      " ON CONFLICT (igdb_id) DO UPDATE SET " .. u.set,
      binds
    )
  end
end

local COLS = "qid, sitelinks, has_publisher, veto_class, enwiki_title"

local function count(sql)
  local rows = db.raw(sql, {})
  return tonumber(rows and rows[1] and rows[1].n) or 0
end

local function apply(dry_run, force, totals)
  local staged = count("SELECT COUNT(*) AS n FROM wikidata_games_staging WHERE qid IS NOT NULL")
  local current = count("SELECT COUNT(*) AS n FROM wikidata_games")
  totals.staged, totals.current = staged, current
  if not force and current > 0 and staged < current * MIN_STAGED_SHARE then
    error("only " .. staged .. " rows staged against " .. current .. " in wikidata_games; refusing to apply (pass force to override)")
  end

  local changed = "(w.qid, w.sitelinks, w.has_publisher, w.veto_class, w.enwiki_title) IS DISTINCT FROM (s.qid, s.sitelinks, s.has_publisher, s.veto_class, s.enwiki_title)"
  if dry_run then
    totals.wouldInsert = count("SELECT COUNT(*) AS n FROM wikidata_games_staging s WHERE s.qid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM wikidata_games w WHERE w.igdb_id = s.igdb_id)")
    totals.wouldUpdate = count("SELECT COUNT(*) AS n FROM wikidata_games_staging s JOIN wikidata_games w ON w.igdb_id = s.igdb_id WHERE s.qid IS NOT NULL AND " .. changed)
    totals.wouldDelete = count("SELECT COUNT(*) AS n FROM wikidata_games w WHERE NOT EXISTS (SELECT 1 FROM wikidata_games_staging s WHERE s.igdb_id = w.igdb_id AND s.qid IS NOT NULL)")
    return
  end

  -- One statement, so readers see either last week's table or this week's.
  local rows = db.raw(
    "WITH s AS (SELECT igdb_id, " .. COLS .. " FROM wikidata_games_staging WHERE qid IS NOT NULL), " ..
    "del AS (DELETE FROM wikidata_games w WHERE NOT EXISTS (SELECT 1 FROM s WHERE s.igdb_id = w.igdb_id) RETURNING 1), " ..
    "up AS (INSERT INTO wikidata_games (igdb_id, " .. COLS .. ", synced_at) SELECT igdb_id, " .. COLS .. ", NOW() FROM s " ..
    "ON CONFLICT (igdb_id) DO UPDATE SET qid = EXCLUDED.qid, sitelinks = EXCLUDED.sitelinks, has_publisher = EXCLUDED.has_publisher, " ..
    "veto_class = EXCLUDED.veto_class, enwiki_title = EXCLUDED.enwiki_title, synced_at = EXCLUDED.synced_at " ..
    "WHERE (wikidata_games.qid, wikidata_games.sitelinks, wikidata_games.has_publisher, wikidata_games.veto_class, wikidata_games.enwiki_title) " ..
    "IS DISTINCT FROM (EXCLUDED.qid, EXCLUDED.sitelinks, EXCLUDED.has_publisher, EXCLUDED.veto_class, EXCLUDED.enwiki_title) " ..
    "RETURNING (xmax = 0) AS inserted) " ..
    "SELECT (SELECT COUNT(*) FROM del) AS deleted, (SELECT COUNT(*) FROM up WHERE inserted) AS inserted, (SELECT COUNT(*) FROM up WHERE NOT inserted) AS updated",
    {}
  )
  local r = rows and rows[1] or {}
  totals.inserted, totals.updated, totals.deleted = tonumber(r.inserted) or 0, tonumber(r.updated) or 0, tonumber(r.deleted) or 0
  db.raw("DELETE FROM wikidata_games_staging", {})
end

function handle()
  local input = job.input or {}
  local dry_run = input.dryRun == true
  local step = input.step or STEPS[1]
  local totals = input.totals or {}

  local index
  for i, s in ipairs(STEPS) do if s == step then index = i end end
  if not index then error("unknown step " .. tostring(step)) end

  if job.should_stop() then
    return { step = step, stopped = true, totals = totals }
  end

  if step == "apply" then
    apply(dry_run, input.force == true, totals)
  else
    if index == 1 then
      db.raw("DELETE FROM wikidata_games_staging", {})
    end
    local rows = sparql(step)
    local list, skipped = entries(step, rows)
    if #rows > 0 and skipped > #rows * MAX_SKIPPED_SHARE then
      error(step .. ": skipped " .. skipped .. " of " .. #rows .. " rows, more than " .. (MAX_SKIPPED_SHARE * 100) .. "%; refusing to stage a suspect answer")
    end
    local previous = count(CURRENT_COUNT[step])
    if not input.force and previous >= MIN_GUARDED_ROWS and #list < previous * MIN_STEP_SHARE then
      error(step .. ": " .. #list .. " rows against " .. previous .. " in the last sync; refusing to stage a truncated answer (pass force to override)")
    end
    stage(step, list)
    totals[step] = #list
    if skipped > 0 then
      totals[step .. "Skipped"] = skipped
      job.warn(step .. ": skipped " .. skipped .. " rows without a numeric IGDB ID or a usable value")
    end
  end

  local next_job
  if index < #STEPS then
    next_job = jobs.create("wikidata.sync", { dryRun = dry_run, step = STEPS[index + 1], totals = totals, force = input.force })
  end
  local out = { step = step, dryRun = dry_run, totals = totals, next = next_job, done = next_job == nil }
  job.progress(out)
  log("wikidata.sync " .. step .. ": " .. json.encode(totals))
  return out
end
