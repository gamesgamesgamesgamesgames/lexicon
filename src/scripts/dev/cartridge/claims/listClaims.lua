local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

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
  local is_admin = ADMIN_DIDS[caller_did]
  local limit = params.limit or 25
  local status_filter = params.status
  local cursor_val = params.cursor

  local cursor_indexed_at = nil
  local cursor_uri = nil
  if cursor_val and cursor_val ~= "" then
    local pipe_pos = cursor_val:find("|", 1, true)
    if pipe_pos then
      cursor_indexed_at = cursor_val:sub(1, pipe_pos - 1)
      cursor_uri = cursor_val:sub(pipe_pos + 1)
    end
  end

  local sql = ""
  local sql_params = {}
  local param_idx = 0

  local function next_param(val)
    param_idx = param_idx + 1
    sql_params[param_idx] = val
    return "$" .. param_idx
  end

  if status_filter == "pending" then
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at, c.author_did FROM happyview_space_records c " ..
          "INNER JOIN happyview_spaces s ON s.id = c.space_id AND s.type_nsid = 'dev.cartridge.claims.space' " ..
          "WHERE c.collection = 'dev.cartridge.claims.claim' " ..
          "AND NOT EXISTS (" ..
            "SELECT 1 FROM happyview_space_records r WHERE r.space_id = c.space_id " ..
            "AND r.collection = 'dev.cartridge.claims.claimReview' " ..
            "AND r.record::jsonb->'claim'->>'uri' = c.uri" ..
          ")"

    if not is_admin then
      sql = sql .. " AND c.author_did = " .. next_param(caller_did)
    end

    if cursor_indexed_at and cursor_uri then
      sql = sql .. " AND (c.indexed_at, c.uri) < (" .. next_param(cursor_indexed_at) .. ", " .. next_param(cursor_uri) .. ")"
    end

    sql = sql .. " ORDER BY c.indexed_at DESC, c.uri DESC LIMIT " .. next_param(limit)

  elseif status_filter == "approved" or status_filter == "denied" then
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at, c.author_did FROM happyview_space_records c " ..
          "INNER JOIN happyview_spaces s ON s.id = c.space_id AND s.type_nsid = 'dev.cartridge.claims.space' " ..
          "INNER JOIN happyview_space_records r ON r.space_id = c.space_id " ..
          "AND r.collection = 'dev.cartridge.claims.claimReview' " ..
          "AND r.record::jsonb->'claim'->>'uri' = c.uri " ..
          "AND r.record::jsonb->>'status' = " .. next_param(status_filter) .. " " ..
          "WHERE c.collection = 'dev.cartridge.claims.claim'"

    if not is_admin then
      sql = sql .. " AND c.author_did = " .. next_param(caller_did)
    end

    if cursor_indexed_at and cursor_uri then
      sql = sql .. " AND (c.indexed_at, c.uri) < (" .. next_param(cursor_indexed_at) .. ", " .. next_param(cursor_uri) .. ")"
    end

    sql = sql .. " ORDER BY c.indexed_at DESC, c.uri DESC LIMIT " .. next_param(limit)

  else
    sql = "SELECT c.uri, c.cid, c.record, c.indexed_at, c.author_did FROM happyview_space_records c " ..
          "INNER JOIN happyview_spaces s ON s.id = c.space_id AND s.type_nsid = 'dev.cartridge.claims.space' " ..
          "WHERE c.collection = 'dev.cartridge.claims.claim'"

    if not is_admin then
      sql = sql .. " AND c.author_did = " .. next_param(caller_did)
    end

    if cursor_indexed_at and cursor_uri then
      sql = sql .. " AND (c.indexed_at, c.uri) < (" .. next_param(cursor_indexed_at) .. ", " .. next_param(cursor_uri) .. ")"
    end

    sql = sql .. " ORDER BY c.indexed_at DESC, c.uri DESC LIMIT " .. next_param(limit)
  end

  local rows = db.raw(sql, sql_params)

  local claims = {}
  local last_row = nil

  for _, row in ipairs(rows or {}) do
    local record = json.decode(row.record)

    local claim_view = {
      ["$type"] = "dev.cartridge.claims.getClaim#claimView",
      uri = row.uri,
      cid = row.cid,
      type = record.type,
      claimantDid = row.author_did,
      createdAt = record.createdAt,
      message = record.message,
      org = record.org,
    }

    if record.type == "game" and record.games then
      local games = {}
      for _, game_uri in ipairs(record.games) do
        local game_record = db.get(game_uri)
        local summary = build_game_summary(game_record)
        if summary then
          table.insert(games, summary)
        end
      end
      claim_view.games = games
    end

    if is_admin and record.contact then
      claim_view.contact = record.contact
    end

    local review_rows = db.raw(
      "SELECT uri, record FROM happyview_space_records WHERE space_id = (SELECT space_id FROM happyview_space_records WHERE uri = $1) AND collection = 'dev.cartridge.claims.claimReview' AND record::jsonb->'claim'->>'uri' = $2 LIMIT 1",
      { row.uri, row.uri }
    )

    if review_rows and #review_rows > 0 then
      local review_record = json.decode(review_rows[1].record)
      claim_view.review = {
        ["$type"] = "dev.cartridge.claims.getClaim#reviewView",
        uri = review_rows[1].uri,
        status = review_record.status,
        reviewedBy = review_record.reviewedBy,
        createdAt = review_record.createdAt,
        approvedGames = review_record.approvedGames,
        reason = review_record.reason,
      }
    end

    table.insert(claims, claim_view)
    last_row = row
  end

  local next_cursor = nil
  if last_row and #claims == limit then
    next_cursor = last_row.indexed_at .. "|" .. last_row.uri
  end

  return { claims = toarray(claims), cursor = next_cursor }
end
