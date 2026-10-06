package.path = "scripts/lua/?.lua;" .. package.path
local t = require("harness")

-- A stand-in for a real shared source: declarations only, no return.
local FIXTURE = "tests/lua/fixtures/sample.lua"

t.test("load_shared returns the locals a chunk declares", function()
  local shared = t.load_shared(FIXTURE, { "DOUBLE", "double" })
  t.eq(shared.DOUBLE, 2, "constant")
  t.eq(shared.double(21), 42, "function")
end)

t.test("load_shared injects a stub environment", function()
  local shared = t.load_shared(FIXTURE, { "read_env" }, { env = { THING = "yes" } })
  t.eq(shared.read_env(), "yes", "env lookup goes through the sandbox")
end)

t.report()
