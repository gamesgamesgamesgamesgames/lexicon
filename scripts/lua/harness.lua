-- Minimal test harness for the inlineable sources in src/shared/.
--
-- Those files are chunks of declarations with no `return`, because a generator
-- pastes them into handlers verbatim. To test one, the harness appends a return
-- of the names it needs and loads the chunk with a stub environment, so `db`,
-- `json` and `env` can be faked.
--
-- Run from the repo root: `bun run test:lua`.

local M = {}

local checks = 0
local failures = {}
local current = "<no test>"

local function fail(message)
  table.insert(failures, current .. ": " .. message)
end

local function render(value)
  if type(value) == "table" then
    local parts = {}
    for k, v in pairs(value) do
      table.insert(parts, tostring(k) .. "=" .. render(v))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

--- Load an inlineable shared source and return the names it declares.
function M.load_shared(path, exports, env)
  local file = assert(io.open(path, "r"), "cannot open " .. path)
  local source = file:read("*a")
  file:close()

  local returns = {}
  for _, name in ipairs(exports) do
    table.insert(returns, name .. " = " .. name)
  end
  source = source .. "\nreturn { " .. table.concat(returns, ", ") .. " }\n"

  -- Copied, not adopted: attaching the metatable to the caller's own table
  -- would leave `__index = _G` on a stub the test still wants to inspect, and
  -- would break a second load_shared call that reuses it.
  local sandbox = {}
  for key, value in pairs(env or {}) do
    sandbox[key] = value
  end

  -- `__index = _G` so the chunk still sees ipairs, table, string and friends.
  setmetatable(sandbox, { __index = _G })
  local chunk = assert(load(source, "@" .. path, "t", sandbox))
  return chunk()
end

function M.test(name, fn)
  current = name
  local ok, err = pcall(fn)
  if not ok then
    fail("raised " .. tostring(err))
  end
end

function M.eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    fail((label or "eq") .. " — expected " .. render(expected) .. ", got " .. render(actual))
  end
end

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

function M.deep_eq(actual, expected, label)
  checks = checks + 1
  if not deep_equal(actual, expected) then
    fail((label or "deep_eq") .. " — expected " .. render(expected) .. ", got " .. render(actual))
  end
end

function M.truthy(value, label)
  checks = checks + 1
  if not value then
    fail((label or "truthy") .. " — expected a truthy value, got " .. render(value))
  end
end

function M.falsy(value, label)
  checks = checks + 1
  if value then
    fail((label or "falsy") .. " — expected a falsy value, got " .. render(value))
  end
end

--- Assert that `fn` raises, and that the message contains `substring`.
function M.raises(fn, substring, label)
  checks = checks + 1
  local ok, err = pcall(fn)
  if ok then
    fail((label or "raises") .. " — expected an error, none raised")
  elseif substring and not tostring(err):find(substring, 1, true) then
    fail((label or "raises") .. " — expected an error containing '" .. substring ..
         "', got '" .. tostring(err) .. "'")
  end
end

function M.report()
  if #failures == 0 then
    print(string.format("  ok — %d checks", checks))
    os.exit(0)
  end
  for _, message in ipairs(failures) do
    print("  FAIL " .. message)
  end
  print(string.format("  %d of %d checks failed", #failures, checks))
  os.exit(1)
end

return M
