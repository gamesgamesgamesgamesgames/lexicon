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
    type = "platform",
    did = did,
    uri = uri,
    name = record.name,
    abbreviation = record.abbreviation,
    alternativeName = record.alternativeName,
    description = record.description,
    category = record.category
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })
end
