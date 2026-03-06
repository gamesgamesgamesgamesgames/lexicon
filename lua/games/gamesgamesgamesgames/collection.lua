local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local INDEX_URL = env.MEILISEARCH_URL .. "/indexes/records/documents"

function handle()
  if action == "delete" then
    http.delete(INDEX_URL .. "/" .. uri, { headers = HEADERS })
    return
  end

  local doc = {
    id = uri,
    type = "collection",
    did = did,
    uri = uri,
    name = record.name,
    description = record.description,
    collectionType = record.type
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })
end
