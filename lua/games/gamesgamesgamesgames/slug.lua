-- When a slug record is created/updated/deleted, patch the referenced
-- document in Meilisearch so the slug is stored directly on the search
-- record. This avoids per-hit DB lookups at search time.

local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local INDEX_URL = env.MEILISEARCH_URL .. "/indexes/records/documents"

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function to_doc_id(s)
  local out = {}
  local i = 1
  while i <= #s do
    local a, b, c = string.byte(s, i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 65536 + b * 256 + c
    local remaining = #s - i + 1
    table.insert(out, string.sub(b64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
    table.insert(out, string.sub(b64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if remaining >= 2 then table.insert(out, string.sub(b64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)) end
    if remaining >= 3 then table.insert(out, string.sub(b64, n % 64 + 1, n % 64 + 1)) end
    i = i + 3
  end
  return table.concat(out)
end

function handle()
  if action == "delete" then
    -- Slug deleted — clear the slug on the referenced document.
    -- We still have `record` from the deleted slug.
    if not record or not record.ref then return true end

    http.post(INDEX_URL, {
      headers = HEADERS,
      body = json.encode(toarray({
        { id = to_doc_id(record.ref), slug = json.null }
      }))
    })
    return true
  end

  if not record.ref or not record.slug then return record end

  -- Partial update: set the slug on the referenced document
  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({
      { id = to_doc_id(record.ref), slug = record.slug }
    }))
  })

  return record
end
