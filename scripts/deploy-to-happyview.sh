#!/usr/bin/env bash
set -euo pipefail

# Deploy lexicon JSON and Lua scripts to HappyView's admin API.
#
# Required environment variables:
#   HAPPYVIEW_URL   — base URL of the HappyView instance (e.g., https://happyview.example.com)
#   HAPPYVIEW_API_KEY — an hv_-prefixed API key for admin auth

if [[ -z "${HAPPYVIEW_URL:-}" ]]; then
  echo "ERROR: HAPPYVIEW_URL is not set" >&2
  exit 1
fi
if [[ -z "${HAPPYVIEW_API_KEY:-}" ]]; then
  echo "ERROR: HAPPYVIEW_API_KEY is not set" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/happyview.json"
LEXICONS_DIR="$REPO_ROOT/lexicons"
LUA_DIR="$REPO_ROOT/lua"

HAPPYVIEW_URL="${HAPPYVIEW_URL%/}"

errors=0
deployed=0

# Process each JSON file under lexicons/
while IFS= read -r json_file; do
  # Extract the NSID and type from the JSON
  nsid=$(jq -r '.id // empty' "$json_file")
  lexicon_type=$(jq -r '.defs.main.type // empty' "$json_file")

  if [[ -z "$nsid" ]]; then
    echo "SKIP: $json_file (missing id)"
    continue
  fi

  # Compute the Lua file path using the same relative structure
  rel_path="${json_file#$LEXICONS_DIR/}"
  lua_file="$LUA_DIR/${rel_path%.json}.lua"

  # Read the Lua script if it exists (only for lexicons with a main type)
  script=""
  index_hook=""
  if [[ -n "$lexicon_type" && -f "$lua_file" ]]; then
    case "$lexicon_type" in
      query|procedure)
        script=$(cat "$lua_file")
        ;;
      record)
        index_hook=$(cat "$lua_file")
        ;;
    esac
  fi

  # Look up manifest entry for target_collection and action
  target_collection=$(jq -r --arg nsid "$nsid" '.[$nsid].target_collection // empty' "$MANIFEST")
  action=$(jq -r --arg nsid "$nsid" '.[$nsid].action // empty' "$MANIFEST")

  # Read the full lexicon JSON
  lexicon_json=$(cat "$json_file")

  # Build the request body
  body=$(jq -n \
    --argjson lexicon_json "$lexicon_json" \
    --arg target_collection "$target_collection" \
    --arg action "$action" \
    --arg script "$script" \
    --arg index_hook "$index_hook" \
    '{
      lexicon_json: $lexicon_json,
      backfill: true
    }
    + (if $target_collection != "" then {target_collection: $target_collection} else {} end)
    + (if $action != "" then {action: $action} else {} end)
    + (if $script != "" then {script: $script} else {} end)
    + (if $index_hook != "" then {index_hook: $index_hook} else {} end)'
  )

  # POST to HappyView
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$HAPPYVIEW_URL/admin/lexicons")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "OK: $nsid (${lexicon_type:-defs}) → HTTP $http_code"
    deployed=$((deployed + 1))
  else
    echo "FAIL: $nsid (${lexicon_type:-defs}) → HTTP $http_code" >&2
    errors=$((errors + 1))
  fi

done < <(find "$LEXICONS_DIR" -name '*.json' -type f | sort)

echo ""
echo "Deployed: $deployed, Failed: $errors"

if [[ $errors -gt 0 ]]; then
  exit 1
fi
