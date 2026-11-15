#!/usr/bin/env bash
# Runs every tests/lua/*_test.lua. Must be run from the repo root, because the
# tests resolve src/shared/ and scripts/lua/ relatively.
set -uo pipefail

LUA_BIN="${LUA_BIN:-}"
if [ -z "$LUA_BIN" ]; then
  # CI installs lua5.4, so prefer it and match what CI will run. Homebrew's
  # lua@5.4 is keg-only and never lands on PATH, so probe it by full path too —
  # otherwise a machine with both runs 5.5 and nobody ever exercises CI's
  # interpreter locally.
  for candidate in \
    lua5.4 \
    /opt/homebrew/opt/lua@5.4/bin/lua5.4 \
    /usr/local/opt/lua@5.4/bin/lua5.4 \
    lua5.3 \
    lua
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      LUA_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$LUA_BIN" ]; then
  echo "no lua interpreter found (tried lua5.4, lua5.3, lua)" >&2
  exit 1
fi

"$LUA_BIN" -v >&2

shopt -s nullglob
test_files=(tests/lua/*_test.lua)

# No tests is a failure, not a pass. Without this, renaming or moving the test
# directory turns this command green while running nothing at all — and CI gates
# the deploy on it.
if [ ${#test_files[@]} -eq 0 ]; then
  echo "no tests found in tests/lua/ — expected at least one *_test.lua" >&2
  exit 1
fi

status=0
for test_file in "${test_files[@]}"; do
  echo "-- $test_file"
  if ! "$LUA_BIN" "$test_file"; then
    status=1
  fi
done

exit $status
