-- A stub of the HappyView globals that game.lua, collection.lua and the
-- search.reindex job use, with an in-memory Meilisearch behind `http`.
-- Load with dofile("tests/search-reindex/fake.lua").
local M = {}

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
function M.doc_id(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local left = #s - i + 1
    for k, shift in ipairs({ 18, 12, 6, 0 }) do
      if k <= 2 or (k == 3 and left >= 2) or (k == 4 and left >= 3) then
        local idx = (n >> shift) & 63
        out[#out + 1] = b64:sub(idx + 1, idx + 1)
      end
    end
  end
  return table.concat(out)
end

local function copy(x)
  if type(x) ~= "table" then return x end
  local o = {}
  for k, v in pairs(x) do o[k] = copy(v) end
  return o
end
M.copy = copy
F_copy = copy

-- opts:
--   records      { [uri] = { did = ..., record = {...} } } (games in the index)
--   meili        { [doc id] = doc } (what Meilisearch holds)
--   backlinks    { [game uri] = { collection uri, ... } }
--   slugs        { [uri] = slug }
--   fail_writes  number of document writes to answer 500 to
--   fail_reads   answer 500 to document fetches
--   pentaract_did  env.PENTARACT_DID (unset: the overlay reads no patches)
--   patches      { { uri, did, record = { subject, createdAt, changes } }, ... }
function M.install(opts)
  local S = {
    meili = opts.meili or {}, records = opts.records or {}, ext = {}, posts = 0, puts = 0, writes = {},
    warns = {}, chained = {}, waits = 0, fail_writes = opts.fail_writes or 0,
  }
  local blobs, n = {}, 0
  json = {
    encode = function(x) n = n + 1; local k = "<json#" .. n .. ">"; blobs[k] = copy(x); return k end,
    decode = function(s)
      if blobs[s] == nil then error("bad json " .. tostring(s)) end
      return copy(blobs[s])
    end,
  }
  S.encode = json.encode
  env = { MEILISEARCH_URL = "http://meili", MEILISEARCH_API_KEY = "k", ADMIN_DIDS = "did:plc:admin", PENTARACT_DID = opts.pentaract_did }
  toarray = function(x) return x end
  log = function() end

  local function sorted_uris()
    local list = {}
    for u in pairs(S.records) do list[#list + 1] = u end
    table.sort(list)
    return list
  end
  db = {
    raw = function(sql, b)
      if sql:find("FROM happyview_jobs", 1, true) then
        S.job_queries = (S.job_queries or 0) + 1
        if sql:find("'catalogue.reindex'", 1, true) then return opts.catalogue_jobs or {} end
        return opts.search_jobs or {}
      end
      -- Live overlay patches: opts.patches is a list of { uri, did, record }.
      if sql:find("games.gamesgamesgamesgames.contributionPatch", 1, true) then
        S.patch_queries = (S.patch_queries or 0) + 1
        local want = {}
        for i = 2, #b do want[b[i]] = true end
        local rows = {}
        for _, p in ipairs(opts.patches or {}) do
          if p.did == b[1] and want[p.record.subject] then
            rows[#rows + 1] = { uri = p.uri, record = json.encode(p.record) }
          end
        end
        return rows
      end
      if sql:find("FROM happyview_records", 1, true) then
        local rows = {}
        local function row(u)
          local r = S.records[u]
          return { uri = u, did = r.did, record = r.raw or json.encode(r.record) }
        end
        if sql:find("uri IN (", 1, true) then
          local want = {}
          for i = 2, #b do want[b[i]] = true end
          for _, u in ipairs(sorted_uris()) do if want[u] then rows[#rows + 1] = row(u) end end
        else
          for _, u in ipairs(sorted_uris()) do
            if u > b[2] and #rows < b[3] then rows[#rows + 1] = row(u) end
          end
        end
        return rows
      end
      if sql:find("FROM publisher_counts", 1, true) then
        if opts.publisher_counts_missing then error('db.raw query failed: relation "publisher_counts" does not exist') end
        if opts.db_down then error("db.raw query failed: connection refused") end
        for i = 2, #b do
          if ((opts.publisher_counts or {})[b[i]] or 0) >= b[1] then return { { ok = 1 } } end
        end
        return {}
      end
      if sql:find("FROM wikidata_games", 1, true) then
        if opts.wikidata_missing then error('db.raw query failed: relation "wikidata_games" does not exist') end
        local w = (opts.wikidata or {})[b[1]]
        return w and { w } or {}
      end
      if sql:find("FROM slugs", 1, true) then
        local s = opts.slugs and opts.slugs[b[1]]
        return s and { { slug = s } } or {}
      end
      if sql:find("INSERT INTO external_ids", 1, true) then
        S.ext[b[1] .. ":" .. tostring(b[2])] = b[3]
        return {}
      end
      error("unexpected sql " .. sql)
    end,
    -- Pages like HappyView's: at most `limit` (capped at 100) per call, with
    -- a cursor while more remain.
    backlinks = function(o)
      if o.collection == "games.gamesgamesgamesgames.org.credit" then
        return { records = F_copy((opts.credits or {})[o.uri] or {}) }
      end
      local list = (opts.backlinks or {})[o.uri] or {}
      local limit = math.min(o.limit or 20, 100)
      local start = tonumber(o.cursor or "0") or 0
      local recs = {}
      for i = start + 1, math.min(#list, start + limit) do recs[#recs + 1] = { uri = list[i] } end
      local cursor = (start + limit < #list) and tostring(start + limit) or nil
      return { records = recs, cursor = cursor }
    end,
  }

  local function write(docs, merge)
    if S.fail_writes > 0 then
      S.fail_writes = S.fail_writes - 1
      return { status = 500, body = "boom" }
    end
    for _, d in ipairs(docs) do
      S.writes[#S.writes + 1] = d.id
      if merge and S.meili[d.id] then
        for k, v in pairs(d) do S.meili[d.id][k] = copy(v) end
      else
        S.meili[d.id] = copy(d)
      end
    end
    return { status = 202, body = "{}" }
  end
  http = {
    post = function(url, o)
      local body = json.decode(o.body)
      if url:find("/fetch$") then
        if opts.fail_reads then return { status = 500, body = "down" } end
        local want = {}
        for u in body.filter:gmatch('"([^"]+)"') do want[u] = true end
        local results = {}
        for _, d in pairs(S.meili) do if d.uri and want[d.uri] then results[#results + 1] = copy(d) end end
        return { status = 200, body = json.encode({ results = results }) }
      end
      S.posts = S.posts + 1
      return write(body, false)
    end,
    put = function(_, o)
      S.puts = S.puts + 1
      return write(json.decode(o.body), true)
    end,
    get = function(url)
      if opts.fail_reads then return { status = 500, body = "down" } end
      local id = url:match("/documents/([^/]+)$")
      local d = S.meili[id]
      if not d then return { status = 404, body = "" } end
      return { status = 200, body = json.encode(d) }
    end,
    delete = function(url)
      local id = url:match("/documents/([^/]+)$")
      S.meili[id] = nil
      return { status = opts.delete_status or 202, body = "{}" }
    end,
  }
  jobs = { create = function(ty, inp) S.chained[#S.chained + 1] = { type = ty, input = copy(inp) }; return "job-" .. #S.chained end }
  job = {
    input = opts.input,
    should_stop = function() return opts.stop end,
    progress = function(p) S.progress = p end,
    warn = function(m) S.warns[#S.warns + 1] = m end,
    wait = function() S.waits = S.waits + 1 end,
  }
  return S
end

return M
