function find_slug(target_uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", { target_uri })
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function build_game_summary(game_record)
  if not game_record then return nil end

  local first_release_date = nil
  if game_record.releases then
    for _, release in ipairs(game_record.releases) do
      if release.releaseDates then
        for _, rd in ipairs(release.releaseDates) do
          if rd.releasedAt then
            local date_int = tonumber(rd.releasedAt:gsub("%-", ""):sub(1, 8))
            if date_int and (not first_release_date or date_int < first_release_date) then
              first_release_date = date_int
            end
          end
        end
      end
    end
  end

  return {
    ["$type"] = "games.gamesgamesgamesgames.defs#gameSummaryView",
    uri = game_record.uri,
    name = game_record.name,
    summary = game_record.summary,
    media = game_record.media,
    slug = find_slug(game_record.uri),
    applicationType = game_record.applicationType,
    firstReleaseDate = first_release_date,
  }
end

function handle()
  local org_uri = params.org
  if not org_uri or org_uri == "" then
    error("org parameter is required")
  end

  local limit = params.limit or 50
  local cursor_offset = 0
  if params.cursor and params.cursor ~= "" then
    cursor_offset = tonumber(params.cursor) or 0
  end

  -- Collect all org.credit records referencing this org (paginate backlinks since limit=100)
  local all_credits = {}
  local bl_cursor = nil
  repeat
    local bl_opts = {
      collection = "games.gamesgamesgamesgames.org.credit",
      uri = org_uri,
      limit = 100,
    }
    if bl_cursor then
      bl_opts.cursor = bl_cursor
    end
    local backlinks = db.backlinks(bl_opts)
    if backlinks and backlinks.records then
      for _, credit in ipairs(backlinks.records) do
        table.insert(all_credits, credit)
      end
      bl_cursor = backlinks.cursor
    else
      bl_cursor = nil
    end
  until not bl_cursor

  -- Extract unique game URIs
  local seen = {}
  local game_uris = {}
  for _, credit in ipairs(all_credits) do
    local game_uri = credit.game and credit.game.uri or nil
    if game_uri and not seen[game_uri] then
      seen[game_uri] = true
      table.insert(game_uris, game_uri)
    end
  end

  -- Apply offset-based pagination
  local page_start = cursor_offset + 1
  local page_end = cursor_offset + limit
  local page = {}

  for i = page_start, math.min(page_end, #game_uris) do
    local game_record = db.get(game_uris[i])
    local summary = build_game_summary(game_record)
    if summary then
      table.insert(page, summary)
    end
  end

  -- Build cursor for next page
  local next_cursor = nil
  if page_end < #game_uris then
    next_cursor = tostring(page_end)
  end

  return { games = toarray(page), cursor = next_cursor }
end
