#!/usr/bin/env bash
# Parse-checks each Lua file given, under every interpreter on this machine.
#
#   bash scripts/lua-check.sh src/scripts/games/gamesgamesgamesgames/game.lua
#
# Handlers are not loaded by the test suite, so nothing else would catch a file
# that parses under one Lua and not another — and the two here are deliberately
# different versions: CI runs 5.4, Homebrew's default `lua` is 5.5. A syntax
# difference between them would otherwise only surface at deploy.
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "usage: lua-check.sh <file.lua>..." >&2
  exit 1
fi

bins=()
for candidate in \
  lua5.4 \
  /opt/homebrew/opt/lua@5.4/bin/lua5.4 \
  /usr/local/opt/lua@5.4/bin/lua5.4 \
  lua5.3 \
  lua
do
  if command -v "$candidate" >/dev/null 2>&1; then
    # Same version twice tells us nothing; keep one of each.
    version=$("$candidate" -v 2>&1 | head -1)
    seen=0
    for already in "${bins[@]+"${bins[@]}"}"; do
      [ "${already#*|}" = "$version" ] && seen=1
    done
    [ "$seen" -eq 0 ] && bins+=("$candidate|$version")
  fi
done

if [ ${#bins[@]} -eq 0 ]; then
  echo "no lua interpreter found" >&2
  exit 1
fi

status=0
for entry in "${bins[@]}"; do
  bin="${entry%%|*}"
  echo "-- ${entry#*|}"
  for file in "$@"; do
    if "$bin" -e "assert(loadfile('$file'))" 2>/dev/null; then
      echo "   ok   $file"
    else
      echo "   FAIL $file"
      "$bin" -e "assert(loadfile('$file'))" 2>&1 | sed 's/^/        /'
      status=1
    fi
  done
done

exit $status
