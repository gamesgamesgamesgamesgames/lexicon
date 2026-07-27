-- Get a list of games on the network.
--
-- Visibility: only published records are public. A caller asking for their own
--             games (`did == caller_did`) may opt into unpublished drafts with
--             `includeUnpublished`; nobody can see anyone else's drafts.
-- Sorting:    `sort` names a key in SORT_COLUMNS, never a raw column. The value
--             reaches an ORDER BY clause, which cannot be parameterised, so an
--             allowlist is the only safe way to accept it from a caller.

-- Sort keys the caller may ask for, mapped to the SQL that implements them.
-- `name` and `createdAt` live inside the record JSON rather than as columns.
local SORT_COLUMNS = {
  indexed_at = "indexed_at",
  createdAt = "record::jsonb->>'createdAt'",
  name = "record::jsonb->>'name'",
}

function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", {target_uri})
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function parse_array(val)
  if not val then return nil end
  if type(val) == "table" then
    if #val == 0 then return nil end
    return val
  end
  if type(val) == "string" and val ~= "" then
    local result = {}
    for item in string.gmatch(val, "[^,]+") do
      table.insert(result, item:match("^%s*(.-)%s*$"))
    end
    if #result == 0 then return nil end
    return result
  end
  return nil
end

function add_jsonb_array_filter(where_parts, bind, field, values)
  local clauses = {}
  for _, v in ipairs(values) do
    table.insert(bind, v)
    table.insert(clauses, "record::jsonb->'" .. field .. "' @> to_jsonb($" .. #bind .. "::text)")
  end
  table.insert(where_parts, "(" .. table.concat(clauses, " OR ") .. ")")
end

function handle()
  local limit = tonumber(params.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = 0
  if params.cursor then
    offset = tonumber(params.cursor) or 0
  end

  local include_cancelled = params.includeCancelled == true or params.includeCancelled == "true"
  local include_unpublished = params.includeUnpublished == true or params.includeUnpublished == "true"

  -- Drafts are visible only to the DID whose repo holds them. Refuse the
  -- request rather than quietly returning the published-only set, so a caller
  -- never mistakes "you may not see these" for "you have none".
  if include_unpublished then
    if not caller_did or caller_did == "" then
      return {
        error = "AuthRequired",
        message = "includeUnpublished requires an authenticated caller",
      }
    end
    if params.did ~= caller_did then
      return {
        error = "Forbidden",
        message = "includeUnpublished is only available for your own games; pass did=<your DID>",
      }
    end
  end

  local where_parts = { "collection = $1" }
  local bind = {"games.gamesgamesgamesgames.game"}

  if not include_unpublished then
    table.insert(where_parts, "record::jsonb->>'publishedAt' IS NOT NULL")
  end

  if not include_cancelled then
    table.insert(where_parts, "(record::jsonb->>'cancelled' IS NULL OR record::jsonb->>'cancelled' != 'true')")
  end

  if params.did then
    table.insert(bind, params.did)
    table.insert(where_parts, "did = $" .. #bind)
  end

  local app_types = parse_array(params.applicationTypes)
  if app_types then
    local clauses = {}
    for _, v in ipairs(app_types) do
      table.insert(bind, v)
      table.insert(clauses, "record::jsonb->>'applicationType' = $" .. #bind)
    end
    table.insert(where_parts, "(" .. table.concat(clauses, " OR ") .. ")")
  end

  local genres = parse_array(params.genres)
  if genres then
    add_jsonb_array_filter(where_parts, bind, "genres", genres)
  end

  local themes = parse_array(params.themes)
  if themes then
    add_jsonb_array_filter(where_parts, bind, "themes", themes)
  end

  local modes = parse_array(params.modes)
  if modes then
    add_jsonb_array_filter(where_parts, bind, "modes", modes)
  end

  local perspectives = parse_array(params.playerPerspectives)
  if perspectives then
    add_jsonb_array_filter(where_parts, bind, "playerPerspectives", perspectives)
  end

  local age_ratings = parse_array(params.ageRatings)
  if age_ratings then
    local include_unrated = params.includeUnrated == true or params.includeUnrated == "true"
    local clauses = {}
    for _, ar in ipairs(age_ratings) do
      local org, rating = ar:match("^(.+):(.+)$")
      if org and rating then
        table.insert(bind, org)
        local org_idx = #bind
        table.insert(bind, rating)
        local rating_idx = #bind
        table.insert(clauses,
          "EXISTS (SELECT 1 FROM jsonb_array_elements(record::jsonb->'ageRatings') AS elem " ..
          "WHERE elem->>'organization' = $" .. org_idx .. " AND elem->>'rating' = $" .. rating_idx .. ")")
      end
    end
    if include_unrated then
      table.insert(clauses, "(record::jsonb->'ageRatings' IS NULL OR jsonb_array_length(record::jsonb->'ageRatings') = 0)")
    end
    if #clauses > 0 then
      table.insert(where_parts, "(" .. table.concat(clauses, " OR ") .. ")")
    end
  end

  -- Resolved through the allowlist, never taken from the caller directly: this
  -- lands in an ORDER BY clause, where bind parameters are not usable.
  local order_col = SORT_COLUMNS.indexed_at
  if params.sort then
    order_col = SORT_COLUMNS[params.sort]
    if not order_col then
      return {
        error = "InvalidRequest",
        message = "Unknown sort field. Expected one of: indexed_at, createdAt, name",
      }
    end
  end

  local order_dir = "DESC"
  if params.sortDirection and params.sortDirection:lower() == "asc" then
    order_dir = "ASC"
  end

  local sql = "SELECT uri, record FROM happyview_records WHERE "
    .. table.concat(where_parts, " AND ")
    .. " ORDER BY " .. order_col .. " " .. order_dir
    .. " LIMIT $" .. (#bind + 1)
    .. " OFFSET $" .. (#bind + 2)
  table.insert(bind, limit + 1)
  table.insert(bind, offset)

  local rows = db.raw(sql, bind)

  local has_more = rows and #rows > limit

  local games = {}
  for i = 1, math.min(#(rows or {}), limit) do
    local record = json.decode(rows[i].record)
    table.insert(games, {
      ["$type"] = "games.gamesgamesgamesgames.defs#gameSummaryView",
      uri = rows[i].uri,
      name = record.name,
      summary = record.summary,
      media = record.media,
      slug = find_slug(rows[i].uri)
    })
  end

  local response = { games = toarray(games) }
  if has_more then
    response.cursor = tostring(offset + limit)
  end

  return response
end
