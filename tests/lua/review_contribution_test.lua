package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/reviewContribution.lua"

local ADMIN = "did:plc:admin"
local PENTARACT = "did:web:pentaract"
local SCRAPER = "did:plc:scraper"
local PENTARACT_GAME = "at://did:web:pentaract/games.gamesgamesgamesgames.game/9"
local OWNED_GAME = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"

local function run_handler(options)
  options = options or {}
  local state = { created = {}, put_records = {} }

  local contribution_uri = options.contribution_uri
    or ("at://" .. (options.contributor or "did:plc:contributor") .. "/games.gamesgamesgamesgames.contribution/1")

  local sandbox = {
    caller_did = options.caller_did or ADMIN,
    input = { contribution = { uri = contribution_uri, cid = "bafy1" }, status = options.status or "approved" },
    env = { PENTARACT_DID = PENTARACT, ADMIN_DIDS = ADMIN },
    db = {
      raw = function(sql, bind)
        if sql:find("contributionReview", 1, true) then return {} end
        if sql:find("contributionOwnerDecision", 1, true) then
          state.decision_bind = bind
          return options.owner_decision and { { uri = options.owner_decision } } or {}
        end
        if sql:find("FROM slugs", 1, true) then return {} end
        if sql:find("INSERT INTO slugs", 1, true) then return {} end
        if sql:find("WHERE uri = $1 LIMIT 1", 1, true) then
          if bind and bind[1] == contribution_uri then
            return { { uri = contribution_uri, cid = "bafy1",
                       -- applicationType is here because a newGame contribution is
                       -- rejected without one, and this fixture covers that case too.
                       record = { subject = options.subject, contributionType = "correction",
                                  changes = { name = "Proposed", applicationType = "game" } } } }
          end
          return { { cid = "bafygame", record = { name = "Stored" } } }
        end
        return {}
      end,
    },
    json = { decode = function(value) return value end },
    now = function() return "2026-10-01T00:00:00Z" end,
    log = function() end,
    linked_repos = {
      get = function()
        return {
          did = PENTARACT,
          create_record = function(_, request)
            table.insert(state.created, request)
            return { uri = "at://" .. PENTARACT .. "/" .. request.collection .. "/new", cid = "bafynew" }
          end,
          put_record = function(_, request) table.insert(state.put_records, request) end,
        }
      end,
    },
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local ok, err = pcall(sandbox.handle)

  local created_by_collection = {}
  for _, request in ipairs(state.created) do
    created_by_collection[request.collection] = (created_by_collection[request.collection] or 0) + 1
  end
  return { ok = ok, err = err, created = created_by_collection, puts = state.put_records, decision_bind = state.decision_bind }
end

local PATCH = "games.gamesgamesgamesgames.contributionPatch"
local GAME = "games.gamesgamesgamesgames.game"

t.test("an approved contribution to a Pentaract game applies immediately, from anyone", function()
  -- The catalogue has no owner to accept a patch. Applying now also keeps the
  -- auto-accept rule that newer catalogue data lands over older approvals: a
  -- patch would overlay the game forever and outrank every later IGDB update.
  for _, contributor in ipairs({ SCRAPER, "did:plc:someone" }) do
    local result = run_handler({ contributor = contributor, subject = PENTARACT_GAME })
    t.eq(result.ok, true, contributor .. ": handled")
    t.eq(#result.puts > 0, true, contributor .. ": the game was written")
    t.eq(result.created[PATCH], nil, contributor .. ": no patch")
  end
end)

t.test("a contribution to an owned game becomes a patch for either submitter", function()
  local user = run_handler({ contributor = "did:plc:someone", subject = OWNED_GAME })
  t.eq(user.created[PATCH], 1, "user patch")

  local scraper = run_handler({ contributor = SCRAPER, subject = OWNED_GAME })
  t.eq(scraper.created[PATCH], 1, "scraper patch — ownership outranks trust")
end)

t.test("a newGame contribution applies immediately for either submitter", function()
  -- There is no subject, so there is no record to overlay and nothing to make
  -- provisional. The game is created in the Pentaract repo and is subject to
  -- the ordinary flow from then on.
  local user = run_handler({ contributor = "did:plc:someone", subject = nil })
  t.eq(user.created[GAME], 1, "user: game created")
  t.eq(user.created[PATCH], nil, "user: no patch")

  local scraper = run_handler({ contributor = SCRAPER, subject = nil })
  t.eq(scraper.created[GAME], 1, "scraper: game created")
  t.eq(scraper.created[PATCH], nil, "scraper: no patch")
end)

t.test("a denial creates neither a patch nor a write", function()
  local result = run_handler({ contributor = SCRAPER, subject = PENTARACT_GAME, status = "denied" })
  t.eq(#result.puts, 0, "nothing written")
  t.eq(result.created[PATCH], nil, "no patch")
end)

t.test("an approval is refused once the owner has decided", function()
  -- Without this a declined change would go public through the patch, and the
  -- owner could not decline it again.
  local result = run_handler({
    contributor = "did:plc:someone", subject = OWNED_GAME,
    owner_decision = "at://did:plc:owner/games.gamesgamesgamesgames.contributionOwnerDecision/1",
  })
  t.eq(result.ok, false, "refused")
  t.truthy(tostring(result.err):find("already decided", 1, true), "says why")
  t.eq(result.created[PATCH], nil, "no patch")
  t.eq(result.decision_bind[1], "did:plc:owner", "only the owner's own repo counts")
end)

t.test("a denial is still recorded after the owner has decided", function()
  local result = run_handler({
    contributor = "did:plc:someone", subject = OWNED_GAME, status = "denied",
    owner_decision = "at://did:plc:owner/games.gamesgamesgamesgames.contributionOwnerDecision/1",
  })
  t.eq(result.ok, true, "recorded")
  t.eq(result.created[PATCH], nil, "no patch")
end)

t.report()
