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

  -- Extract just the name strings from alternativeNames objects
  local alt_names = {}
  if record.alternativeNames then
    for _, an in ipairs(record.alternativeNames) do
      if an.name then
        table.insert(alt_names, an.name)
      end
    end
  end

  local obj = {
    objectID = uri,
    type = "game",
    did = did,
    uri = uri,
    name = record.name,
    summary = record.summary,
    storyline = record.storyline,
    keywords = record.keywords,
    genres = record.genres,
    modes = record.modes,
    themes = record.themes,
    playerPerspectives = record.playerPerspectives,
    alternativeNames = alt_names,
    multiplayerModes = record.multiplayerModes,
    applicationType = record.applicationType,
    media = record.media
  }

  http.put(env.ALGOLIA_BASE_URL .. "/" .. url_encode(uri), {
    headers = HEADERS,
    body = json.encode(obj)
  })
end
