local function get_admin_space_uri()
  local rows = db.raw(
    "SELECT owner_did FROM happyview_spaces WHERE type_nsid = 'dev.cartridge.claims.adminGroup' AND skey = 'self' LIMIT 1",
    {}
  )
  if not rows or #rows == 0 then return nil end
  return "at://" .. rows[1].owner_did .. "/space/dev.cartridge.claims.adminGroup/self"
end

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
  local uri = params.uri
  if not uri or uri == "" then
    error("uri is required")
  end

  local claimant_did = uri:match("^at://([^/]+)/")
  if not claimant_did then
    error("invalid claim URI")
  end

  local admin_space_uri = get_admin_space_uri()
  local is_admin = admin_space_uri and atproto.spaces.is_member(admin_space_uri, caller_did)
  if caller_did ~= claimant_did and not is_admin then
    error("unauthorized")
  end

  local rows = db.raw(
    "SELECT uri, cid, record FROM happyview_space_records WHERE uri = $1 LIMIT 1",
    { uri }
  )

  if not rows or #rows == 0 then
    error("claim not found")
  end

  local row = rows[1]
  local record = json.decode(row.record)

  local claim_view = {
    ["$type"] = "dev.cartridge.claims.getClaim#claimView",
    uri = row.uri,
    cid = row.cid,
    type = record.type,
    claimantDid = claimant_did,
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

  if record.type == "org" and record.org then
    local all_credits = {}
    local cursor = nil
    repeat
      local bl_opts = {
        collection = "games.gamesgamesgamesgames.org.credit",
        uri = record.org,
        limit = 100,
      }
      if cursor then
        bl_opts.cursor = cursor
      end
      local backlinks = db.backlinks(bl_opts)
      if backlinks and backlinks.records then
        for _, credit in ipairs(backlinks.records) do
          table.insert(all_credits, credit)
        end
        cursor = backlinks.cursor
      else
        cursor = nil
      end
    until not cursor

    local seen = {}
    local games = {}
    for _, credit in ipairs(all_credits) do
      local game_uri = credit.game and credit.game.uri or nil
      if game_uri and not seen[game_uri] then
        seen[game_uri] = true
        local game_record = db.get(game_uri)
        local summary = build_game_summary(game_record)
        if summary then
          table.insert(games, summary)
        end
      end
    end
    claim_view.games = games
  end

  if is_admin and record.contact then
    claim_view.contact = record.contact
  end

  local space_uri = "at://" .. claimant_did .. "/space/dev.cartridge.claims.space/self"
  local review_rows = db.raw(
    "SELECT sr.uri, sr.record FROM happyview_space_records sr " ..
    "INNER JOIN happyview_spaces s ON s.id = sr.space_id " ..
    "WHERE s.id = (SELECT id FROM happyview_spaces WHERE owner_did = $1 AND type_nsid = 'dev.cartridge.claims.space' AND skey = 'self' LIMIT 1) " ..
    "AND sr.collection = 'dev.cartridge.claims.claimReview' " ..
    "AND sr.record::jsonb->'claim'->>'uri' = $2 LIMIT 1",
    { claimant_did, uri }
  )

  if review_rows and #review_rows > 0 then
    local review_row = review_rows[1]
    local review_record = json.decode(review_row.record)
    claim_view.review = {
      ["$type"] = "dev.cartridge.claims.getClaim#reviewView",
      uri = review_row.uri,
      status = review_record.status,
      reviewedBy = review_record.reviewedBy,
      createdAt = review_record.createdAt,
      approvedGames = review_record.approvedGames,
      reason = review_record.reason,
    }
  end

  return { claim = claim_view }
end
