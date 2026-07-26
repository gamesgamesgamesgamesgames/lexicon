-- Owner-facing analytics for a single game.
--
-- Auth:      requires an authenticated caller (`caller_did`); anonymous
--            requests are rejected.
-- Ownership: a game is owned by the DID whose repo holds the game record.
--            Verified creators' games live in their own repo; unverified
--            submissions live in a shared repo and are moved ("migrated") into
--            a claimant's repo when an ownership claim is approved. In every
--            case the owning DID is the authority segment of the record's
--            AT-URI. (Mirrors getGame.lua's verified-owner lookup and the
--            `did` filter in listGames.lua.)
-- Data:      behavioral rollups come from a separate self-hosted ClickHouse
--            (read over HTTP); record-creation trends come from HappyView's
--            own `happyview_records`.

local RANGE_DAYS = { ["7d"] = 7, ["30d"] = 30, ["90d"] = 90 }

local DWELL_BUCKETS = { "0-10s", "10-30s", "30-60s", "1-3m", "3m+" }

local RECORD_TREND_COLLECTIONS = {
  likes = "games.gamesgamesgamesgames.graph.like",
  reviews = "games.gamesgamesgamesgames.feed.review",
  listAdds = "games.gamesgamesgamesgames.feed.listItem",
}

-- ---------------------------------------------------------------------------
-- Small numeric helpers.
-- ---------------------------------------------------------------------------

local function num(v)
  return tonumber(v) or 0
end

-- Round to a whole number (ClickHouse aggregates arrive as strings/floats).
local function iround(v)
  return math.floor(num(v) + 0.5)
end

-- Round a fraction to 4 decimal places (used for CTR, 0..1).
local function round4(v)
  return math.floor(num(v) * 10000 + 0.5) / 10000
end

-- Round to a single decimal place (used for percentages).
local function round1(v)
  return math.floor(num(v) * 10 + 0.5) / 10
end

-- ---------------------------------------------------------------------------
-- Range → inclusive UTC Date bounds + the full day axis.
-- ---------------------------------------------------------------------------

local function normalize_range(r)
  if r and RANGE_DAYS[r] then return r end
  return "30d"
end

-- Ordered list of 'YYYY-MM-DD' UTC days ending today, `days` long.
local function date_axis(days)
  local now_t = os.time()
  local axis = {}
  for i = days - 1, 0, -1 do
    axis[#axis + 1] = os.date("!%Y-%m-%d", now_t - i * 86400)
  end
  return axis
end

-- ---------------------------------------------------------------------------
-- ClickHouse HTTP read helper.
--
-- POSTs SQL to the ClickHouse HTTP interface with `FORMAT JSON`, using a
-- read-only user over basic-style ClickHouse auth headers. Query parameters
-- are bound with ClickHouse's `{name:Type}` / `param_name` mechanism so slugs
-- and dates are never interpolated into SQL. Returns the `data` array, or an
-- empty table on ANY failure — ClickHouse being unreachable must never error
-- the whole request.
-- ---------------------------------------------------------------------------

local function ch_urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function ch_query(sql, ch_params)
  local base = env.CLICKHOUSE_URL
  if not base or base == "" then return {} end

  local qs = "default_format=JSON&database=" ..
    ch_urlencode(env.CLICKHOUSE_DATABASE or "cartridge_analytics")
  if ch_params then
    for k, v in pairs(ch_params) do
      qs = qs .. "&param_" .. k .. "=" .. ch_urlencode(v)
    end
  end

  local ok, resp = pcall(function()
    return http.post(base .. "?" .. qs, {
      headers = {
        ["X-ClickHouse-User"] = env.CLICKHOUSE_READ_USER or "readonly",
        ["X-ClickHouse-Key"] = env.CLICKHOUSE_READONLY_PASSWORD or "",
        ["content-type"] = "text/plain",
      },
      body = sql,
    })
  end)

  if not ok or not resp or resp.status ~= 200 then
    return {}
  end

  local decoded_ok, decoded = pcall(json.decode, resp.body)
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
    return {}
  end
  return decoded.data
end

-- ---------------------------------------------------------------------------
-- Ownership helpers.
-- ---------------------------------------------------------------------------

local function resolve_slug_to_uri(slug)
  local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", { slug })
  if rows and #rows > 0 then return rows[1].uri end
  return nil
end

local function owner_of(uri)
  return uri:match("^at://([^/]+)/")
end

-- ---------------------------------------------------------------------------
-- Record-creation trends from HappyView (authoritative, not ClickHouse).
--
-- Likes/reviews/list-adds all reference a game via `record.subject` = game URI
-- (same predicate getHotGamesFeed.lua uses to compute weekly counts). Grouped
-- by UTC day over the range.
-- ---------------------------------------------------------------------------

local function record_trend_by_day(collection, game_uri, from)
  local counts = {}
  -- indexed_at/created_at are ISO-8601 UTC text (e.g. 2026-07-26T02:12:44Z), not
  -- timestamp columns — so we take the YYYY-MM-DD prefix directly (substr is
  -- portable to Postgres + SQLite) rather than timezone math, and compare
  -- against an explicit UTC cutoff (…T00:00:00Z), mirroring getHotGamesFeed.lua.
  local cutoff = from .. "T00:00:00Z"
  local rows = db.raw(
    "SELECT substr(COALESCE(indexed_at, created_at), 1, 10) AS day, " ..
    "COUNT(*) AS c FROM happyview_records " ..
    "WHERE collection = $1 AND record::jsonb->>'subject' = $2 " ..
    "AND COALESCE(indexed_at, created_at) >= $3 GROUP BY day",
    { collection, game_uri, cutoff }
  )
  if rows then
    for _, row in ipairs(rows) do
      counts[row.day] = num(row.c)
    end
  end
  return counts
end

function handle()
  -- Require authentication.
  if not caller_did or caller_did == "" then
    return { error = "AuthRequired", message = "Authentication required" }
  end

  local slug = params.slug
  if not slug or slug == "" then
    return { error = "InvalidRequest", message = "slug is required" }
  end

  local range = normalize_range(params.range)
  local days = RANGE_DAYS[range]
  local axis = date_axis(days)
  local from = axis[1]
  local to = axis[#axis]

  -- Resolve the slug and enforce ownership.
  local uri = resolve_slug_to_uri(slug)
  if not uri then
    return { error = "NotFound", message = "Game not found" }
  end
  if owner_of(uri) ~= caller_did then
    return { error = "Forbidden", message = "You do not own this game" }
  end

  local record = db.get(uri)
  local name = (record and record.name) or slug

  local ch = { slug = slug, from = from, to = to }

  -- --- Discovery: impressions per day split by surface -------------------
  local surface_daily = ch_query(
    "SELECT date, surface, sumMerge(impressions) AS impressions " ..
    "FROM daily_game_surface " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY date, surface ORDER BY date", ch)

  local impressions_by_day = {}
  for _, d in ipairs(axis) do
    impressions_by_day[d] = { search = 0, feed = 0 }
  end
  for _, row in ipairs(surface_daily) do
    local slot = impressions_by_day[row.date]
    if slot then
      if row.surface == "search" then
        slot.search = slot.search + iround(row.impressions)
      elseif row.surface == "feed" then
        slot.feed = slot.feed + iround(row.impressions)
      end
    end
  end
  local impressions_over_time = {}
  for _, d in ipairs(axis) do
    impressions_over_time[#impressions_over_time + 1] = {
      date = d,
      search = impressions_by_day[d].search,
      feed = impressions_by_day[d].feed,
    }
  end

  -- --- Surface totals + CTR by surface -----------------------------------
  local surface_totals = ch_query(
    "SELECT surface, sumMerge(impressions) AS impressions, sumMerge(clicks) AS clicks " ..
    "FROM daily_game_surface " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY surface", ch)

  local total_impressions = 0
  local total_clicks = 0
  local ctr_by_surface = {}
  for _, row in ipairs(surface_totals) do
    local imp = iround(row.impressions)
    local clk = iround(row.clicks)
    total_impressions = total_impressions + imp
    total_clicks = total_clicks + clk
    ctr_by_surface[#ctr_by_surface + 1] = {
      surface = row.surface,
      impressions = imp,
      clicks = clk,
      ctr = imp > 0 and round4(clk / imp) or 0,
    }
  end

  -- --- Feed breakdown ----------------------------------------------------
  local feed_rows = ch_query(
    "SELECT feed_name, sumMerge(impressions) AS impressions " ..
    "FROM daily_game_surface " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "AND feed_name != '' GROUP BY feed_name ORDER BY impressions DESC LIMIT 25", ch)
  local feed_breakdown = {}
  for _, row in ipairs(feed_rows) do
    feed_breakdown[#feed_breakdown + 1] = { name = row.feed_name, count = iround(row.impressions) }
  end

  -- --- Top search terms --------------------------------------------------
  local term_rows = ch_query(
    "SELECT query, countMerge(impressions) AS impressions " ..
    "FROM daily_game_search_terms " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY query ORDER BY impressions DESC LIMIT 25", ch)
  local top_search_terms = {}
  for _, row in ipairs(term_rows) do
    if row.query and row.query ~= "" then
      top_search_terms[#top_search_terms + 1] = { name = row.query, count = iround(row.impressions) }
    end
  end

  -- --- Attribution: traffic sources & referrer feeds ---------------------
  local traffic_rows = ch_query(
    "SELECT referrer_type, countMerge(pageviews) AS pageviews " ..
    "FROM daily_game_traffic " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY referrer_type ORDER BY pageviews DESC", ch)
  local traffic_sources = {}
  for _, row in ipairs(traffic_rows) do
    local label = row.referrer_type
    if not label or label == "" then label = "unknown" end
    traffic_sources[#traffic_sources + 1] = { name = label, count = iround(row.pageviews) }
  end

  local referrer_rows = ch_query(
    "SELECT referrer_feed, countMerge(pageviews) AS pageviews " ..
    "FROM daily_game_traffic " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "AND referrer_feed != '' GROUP BY referrer_feed ORDER BY pageviews DESC LIMIT 25", ch)
  local top_referrer_feeds = {}
  for _, row in ipairs(referrer_rows) do
    top_referrer_feeds[#top_referrer_feeds + 1] = { name = row.referrer_feed, count = iround(row.pageviews) }
  end

  -- --- Engagement summary (dwell / scroll / pageviews) -------------------
  local eng_summary = ch_query(
    "SELECT countMerge(pageviews) AS pageviews, avgMerge(dwell_avg) AS dwell_avg, " ..
    "quantileMerge(0.5)(dwell_median) AS dwell_median, avgMerge(scroll_avg) AS scroll_avg " ..
    "FROM daily_game_engagement " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date}", ch)
  local summary = eng_summary[1] or {}
  local total_pageviews = iround(summary.pageviews)
  local avg_dwell_ms = iround(summary.dwell_avg)
  local median_dwell_ms = iround(summary.dwell_median)
  local avg_scroll_pct = round1(summary.scroll_avg)

  -- --- Engagement daily uniques ------------------------------------------
  local uniques_rows = ch_query(
    "SELECT date, uniqMerge(uniques) AS uniques " ..
    "FROM daily_game_engagement " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY date ORDER BY date", ch)
  local uniques_by_day = {}
  for _, row in ipairs(uniques_rows) do
    uniques_by_day[row.date] = iround(row.uniques)
  end
  local daily_uniques = {}
  local uniques_sum = 0
  local uniques_days = 0
  for _, d in ipairs(axis) do
    local v = uniques_by_day[d] or 0
    daily_uniques[#daily_uniques + 1] = { date = d, value = v }
    if uniques_by_day[d] then
      uniques_sum = uniques_sum + v
      uniques_days = uniques_days + 1
    end
  end
  local avg_daily_uniques = uniques_days > 0 and round1(uniques_sum / uniques_days) or 0

  -- --- Tab engagement ----------------------------------------------------
  local tab_rows = ch_query(
    "SELECT tab, countMerge(views) AS views " ..
    "FROM daily_game_tabs " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY tab ORDER BY views DESC", ch)
  local tab_engagement = {}
  for _, row in ipairs(tab_rows) do
    if row.tab and row.tab ~= "" then
      tab_engagement[#tab_engagement + 1] = { name = row.tab, count = iround(row.views) }
    end
  end

  -- --- Dwell distribution (bucketed from the raw events table) -----------
  -- Time-of-event dwell buckets aren't available from the daily rollups, so
  -- we bucket `dwell_ms` directly from `events` (event_type='dwell').
  local dwell_rows = ch_query(
    "SELECT multiIf(dwell_ms < 10000, '0-10s', dwell_ms < 30000, '10-30s', " ..
    "dwell_ms < 60000, '30-60s', dwell_ms < 180000, '1-3m', '3m+') AS bucket, " ..
    "count() AS c FROM events " ..
    "WHERE game_slug = {slug:String} AND event_type = 'dwell' " ..
    "AND toDate(ts) BETWEEN {from:Date} AND {to:Date} GROUP BY bucket", ch)
  local dwell_counts = {}
  for _, row in ipairs(dwell_rows) do
    dwell_counts[row.bucket] = iround(row.c)
  end
  local dwell_distribution = {}
  for _, bucket in ipairs(DWELL_BUCKETS) do
    dwell_distribution[#dwell_distribution + 1] = { name = bucket, count = dwell_counts[bucket] or 0 }
  end

  -- --- Conversions: funnel actions total ---------------------------------
  local actions_rows = ch_query(
    "SELECT countMerge(actions) AS actions FROM daily_game_actions " ..
    "WHERE game_slug = {slug:String} AND date BETWEEN {from:Date} AND {to:Date}", ch)
  local total_actions = iround(actions_rows[1] and actions_rows[1].actions)

  -- --- Conversions: record-creation trends (HappyView) -------------------
  local likes_by_day = record_trend_by_day(RECORD_TREND_COLLECTIONS.likes, uri, from)
  local reviews_by_day = record_trend_by_day(RECORD_TREND_COLLECTIONS.reviews, uri, from)
  local list_adds_by_day = record_trend_by_day(RECORD_TREND_COLLECTIONS.listAdds, uri, from)
  local record_trends = {}
  for _, d in ipairs(axis) do
    record_trends[#record_trends + 1] = {
      date = d,
      likes = likes_by_day[d] or 0,
      reviews = reviews_by_day[d] or 0,
      listAdds = list_adds_by_day[d] or 0,
    }
  end

  -- --- Assemble ----------------------------------------------------------
  return {
    slug = slug,
    name = name,
    range = range,
    generatedAt = now(),
    totals = {
      impressions = total_impressions,
      clicks = total_clicks,
      pageviews = total_pageviews,
      ctr = total_impressions > 0 and round4(total_clicks / total_impressions) or 0,
      avgDwellMs = avg_dwell_ms,
      medianDwellMs = median_dwell_ms,
      avgScrollPct = avg_scroll_pct,
      avgDailyUniques = avg_daily_uniques,
    },
    discovery = {
      impressionsOverTime = toarray(impressions_over_time),
      feedBreakdown = toarray(feed_breakdown),
      topSearchTerms = toarray(top_search_terms),
    },
    attribution = {
      trafficSources = toarray(traffic_sources),
      topReferrerFeeds = toarray(top_referrer_feeds),
      ctrBySurface = toarray(ctr_by_surface),
    },
    engagement = {
      dwellDistribution = toarray(dwell_distribution),
      avgScrollPct = avg_scroll_pct,
      tabEngagement = toarray(tab_engagement),
      dailyUniques = toarray(daily_uniques),
    },
    conversions = {
      recordTrends = toarray(record_trends),
      funnel = {
        impressions = total_impressions,
        pageviews = total_pageviews,
        actions = total_actions,
      },
    },
  }
end
