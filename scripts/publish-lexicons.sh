#!/usr/bin/env bash
set -euo pipefail

# Publish lexicon schemas to an atproto repo via com.atproto.repo.applyWrites.
#
# Usage: publish-lexicons.sh <lexicon-dir>
#
# Required environment variables:
#   PUBLISH_HANDLE   — handle of the account to publish to
#   PUBLISH_PASSWORD — app password for authentication

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <lexicon-dir>" >&2
  echo "Required env vars: PUBLISH_HANDLE, PUBLISH_PASSWORD" >&2
  exit 1
fi

LEXICON_DIR="$1"

if [[ -z "${PUBLISH_HANDLE:-}" ]]; then
  echo "ERROR: PUBLISH_HANDLE is not set" >&2
  exit 1
fi
if [[ -z "${PUBLISH_PASSWORD:-}" ]]; then
  echo "ERROR: PUBLISH_PASSWORD is not set" >&2
  exit 1
fi

if [[ ! -d "$LEXICON_DIR" ]]; then
  echo "ERROR: $LEXICON_DIR is not a directory" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse changed files filter (optional)
# ---------------------------------------------------------------------------

declare -A changed_filter=()
filter_enabled=false
if [[ -n "${CHANGED_FILES:-}" && "$CHANGED_FILES" != "[]" ]]; then
  filter_enabled=true
  while IFS= read -r cf; do
    [[ -n "$cf" ]] && changed_filter["$cf"]=1
  done < <(echo "$CHANGED_FILES" | jq -r '.[]')
  echo "Filtering to ${#changed_filter[@]} changed file(s)"
fi

# ---------------------------------------------------------------------------
# Resolve handle → DID → PDS
# ---------------------------------------------------------------------------

echo "Resolving $PUBLISH_HANDLE..."

resolve_resp=$(curl -s "https://plc.directory/$PUBLISH_HANDLE" 2>/dev/null || true)
did=$(echo "$resolve_resp" | jq -r '.id // empty' 2>/dev/null || true)

if [[ -z "$did" ]]; then
  resolve_resp=$(curl -s "https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=$PUBLISH_HANDLE")
  did=$(echo "$resolve_resp" | jq -r '.did // empty')
fi

if [[ -z "$did" ]]; then
  dns_did=$(dig +short TXT "_atproto.$PUBLISH_HANDLE" 2>/dev/null | tr -d '"' | grep -oP 'did=\K.+' || true)
  did="$dns_did"
fi

if [[ -z "$did" ]]; then
  echo "ERROR: Could not resolve handle $PUBLISH_HANDLE to a DID" >&2
  exit 1
fi

echo "Resolved DID: $did"

# Resolve DID document to find PDS endpoint
if [[ "$did" == did:plc:* ]]; then
  did_doc=$(curl -s "https://plc.directory/$did")
elif [[ "$did" == did:web:* ]]; then
  web_domain="${did#did:web:}"
  did_doc=$(curl -s "https://$web_domain/.well-known/did.json")
else
  echo "ERROR: Unsupported DID method: $did" >&2
  exit 1
fi

pds=$(echo "$did_doc" | jq -r '.service[]? | select(.id == "#atproto_pds") | .serviceEndpoint // empty')

if [[ -z "$pds" ]]; then
  echo "ERROR: Could not find PDS endpoint for $did" >&2
  exit 1
fi

pds="${pds%/}"
echo "PDS: $pds"

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------

echo "Authenticating as $PUBLISH_HANDLE..."

session=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$PUBLISH_HANDLE" --arg pw "$PUBLISH_PASSWORD" '{identifier: $id, password: $pw}')" \
  "$pds/xrpc/com.atproto.server.createSession")

token=$(echo "$session" | jq -r '.accessJwt // empty')

if [[ -z "$token" ]]; then
  echo "ERROR: Authentication failed" >&2
  echo "$session" | jq . >&2
  exit 1
fi

echo "Authenticated: $did → $pds"

# ---------------------------------------------------------------------------
# Collect existing lexicon record rkeys (paginated)
# ---------------------------------------------------------------------------

declare -A existing_rkeys=()
cursor=""

while true; do
  url="${pds}/xrpc/com.atproto.repo.listRecords?repo=${did}&collection=com.atproto.lexicon.schema&limit=100"
  if [[ -n "$cursor" ]]; then
    url="${url}&cursor=${cursor}"
  fi

  page=$(curl -s -H "Authorization: Bearer $token" "$url")

  while IFS= read -r rkey; do
    [[ -n "$rkey" ]] && existing_rkeys["$rkey"]=1
  done < <(echo "$page" | jq -r '.records[]?.uri // empty' | grep -oE '[^/]+$' || true)

  cursor=$(echo "$page" | jq -r '.cursor // empty')
  [[ -z "$cursor" ]] && break
done

echo "Found ${#existing_rkeys[@]} existing lexicon record(s) in repo"

# ---------------------------------------------------------------------------
# Build writes array from lexicon files
# ---------------------------------------------------------------------------

creates=0
updates=0
tmp_writes=$(mktemp)
echo '[]' > "$tmp_writes"

while IFS= read -r json_file; do
  nsid=$(jq -r '.id // empty' "$json_file")
  if [[ -z "$nsid" ]]; then
    echo "SKIP: $json_file (missing id)"
    continue
  fi

  if $filter_enabled; then
    rel="${json_file#./}"
    if [[ -z "${changed_filter[$rel]+_}" ]]; then
      continue
    fi
  fi

  if [[ -n "${existing_rkeys[$nsid]+_}" ]]; then
    write_type="com.atproto.repo.applyWrites#update"
    updates=$((updates + 1))
  else
    write_type="com.atproto.repo.applyWrites#create"
    creates=$((creates + 1))
  fi

  jq --arg type "$write_type" \
     --arg rkey "$nsid" \
     --slurpfile record "$json_file" \
     '. + [{
       "$type": $type,
       "collection": "com.atproto.lexicon.schema",
       "rkey": $rkey,
       "value": $record[0]
     }]' "$tmp_writes" > "$tmp_writes.new"
  mv "$tmp_writes.new" "$tmp_writes"

done < <(find "$LEXICON_DIR" -name '*.json' -type f | sort)

total=$((creates + updates))
echo "Prepared $total write(s): $creates create(s), $updates update(s)"

if [[ $total -eq 0 ]]; then
  echo "Nothing to publish"
  rm -f "$tmp_writes"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply writes in batches of 200 (PDS limit)
# ---------------------------------------------------------------------------

batch_size=50
batches=$(( (total + batch_size - 1) / batch_size ))

tmp_request=$(mktemp)

for ((i = 0; i < batches; i++)); do
  offset=$((i * batch_size))

  jq --argjson offset "$offset" \
     --argjson limit "$batch_size" \
     --arg repo "$did" \
     '{repo: $repo, writes: .[$offset:$offset + $limit]}' "$tmp_writes" > "$tmp_request"

  batch_count=$(jq '.writes | length' "$tmp_request")

  if [[ $batches -gt 1 ]]; then
    echo "Publishing batch $((i + 1))/$batches ($batch_count writes)..."
  else
    echo "Publishing $batch_count lexicon(s)..."
  fi

  response=$(mktemp)
  resp_headers=$(mktemp)
  max_retries=5
  retry=0
  backoff=5

  while true; do
    http_code=$(curl -s -o "$response" -D "$resp_headers" -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d @"$tmp_request" \
      "${pds}/xrpc/com.atproto.repo.applyWrites")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      echo "OK: batch $((i + 1)) → HTTP $http_code"
      break
    elif [[ "$http_code" == "429" && $retry -lt $max_retries ]]; then
      retry=$((retry + 1))
      retry_after=$(grep -i '^retry-after:' "$resp_headers" | head -1 | tr -d '\r' | awk '{print $2}' || true)
      wait_time="${retry_after:-$backoff}"
      echo "  Rate limited, retrying in ${wait_time}s (attempt $retry/$max_retries)..."
      sleep "$wait_time"
      backoff=$((backoff * 2))
    else
      echo "FAIL: batch $((i + 1)) → HTTP $http_code" >&2
      cat "$response" >&2; echo >&2
      rm -f "$tmp_writes" "$tmp_request" "$response" "$resp_headers"
      exit 1
    fi
  done

  rm -f "$response" "$resp_headers"
done

rm -f "$tmp_request"

rm -f "$tmp_writes"
echo ""
echo "Published $total lexicon(s) to $PUBLISH_HANDLE ($did)"
