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
scripts_deployed=0
deleted=0
scripts_deleted=0

# Collect the set of NSIDs present in the repo
declare -A repo_nsids

# Track script trigger IDs deployed this run
declare -A repo_script_ids

# Parse changed files filter (optional)
declare -A changed_filter=()
filter_enabled=false
if [[ -n "${CHANGED_FILES:-}" && "$CHANGED_FILES" != "[]" ]]; then
  filter_enabled=true
  while IFS= read -r cf; do
    [[ -n "$cf" ]] && changed_filter["$cf"]=1
  done < <(echo "$CHANGED_FILES" | jq -r '.[]')
  if [[ -n "${changed_filter['happyview.json']+_}" ]]; then
    filter_enabled=false
    echo "happyview.json changed — deploying all"
  else
    echo "Filtering to ${#changed_filter[@]} changed file(s)"
  fi
fi

# Process each JSON file under lexicons/
while IFS= read -r json_file; do
  # Extract the NSID and type from the JSON
  nsid=$(jq -r '.id // empty' "$json_file")
  lexicon_type=$(jq -r '.defs.main.type // empty' "$json_file")

  if [[ -z "$nsid" ]]; then
    echo "SKIP: $json_file (missing id)"
    continue
  fi

  repo_nsids["$nsid"]=1

  # Determine corresponding Lua script path and trigger ID
  rel_path="${json_file#$LEXICONS_DIR/}"
  lua_file="$LUA_DIR/${rel_path%.json}.lua"
  trigger_id=""
  if [[ -n "$lexicon_type" && -f "$lua_file" ]]; then
    case "$lexicon_type" in
      query)      trigger_id="xrpc.query:$nsid" ;;
      procedure)  trigger_id="xrpc.procedure:$nsid" ;;
      record)     trigger_id="record.index:$nsid" ;;
    esac
    [[ -n "$trigger_id" ]] && repo_script_ids["$trigger_id"]=1
  fi

  # Skip unchanged files if filtering (still tracked above for cleanup)
  if $filter_enabled; then
    dorny_json="lexicons/$rel_path"
    dorny_lua="lua/${rel_path%.json}.lua"
    if [[ -z "${changed_filter[$dorny_json]+_}" ]] && [[ -z "${changed_filter[$dorny_lua]+_}" ]]; then
      continue
    fi
  fi

  # Look up manifest entry for target_collection
  target_collection=$(jq -r --arg nsid "$nsid" '.[$nsid].target_collection // empty' "$MANIFEST")

  # Read the full lexicon JSON
  lexicon_json=$(cat "$json_file")

  # Build the lexicon request body
  body=$(jq -n \
    --argjson lexicon_json "$lexicon_json" \
    --arg target_collection "$target_collection" \
    '{
      lexicon_json: $lexicon_json,
      backfill: true
    }
    + (if $target_collection != "" then {target_collection: $target_collection} else {} end)'
  )

  # POST lexicon to HappyView
  response=$(mktemp)
  http_code=$(curl -s -o "$response" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$HAPPYVIEW_URL/hv/admin/lexicons")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "OK: $nsid (${lexicon_type:-defs}) → HTTP $http_code"
    deployed=$((deployed + 1))
  else
    echo "FAIL: $nsid (${lexicon_type:-defs}) → HTTP $http_code" >&2
    cat "$response" >&2; echo >&2
    errors=$((errors + 1))
  fi
  rm -f "$response"

  # Upload the Lua script if it exists
  if [[ -n "$trigger_id" ]]; then
    lua_body=$(cat "$lua_file")

    script_payload=$(jq -n \
      --arg id "$trigger_id" \
      --arg body "$lua_body" \
      '{
        id: $id,
        script_type: "lua",
        body: $body
      }')

    script_response=$(mktemp)
    script_code=$(curl -s -o "$script_response" -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$script_payload" \
      "$HAPPYVIEW_URL/hv/admin/scripts")

    if [[ "$script_code" -ge 200 && "$script_code" -lt 300 ]]; then
      echo "  SCRIPT OK: $trigger_id → HTTP $script_code"
      scripts_deployed=$((scripts_deployed + 1))
    else
      echo "  SCRIPT FAIL: $trigger_id → HTTP $script_code" >&2
      cat "$script_response" >&2; echo >&2
      errors=$((errors + 1))
    fi
    rm -f "$script_response"
  fi

done < <(find "$LEXICONS_DIR" -name '*.json' -type f | sort)

# ---------------------------------------------------------------------------
# Remove lexicons from HappyView that no longer exist in the repo
# ---------------------------------------------------------------------------

remote_nsids=$(curl -s \
  -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
  "$HAPPYVIEW_URL/hv/admin/lexicons" \
  | jq -r '.[].id // empty')

for remote_nsid in $remote_nsids; do
  if [[ -z "${repo_nsids[$remote_nsid]+_}" ]]; then
    del_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X DELETE \
      -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
      "$HAPPYVIEW_URL/hv/admin/lexicons/$remote_nsid")

    if [[ "$del_code" -ge 200 && "$del_code" -lt 300 ]] || [[ "$del_code" == "404" ]]; then
      echo "DELETED: $remote_nsid → HTTP $del_code"
      deleted=$((deleted + 1))
    else
      echo "DELETE FAIL: $remote_nsid → HTTP $del_code" >&2
      errors=$((errors + 1))
    fi
  fi
done

# ---------------------------------------------------------------------------
# Remove scripts from HappyView that no longer exist in the repo
# ---------------------------------------------------------------------------

remote_scripts=$(curl -s \
  -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
  "$HAPPYVIEW_URL/hv/admin/scripts" \
  | jq -r '.[].id // empty')

for remote_script_id in $remote_scripts; do
  if [[ -z "${repo_script_ids[$remote_script_id]+_}" ]]; then
    encoded_id=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$remote_script_id', safe=''))")

    del_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X DELETE \
      -H "Authorization: Bearer $HAPPYVIEW_API_KEY" \
      "$HAPPYVIEW_URL/hv/admin/scripts/$encoded_id")

    if [[ "$del_code" -ge 200 && "$del_code" -lt 300 ]] || [[ "$del_code" == "404" ]]; then
      echo "SCRIPT DELETED: $remote_script_id → HTTP $del_code"
      scripts_deleted=$((scripts_deleted + 1))
    else
      echo "SCRIPT DELETE FAIL: $remote_script_id → HTTP $del_code" >&2
      errors=$((errors + 1))
    fi
  fi
done

echo ""
echo "Lexicons deployed: $deployed, deleted: $deleted"
echo "Scripts deployed: $scripts_deployed, deleted: $scripts_deleted"
echo "Errors: $errors"

if [[ $errors -gt 0 ]]; then
  exit 1
fi
