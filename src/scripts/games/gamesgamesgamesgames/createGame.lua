-- Accented Latin letters, grouped by the plain letter each one decomposes to
-- (its Unicode NFD form without the combining marks). Slugs fold them the
-- way the sync's old slugify did: "Löwenzahn" becomes "lowenzahn".
local ACCENT_FOLD = {}
for letter, accented in ([[
a ÀÁÂÃÄÅàáâãäåĀāĂăĄąǍǎǞǟǠǡǺǻȀȁȂȃȦȧḀḁẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặ
b ḂḃḄḅḆḇ
c ÇçĆćĈĉĊċČčḈḉ
d ĎďḊḋḌḍḎḏḐḑḒḓ
e ÈÉÊËèéêëĒēĔĕĖėĘęĚěȄȅȆȇȨȩḔḕḖḗḘḙḚḛḜḝẸẹẺẻẼẽẾếỀềỂểỄễỆệ
f Ḟḟ
g ĜĝĞğĠġĢģǦǧǴǵḠḡ
h ĤĥȞȟḢḣḤḥḦḧḨḩḪḫẖ
i ÌÍÎÏìíîïĨĩĪīĬĭĮįİǏǐȈȉȊȋḬḭḮḯỈỉỊị
j Ĵĵǰ
k ĶķǨǩḰḱḲḳḴḵ
l ĹĺĻļĽľḶḷḸḹḺḻḼḽ
m ḾḿṀṁṂṃ
n ÑñŃńŅņŇňǸǹṄṅṆṇṈṉṊṋ
o ÒÓÔÕÖòóôõöŌōŎŏŐőƠơǑǒǪǫǬǭȌȍȎȏȪȫȬȭȮȯȰȱṌṍṎṏṐṑṒṓỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợ
p ṔṕṖṗ
r ŔŕŖŗŘřȐȑȒȓṘṙṚṛṜṝṞṟ
s ŚśŜŝŞşŠšȘșṠṡṢṣṤṥṦṧṨṩ
t ŢţŤťȚțṪṫṬṭṮṯṰṱẗ
u ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲųƯưǓǔǕǖǗǘǙǚǛǜȔȕȖȗṲṳṴṵṶṷṸṹṺṻỤụỦủỨứỪừỬửỮữỰự
v ṼṽṾṿ
w ŴŵẀẁẂẃẄẅẆẇẈẉẘ
x ẊẋẌẍ
y ÝýÿŶŷŸȲȳẎẏẙỲỳỴỵỶỷỸỹ
z ŹźŻżŽžẐẑẒẓẔẕ
]]):gmatch("(%a) (%S+)") do
  for ch in accented:gmatch("[\xC2-\xF4][\x80-\xBF]*") do
    ACCENT_FOLD[ch] = letter
  end
end

function generate_slug(str)
  if not str or str == "" then
    return nil
  end

  local slug = (str:gsub("[\xC2-\xF4][\x80-\xBF]*", ACCENT_FOLD)):lower()
  slug = slug:gsub("[^%w%s%-]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")

  if slug == "" then
    return nil
  end

  return slug
end

local MAX_SLUG_SUFFIX = 1000

local function slug_owner(slug)
  local rows = db.raw("SELECT uri FROM slugs WHERE slug = $1 LIMIT 1", { slug })
  return rows and rows[1] and rows[1].uri or nil
end

-- Same rule as game.lua's ensure_slug, so the two arrive at the same slug
-- whichever runs first.
local function assign_generated_slug(target_uri, name)
  local own = db.raw("SELECT slug FROM slugs WHERE uri = $1 ORDER BY length(slug), slug LIMIT 1", { target_uri })
  if own and #own > 0 then
    return own[1].slug
  end
  local base = generate_slug(name)
  if not base then
    return nil
  end
  local slug, n = base, 1
  while n <= MAX_SLUG_SUFFIX do
    local owner = slug_owner(slug)
    if not owner then
      db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO NOTHING", { slug, target_uri })
      owner = slug_owner(slug)
    end
    if owner == target_uri then
      return slug
    end
    n = n + 1
    slug = base .. "-" .. n
  end
  error("no free slug for " .. target_uri .. " after " .. base .. "-" .. MAX_SLUG_SUFFIX)
end

function resolve_twitch_id(igdb_id)
  if not igdb_id or igdb_id == "" then return nil end
  if not env.TWITCH_CLIENT_ID or not env.TWITCH_ACCESS_TOKEN then return nil end

  local resp = http.get("https://api.twitch.tv/helix/games?igdb_id=" .. igdb_id, {
    headers = {
      ["Client-ID"] = env.TWITCH_CLIENT_ID,
      ["Authorization"] = "Bearer " .. env.TWITCH_ACCESS_TOKEN,
    }
  })

  if resp and resp.status == 200 then
    local body = json.decode(resp.body)
    if body and body.data and #body.data > 0 then
      return body.data[1].id
    end
  end

  return nil
end

function handle()
  -- Enrich externalIds: resolve Twitch ID from IGDB ID if missing
  local external_ids = input.externalIds
  if external_ids then
    if external_ids.igdb and (not external_ids.twitch or external_ids.twitch == "") then
      external_ids.twitch = resolve_twitch_id(external_ids.igdb)
    end
  end

  local game_data = {
    name = input.name,
    summary = input.summary,
    applicationType = input.applicationType,
    genres = input.genres,
    modes = input.modes,
    themes = input.themes,
    playerPerspectives = input.playerPerspectives,
    releases = input.releases,
    media = input.media,
    parent = input.parent,
    storyline = input.storyline,
    keywords = input.keywords,
    websites = input.websites,
    videos = input.videos,
    alternativeNames = input.alternativeNames,
    timeToBeat = input.timeToBeat,
    ageRatings = input.ageRatings,
    languageSupports = input.languageSupports,
    multiplayerModes = input.multiplayerModes,
    engines = input.engines,
    externalIds = external_ids,
    createdAt = now()
  }

  if input.shouldPublish then
    game_data.publishedAt = now()
  end

  -- The game lexicon requires applicationType but the createGame input schema
  -- does not, so check it here. Record.new():save() would catch this on the
  -- verified path; the linked-repo path has no schema to validate against.
  if not game_data.applicationType then
    error("applicationType is required")
  end

  -- Check if the caller is verified (has a dev.cartridge.graph.verification record from the trusted verifier)
  local VERIFIER_DID = env.VERIFIER_DID
  local PENTARACT_DID = env.PENTARACT_DID

  local is_verified = false
  if VERIFIER_DID and VERIFIER_DID ~= "" then
    local verification_rows = db.raw(
      "SELECT uri FROM happyview_records WHERE collection = 'dev.cartridge.graph.verification' AND did = $1 AND record::jsonb->>'subject' = $2 LIMIT 1",
      { VERIFIER_DID, caller_did }
    )
    is_verified = verification_rows and #verification_rows > 0
  end

  local uri, cid

  if is_verified or not PENTARACT_DID or PENTARACT_DID == "" then
    -- Verified author: the game lives in their own repo, written with their
    -- own credentials.
    local game = Record.new("games.gamesgamesgamesgames.game", game_data)
    game:save()
    uri, cid = game._uri, game._cid
  else
    -- Unverified author: the instance publishes on their behalf into the
    -- Pentaract repo. That needs a linked-repo grant — HappyView can only
    -- write to a repo it holds a session for, and the caller's credentials
    -- are not credentials for someone else's repo.
    local pentaract = linked_repos.get(PENTARACT_DID)
    if not pentaract then
      error("cannot publish on your behalf: no linked repo grant for " .. PENTARACT_DID ..
            " — an admin must link that account")
    end

    game_data["$type"] = "games.gamesgamesgamesgames.game"
    local result = pentaract:create_record({
      collection = "games.gamesgamesgamesgames.game",
      record = game_data,
    })
    uri, cid = result.uri, result.cid
  end

  -- game.lua's index hook gives a game with no slug one from its name, and it
  -- can run before this point. The game is brand new, so any slug it already
  -- has came from the hook. An explicit slug replaces it. A generated slug
  -- follows the hook's rule: a slug another game holds gets a numeric suffix
  -- rather than being repointed, and a slug this game already holds is kept.
  if input.slug then
    local hook_slug = db.raw("SELECT slug FROM slugs WHERE uri = $1 ORDER BY length(slug), slug LIMIT 1", { uri })
    db.raw("INSERT INTO slugs (slug, uri) VALUES ($1, $2) ON CONFLICT (slug) DO UPDATE SET uri = $2",
      {input.slug, uri})
    if hook_slug and #hook_slug > 0 then
      db.raw("DELETE FROM slugs WHERE uri = $1 AND slug <> $2", { uri, input.slug })
    end
  else
    -- The game exists now, so a slug failure must not fail the call: a retry
    -- would create the game a second time. The index hook assigns one later.
    local slug_ok, slug_err = pcall(assign_generated_slug, uri, input.name)
    if not slug_ok then
      log("warning: failed to assign a slug to " .. uri .. ": " .. tostring(slug_err))
    end
  end

  return { uri = uri, cid = cid }
end
