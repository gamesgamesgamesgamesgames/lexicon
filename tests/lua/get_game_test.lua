package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/getGame.lua"
local GAME_URI = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local PENTARACT_DID = "did:web:pentaract"

local function run_handler(options)
  local raw_calls = {}

  local sandbox = {
    params = options.params or {},
    caller_did = options.caller_did,
    env = { PENTARACT_DID = PENTARACT_DID, VERIFIER_DID = "" },
    db = {
      get = function(uri)
        if uri == GAME_URI then return options.game end
        return options.platforms and options.platforms[uri] or nil
      end,
      raw = function(sql, bind)
        table.insert(raw_calls, { sql = sql, bind = bind })
        if sql:find("contributionPatch", 1, true) then
          -- Model the repo filter the query is supposed to carry, so a test can
          -- publish a patch from the wrong repo and see it excluded. A stub that
          -- returned every row regardless of binds would pass just as happily
          -- with the `did = $1` clause deleted.
          local matched = {}
          for _, row in ipairs(options.patch_rows or {}) do
            if (row.did or PENTARACT_DID) == bind[1] then
              table.insert(matched, row)
            end
          end
          return matched
        end
        return {}
      end,
      backlinks = function() return { records = {} } end,
    },
    json = { decode = function(value) return value end },
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local result = sandbox.handle()
  result.raw_calls = raw_calls
  return result
end

local function patch(changes, did)
  return {
    did = did,
    uri = "at://" .. (did or PENTARACT_DID) .. "/games.gamesgamesgamesgames.contributionPatch/1",
    record = { subject = GAME_URI, createdAt = "2026-01-01T00:00:00Z", changes = changes },
  }
end

t.test("an unpatched game returns its stored values", function()
  local result = run_handler({
    params = { uri = GAME_URI },
    game = { uri = GAME_URI, name = "Stored", summary = "Stored summary" },
  })
  t.eq(result.game.name, "Stored", "name")
end)

t.test("a patched game returns the overlaid values", function()
  local result = run_handler({
    params = { uri = GAME_URI },
    game = { uri = GAME_URI, name = "Stored", summary = "Stored summary" },
    patch_rows = { patch({ name = "Patched" }) },
  })
  t.eq(result.game.name, "Patched", "overlaid name")
  t.eq(result.game.summary, "Stored summary", "unpatched field")
  t.eq(result.game.uri, GAME_URI, "uri is the stored record's")
end)

t.test("a patch from a repo other than Pentaract is ignored", function()
  -- happyview_records indexes the whole network: anyone can publish a patch
  -- record naming someone else's game.
  local result = run_handler({
    params = { uri = GAME_URI },
    game = { uri = GAME_URI, name = "Stored" },
    patch_rows = { patch({ name = "Forged" }, "did:plc:attacker") },
  })
  t.eq(result.game.name, "Stored", "forged patch has no effect")

  local patch_call = nil
  for _, call in ipairs(result.raw_calls) do
    if call.sql:find("contributionPatch", 1, true) then
      patch_call = call
    end
  end
  t.truthy(patch_call, "a patch query ran")
  t.truthy(patch_call.sql:find("did = $1", 1, true), "the query carries the repo filter")
  t.eq(patch_call.bind[1], PENTARACT_DID, "bound to the Pentaract DID")
end)

t.test("the overlay does not write back into the stored record", function()
  -- resolve_release_platforms fills release.platform in place. It must only
  -- ever see the overlay's own copy: db.get hands back the row HappyView
  -- holds, and the detail build is a read.
  local stored = {
    uri = GAME_URI,
    name = "Stored",
    releases = { { platformUri = "at://did:plc:p/games.gamesgamesgamesgames.platform/1" } },
  }
  local result = run_handler({
    params = { uri = GAME_URI },
    game = stored,
    platforms = { ["at://did:plc:p/games.gamesgamesgamesgames.platform/1"] = { name = "Switch" } },
  })

  t.eq(result.game.releases[1].platform, "Switch", "the view resolved the platform name")
  t.eq(stored.releases[1].platform, nil, "the stored record was left alone")
  t.eq(stored.name, "Stored", "and so was every other stored field")
end)

t.test("a patch that replaces releases leaves the stored releases alone", function()
  local stored = {
    uri = GAME_URI,
    name = "Stored",
    releases = { { platformUri = "at://did:plc:p/games.gamesgamesgamesgames.platform/1" } },
  }
  local result = run_handler({
    params = { uri = GAME_URI },
    game = stored,
    platforms = {
      ["at://did:plc:p/games.gamesgamesgamesgames.platform/1"] = { name = "Switch" },
      ["at://did:plc:p/games.gamesgamesgamesgames.platform/2"] = { name = "Steam Deck" },
    },
    patch_rows = {
      patch({ releases = { { platformUri = "at://did:plc:p/games.gamesgamesgamesgames.platform/2" } } }),
    },
  })

  t.eq(result.game.releases[1].platform, "Steam Deck", "the patched release resolved")
  t.eq(#stored.releases, 1, "the stored releases array is untouched")
  t.eq(stored.releases[1].platformUri, "at://did:plc:p/games.gamesgamesgamesgames.platform/1", "still the stored platform")
  t.eq(stored.releases[1].platform, nil, "and nothing was written into it")
end)

t.test("a missing game is still nil", function()
  local result = run_handler({ params = { uri = "at://did:plc:owner/games.gamesgamesgamesgames.game/missing" } })
  t.eq(result.game, nil, "nil game")
end)

t.report()
