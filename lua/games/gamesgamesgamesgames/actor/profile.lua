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
    type = "profile",
    profileType = "actor",
    did = did,
    uri = uri,
    displayName = record.displayName,
    description = record.description,
    pronouns = record.pronouns,
    avatar = record.avatar
  }

  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({ doc }))
  })
end
