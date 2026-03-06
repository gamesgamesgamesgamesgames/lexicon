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
    http.delete(INDEX_URL .. "/" .. to_doc_id(uri), { headers = HEADERS })
    return
  end

  local doc = {
    id = to_doc_id(uri),
    type = "profile",
    profileType = "org",
    did = did,
    uri = uri,
    displayName = record.displayName,
    description = record.description,
    country = record.country,
    status = record.status,
    avatar = record.avatar
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })
end
