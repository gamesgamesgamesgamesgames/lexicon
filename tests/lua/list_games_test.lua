package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

local HANDLER = "src/scripts/games/gamesgamesgamesgames/listGames.lua"
local FIRST = "at://did:plc:owner/games.gamesgamesgamesgames.game/1"
local SECOND = "at://did:plc:owner/games.gamesgamesgamesgames.game/2"
local PENTARACT_DID = "did:web:pentaract"

local function run_handler(options)
  local patch_queries = 0
  local patch_calls = {}

  local sandbox = {
    params = options.params or {},
    caller_did = options.caller_did,
    env = { PENTARACT_DID = PENTARACT_DID },
    db = {
      raw = function(sql, bind)
        if sql:find("contributionPatch", 1, true) then
          patch_queries = patch_queries + 1
          table.insert(patch_calls, { sql = sql, bind = bind })
          -- Model the repo filter, so a patch from the wrong repo is actually
          -- excluded here rather than taken on trust: a stub that returned every
          -- row would pass with `did = $1` deleted from the query.
          local matched = {}
          for _, row in ipairs(options.patch_rows or {}) do
            if (row.did or PENTARACT_DID) == bind[1] then
              table.insert(matched, row)
            end
          end
          return matched
        end
        if sql:find("FROM slugs", 1, true) then
          return {}
        end
        return options.game_rows or {}
      end,
    },
    json = { decode = function(value) return value end },
    toarray = function(value) return value end,
  }
  setmetatable(sandbox, { __index = _G })

  local chunk = assert(loadfile(HANDLER, "t", sandbox))
  chunk()
  local result = sandbox.handle()
  return result, patch_queries, patch_calls
end

local function patch(subject, changes, did)
  return {
    did = did,
    uri = "at://" .. (did or PENTARACT_DID) .. "/games.gamesgamesgamesgames.contributionPatch/1",
    record = { subject = subject, createdAt = "2026-01-01T00:00:00Z", changes = changes },
  }
end

t.test("listed games carry overlaid values", function()
  local result = run_handler({
    game_rows = {
      { uri = FIRST, record = { name = "Stored one", summary = "One" } },
      { uri = SECOND, record = { name = "Stored two", summary = "Two" } },
    },
    patch_rows = { patch(SECOND, { name = "Patched two" }) },
  })

  t.eq(result.games[1].name, "Stored one", "unpatched row")
  t.eq(result.games[2].name, "Patched two", "patched row")
  t.eq(result.games[2].summary, "Two", "unpatched field on a patched row")
end)

t.test("one patch query serves the whole page", function()
  local _, patch_queries = run_handler({
    game_rows = {
      { uri = FIRST, record = { name = "One" } },
      { uri = SECOND, record = { name = "Two" } },
    },
  })
  t.eq(patch_queries, 1, "a single query regardless of page size")
end)

t.test("the one query names every uri on the page and only the Pentaract repo", function()
  local _, _, patch_calls = run_handler({
    game_rows = {
      { uri = FIRST, record = { name = "One" } },
      { uri = SECOND, record = { name = "Two" } },
    },
  })

  local call = patch_calls[1]
  t.truthy(call.sql:find("did = $1", 1, true), "the query carries the repo filter")
  t.eq(call.bind[1], PENTARACT_DID, "bound to the Pentaract DID")
  t.eq(call.bind[2], FIRST, "first page uri bound")
  t.eq(call.bind[3], SECOND, "second page uri bound")
  t.eq(#call.bind, 3, "nothing else bound")
end)

t.test("an empty page issues no patch query", function()
  local _, patch_queries = run_handler({ game_rows = {} })
  t.eq(patch_queries, 0, "nothing to look up")
end)

t.test("a patch from a repo other than Pentaract is ignored", function()
  local result = run_handler({
    game_rows = { { uri = FIRST, record = { name = "Stored one" } } },
    patch_rows = { patch(FIRST, { name = "Forged" }, "did:plc:attacker") },
  })
  t.eq(result.games[1].name, "Stored one", "forged patch has no effect")
end)

t.test("a patch naming a game outside the page changes nothing", function()
  local result = run_handler({
    game_rows = { { uri = FIRST, record = { name = "Stored one" } } },
    patch_rows = { patch(SECOND, { name = "Patched two" }) },
  })
  t.eq(result.games[1].name, "Stored one", "only its own subject is patched")
end)

t.test("a page larger than the limit still issues one query, for the page only", function()
  local rows = {}
  for i = 1, 25 do
    table.insert(rows, {
      uri = "at://did:plc:owner/games.gamesgamesgamesgames.game/" .. i,
      record = { name = "Game " .. i },
    })
  end

  local result, patch_queries, patch_calls = run_handler({ game_rows = rows })

  t.eq(#result.games, 20, "trimmed to the default limit")
  t.eq(patch_queries, 1, "still one query")
  t.eq(#patch_calls[1].bind, 21, "the Pentaract DID plus the 20 uris actually returned")
  t.truthy(result.cursor, "and the extra row became a cursor")
end)

t.test("a full page of 100 is still one query with 100 placeholders", function()
  -- The two-row fixture cannot tell a single query from a per-row one at the
  -- size this path actually runs at. 100 is the handler's own ceiling.
  local rows = {}
  for i = 1, 101 do
    table.insert(rows, {
      uri = "at://did:plc:owner/games.gamesgamesgamesgames.game/" .. i,
      record = { name = "Game " .. i },
    })
  end

  local result, patch_queries, patch_calls = run_handler({
    params = { limit = 100 },
    game_rows = rows,
  })

  t.eq(#result.games, 100, "a full page")
  t.eq(patch_queries, 1, "one query for a hundred games")

  local call = patch_calls[1]
  t.eq(#call.bind, 101, "the Pentaract DID plus 100 uris")
  t.eq(call.bind[2], "at://did:plc:owner/games.gamesgamesgamesgames.game/1", "first uri bound")
  t.eq(call.bind[101], "at://did:plc:owner/games.gamesgamesgamesgames.game/100", "hundredth uri bound")

  -- Count the placeholders in the IN list itself, not just the bind array: a
  -- query that bound 100 values but listed fewer would silently drop games.
  local in_list = call.sql:match("IN %((.-)%)")
  t.truthy(in_list, "the query has an IN list")
  local placeholders = 0
  for _ in in_list:gmatch("%$%d+") do
    placeholders = placeholders + 1
  end
  t.eq(placeholders, 100, "one placeholder per uri on the page")
  t.truthy(in_list:find("$101", 1, true), "up to the last bind")
end)

t.test("the overlay does not write back into the decoded row", function()
  -- The rows come from json.decode, but the summary view must not be built by
  -- editing them: anything that later reads a row expects the stored values.
  local stored = { name = "Stored two", summary = "Two" }
  run_handler({
    game_rows = {
      { uri = FIRST, record = { name = "Stored one" } },
      { uri = SECOND, record = stored },
    },
    patch_rows = { patch(SECOND, { name = "Patched two" }) },
  })
  t.eq(stored.name, "Stored two", "the decoded record was not mutated")
end)

t.report()
