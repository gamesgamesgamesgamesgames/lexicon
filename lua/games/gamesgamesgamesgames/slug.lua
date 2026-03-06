-- When a slug record is created/updated/deleted, patch the referenced
-- document in Meilisearch so the slug is stored directly on the search
-- record. This avoids per-hit DB lookups at search time.

local HEADERS = {
  ["Authorization"] = "Bearer " .. env.MEILISEARCH_API_KEY,
  ["content-type"] = "application/json"
}

local INDEX_URL = env.MEILISEARCH_URL .. "/indexes/records/documents"

function handle()
  if action == "delete" then
    -- Slug deleted — clear the slug on the referenced document.
    -- We still have `record` from the deleted slug.
    if not record or not record.ref then return end

    http.post(INDEX_URL, {
      headers = HEADERS,
      body = json.encode(toarray({
        { id = record.ref, slug = json.null }
      }))
    })
    return
  end

  if not record.ref or not record.slug then return end

  -- Partial update: set the slug on the referenced document
  http.post(INDEX_URL, {
    headers = HEADERS,
    body = json.encode(toarray({
      { id = record.ref, slug = record.slug }
    }))
  })
end
