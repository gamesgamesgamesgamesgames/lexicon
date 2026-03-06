local HEADERS = {
  ["X-Algolia-Application-Id"] = env.ALGOLIA_APP_ID,
  ["X-Algolia-API-Key"] = env.ALGOLIA_WRITE_KEY,
  ["content-type"] = "application/json"
}

local function url_encode(s)
  return (s:gsub("[^%w_%-%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function handle()
  if action == "delete" then
    http.delete(env.ALGOLIA_BASE_URL .. "/" .. url_encode(uri), { headers = HEADERS })
    return
  end

  local obj = {
    objectID = uri,
    type = "engine",
    did = did,
    uri = uri,
    name = record.name,
    description = record.description
  }

  http.put(env.ALGOLIA_BASE_URL .. "/" .. url_encode(uri), {
    headers = HEADERS,
    body = json.encode(obj)
  })
end
