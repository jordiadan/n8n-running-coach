#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$REPO_ROOT/.tmp/feedback-itest"
N8N_DATA_DIR="${N8N_DATA_DIR:-$TMP_DIR/n8n}"
export N8N_DATA_DIR

COMPOSE_FILE="$REPO_ROOT/docker-compose.itest.yml"
CREDS_FILE="$REPO_ROOT/tests/credentials/mongo.json"
PATCHED_JSON="$TMP_DIR/running-coach-feedback.itest.json"
EXECUTION_LOG="$TMP_DIR/execution.feedback.log"
EXECUTION_LOG_LATE="$TMP_DIR/execution.feedback.late.log"

N8N_HOST="localhost"
N8N_PORT="5678"
MOCK_HOST="localhost"
MOCK_PORT="1080"
NETWORK_NAME="integration_test_network"

WORKFLOW_NAME_DEFAULT="Running Coach Feedback Ingestion"
WORKFLOW_NAME="${WORKFLOW_NAME:-$WORKFLOW_NAME_DEFAULT}"
WORKFLOW_FILE="${WORKFLOW_FILE:-}"

COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE")

cleanup() {
  local exit_code=$?
  echo "🧹 Cleanup feedback itest (exit $exit_code)"
  if command -v docker >/dev/null 2>&1; then
    "${COMPOSE_CMD[@]}" logs --tail 120 || true
    "${COMPOSE_CMD[@]}" down -v || true
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
      docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -z "${KEEP_TMP:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
  exit $exit_code
}

trap cleanup EXIT
trap 'trap - EXIT; cleanup' INT TERM

require_tool() {
  local tool=$1
  command -v "$tool" >/dev/null 2>&1 || {
    echo "❌ Missing required tool: $tool"
    exit 1
  }
}

wait_for_service() {
  local name=$1
  local url=$2
  local attempts=${3:-30}
  local pause=${4:-2}
  local method="GET"

  if [[ "$name" == "MockServer" ]]; then
    method="PUT"
  fi

  echo "⏳ Waiting for $name at $url"
  for ((i=1; i<=attempts; i++)); do
    local response http_code
    response="$(curl -sS -X "$method" -w '\n%{http_code}' --max-time 5 "$url" 2>&1)" || true
    http_code="$(echo "$response" | tail -n1)"
    if [[ "$http_code" == "200" ]]; then
      echo "✅ $name ready"
      return 0
    fi
    echo "   Attempt $i/$attempts failed (HTTP $http_code)"
    sleep "$pause"
  done
  echo "❌ $name did not become ready"
  return 1
}

discover_workflow() {
  if [[ -n "$WORKFLOW_FILE" ]]; then
    WORKFLOW_FILE="$REPO_ROOT/$WORKFLOW_FILE"
    return
  fi

  echo "🔎 Looking for workflow named \"$WORKFLOW_NAME\""
  while IFS= read -r candidate; do
    if jq -e --arg name "$WORKFLOW_NAME" '.name? == $name' "$candidate" >/dev/null 2>&1; then
      WORKFLOW_FILE="$candidate"
      echo "   Found workflow: $WORKFLOW_FILE"
      return
    fi
  done < <(cd "$REPO_ROOT" && find workflows -maxdepth 1 -name '*.json' -print)

  echo "❌ Workflow \"$WORKFLOW_NAME\" not found"
  exit 1
}

seed_credentials() {
  echo "▶️  Seeding MongoDB credential"
  docker cp "$CREDS_FILE" "$CID:/home/node/mongo.json"
  if ! docker exec -u node "$CID" sh -lc "cd /home/node && n8n import:credentials --input mongo.json >/tmp/cred-import.log 2>&1"; then
    echo "❌ Unable to import credential via CLI"
    docker exec -u node "$CID" sh -lc "cat /tmp/cred-import.log" || true
    exit 1
  fi
  echo "✅ Credential imported"
}

patch_workflow() {
  local days_old=${1:-0}
  echo "▶️  Patching feedback workflow JSON"
  local js_mock_trigger js_mock_telegram

  js_mock_trigger=$(cat <<'EOF'
const daysOld = __DAYS_OLD__;
const nowMs = Date.now() - (daysOld * 86400000);
const runId = `itest-run-feedback-${daysOld}`;
return [{
  json: {
    callback_query: {
      data: `feedback|${runId}|done`,
      from: { id: 1, username: "itest" },
      message: {
        message_id: 12345 + daysOld,
        chat: { id: 987654, username: "itest" },
        date: Math.floor(nowMs / 1000)
      }
    }
  }
}];
EOF
)
  js_mock_trigger="${js_mock_trigger/__DAYS_OLD__/$days_old}"

  js_mock_telegram=$'return items.map(item => ({\n  json: {\n    ok: true,\n    chatId: item.json.chatId,\n    isLateResponse: item.json.isLateResponse,\n    type: item.json.type,\n    promptAgeDays: item.json.promptAgeDays\n  }\n}));'

  jq --arg js_trigger "$js_mock_trigger" --arg js_telegram "$js_mock_telegram" '
    .nodes |= map(
      if .name == "Telegram Feedback Trigger" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_trigger}
        | del(.credentials)
      elif .name == "Send Feedback Ack" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      else .
      end
    )
    | .nodes += [{
        "id": "itest-feedback-manual-trigger",
        "name": "When clicking ‘Execute workflow’",
        "type": "n8n-nodes-base.manualTrigger",
        "typeVersion": 1,
        "position": [-420, -200],
        "parameters": {}
      }]
    | .connections["When clicking ‘Execute workflow’"] = {
        "main": [[{
          "node": "Telegram Feedback Trigger",
          "type": "main",
          "index": 0
        }]]
      }
  ' "$WORKFLOW_FILE" > "$PATCHED_JSON"
}

import_patched_workflow() {
  docker cp "$PATCHED_JSON" "$CID:/home/node/itest.feedback.workflow.json"

  set +e
  import_output="$(docker exec -u node "$CID" sh -lc "cd /home/node && n8n import:workflow --input itest.feedback.workflow.json")"
  import_status=$?
  set -e

  if [[ "$import_status" -ne 0 ]]; then
    echo "❌ Feedback workflow import failed (exit $import_status)"
    echo "$import_output"
    exit "$import_status"
  fi
}

execute_workflow() {
  local log_file=$1
  local env_prefix=$2
  local timeout_cmd status

  timeout_cmd="$(command -v gtimeout || command -v timeout || true)"
  if [[ -n "$timeout_cmd" ]]; then
    set +e
    $timeout_cmd 90 docker exec -u node "$CID" sh -lc "cd /home/node && $env_prefix n8n execute --rawOutput --id $workflow_id" | tee "$log_file"
    status=${PIPESTATUS[0]}
    set -e
    if [[ "$status" -eq 124 || "$status" -eq 143 ]]; then
      echo "❌ Workflow execution timed out after 90s"
      exit 1
    fi
    if [[ "$status" -ne 0 ]]; then
      echo "❌ Workflow execution failed (exit $status)"
      exit "$status"
    fi
  else
    docker exec -u node "$CID" sh -lc "cd /home/node && $env_prefix n8n execute --rawOutput --id $workflow_id" | tee "$log_file"
  fi
}

verify_non_late_feedback() {
  echo "▶️  Verifying non-late feedback persistence"

  read -r session_key run_id < <(python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
text = re.sub(r'\x1B\[[0-9;]*[A-Za-z]', '', text)
decoder = json.JSONDecoder()
candidate = None
for match in re.finditer(r'\{', text):
    idx = match.start()
    try:
        obj, _ = decoder.raw_decode(text[idx:])
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and ("data" in obj or "resultData" in obj):
        candidate = obj
        break

if candidate is None:
    raise SystemExit("❌ Unable to find run data in execution log")

run_data = candidate.get("data", candidate).get("resultData", {}).get("runData", {})
parse_runs = run_data.get("Parse Feedback") or []
db_runs = run_data.get("Feedback Events DB") or []
ack_runs = run_data.get("Send Feedback Ack") or []

if not parse_runs:
    raise SystemExit("❌ Parse Feedback output not found")
if not db_runs:
    raise SystemExit("❌ Feedback Events DB should run for non-late feedback")
if not ack_runs:
    raise SystemExit("❌ Send Feedback Ack output not found")

payload = parse_runs[0].get("data", {}).get("main", [[{}]])[0][0].get("json", {})
if payload.get("isLateResponse") is not False:
    raise SystemExit("❌ Expected non-late feedback in first run")

session_key = str(payload.get("sessionKey", "")).strip()
run_id = str(payload.get("runId", "")).strip()
if not session_key or not run_id:
    raise SystemExit("❌ sessionKey/runId missing in Parse Feedback payload")

print(session_key, run_id)
PY
)

  [[ -n "$session_key" && -n "$run_id" ]] || { echo "❌ Missing session key/run id"; exit 1; }

  local mid mongo_payload
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  mongo_payload="$(docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" --eval "const doc = db.feedback_events.findOne({ sessionKey: '${session_key}' }); print(JSON.stringify(doc || {}));")"

  python3 - "$mongo_payload" "$run_id" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
run_id = sys.argv[2]
if not raw:
    raise SystemExit("❌ Empty mongo response for feedback document")

doc = json.loads(raw.splitlines()[-1])
if not isinstance(doc, dict) or not doc:
    raise SystemExit("❌ Feedback event was not persisted")
if str(doc.get("runId")) != run_id:
    raise SystemExit("❌ Persisted feedback runId mismatch")
if doc.get("type") != "done":
    raise SystemExit("❌ Persisted feedback type mismatch")

print("✅ Non-late feedback persisted")
PY
}

verify_late_feedback() {
  echo "▶️  Verifying late feedback is not persisted"

  local late_run_id
  late_run_id="$(python3 - "$EXECUTION_LOG_LATE" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
text = re.sub(r'\x1B\[[0-9;]*[A-Za-z]', '', text)
decoder = json.JSONDecoder()
candidate = None
for match in re.finditer(r'\{', text):
    idx = match.start()
    try:
        obj, _ = decoder.raw_decode(text[idx:])
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and ("data" in obj or "resultData" in obj):
        candidate = obj
        break

if candidate is None:
    raise SystemExit("❌ Unable to find run data in late execution log")

run_data = candidate.get("data", candidate).get("resultData", {}).get("runData", {})
parse_runs = run_data.get("Parse Feedback") or []
db_runs = run_data.get("Feedback Events DB") or []
ack_runs = run_data.get("Send Feedback Ack") or []

if not parse_runs:
    raise SystemExit("❌ Parse Feedback output not found in late run")
if not ack_runs:
    raise SystemExit("❌ Send Feedback Ack output not found in late run")
if db_runs:
    raise SystemExit("❌ Feedback Events DB should not run for late feedback")

payload = parse_runs[0].get("data", {}).get("main", [[{}]])[0][0].get("json", {})
if payload.get("isLateResponse") is not True:
    raise SystemExit("❌ Expected late feedback in second run")

run_id = str(payload.get("runId", "")).strip()
if not run_id:
    raise SystemExit("❌ Missing runId in late Parse Feedback payload")
print(run_id)
PY
)"

  [[ -n "$late_run_id" ]] || { echo "❌ Missing late run id"; exit 1; }

  local mid count_payload
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  count_payload="$(docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" --eval "print(db.feedback_events.countDocuments({ runId: '${late_run_id}' }));")"
  local count
  count="$(echo "$count_payload" | tail -n1 | tr -d '[:space:]')"

  if [[ "$count" != "0" ]]; then
    echo "❌ Late feedback run should not persist events (count=$count)"
    exit 1
  fi

  echo "✅ Late feedback is acknowledged without persistence"
}

require_tool docker
require_tool curl
require_tool jq
require_tool sqlite3
discover_workflow

docker info >/dev/null 2>&1 || {
  echo "❌ Docker daemon not running"
  exit 1
}

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$N8N_DATA_DIR"
chmod -R 777 "$TMP_DIR" "$N8N_DATA_DIR"

"${COMPOSE_CMD[@]}" down -v >/dev/null 2>&1 || true
docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true

echo "▶️  Starting services for feedback itest"
"${COMPOSE_CMD[@]}" up -d

wait_for_service "MockServer" "http://$MOCK_HOST:$MOCK_PORT/mockserver/status" 30 2
wait_for_service "n8n" "http://$N8N_HOST:$N8N_PORT/healthz" 60 2

CID=$("${COMPOSE_CMD[@]}" ps -q n8n)
[[ -n "$CID" ]] || { echo "❌ Unable to resolve n8n container id"; exit 1; }

seed_credentials
patch_workflow 0

echo "▶️  Importing feedback workflow"
import_patched_workflow

set +e
workflow_id="$(sqlite3 "$N8N_DATA_DIR/database.sqlite" "SELECT id FROM workflow_entity WHERE name = '$WORKFLOW_NAME' ORDER BY updatedAt DESC LIMIT 1;" 2>"$TMP_DIR/sqlite.err")"
sqlite_status=$?
set -e

if [[ "$sqlite_status" -ne 0 || -z "$workflow_id" ]]; then
  echo "❌ Could not fetch feedback workflow ID from database"
  cat "$TMP_DIR/sqlite.err" || true
  exit 1
fi
workflow_id="$(echo "$workflow_id" | tr -d '[:space:]')"
echo "✅ Feedback workflow imported with ID $workflow_id"

echo "▶️  Executing feedback workflow (non-late callback)"
execute_workflow "$EXECUTION_LOG" ""
verify_non_late_feedback

echo "▶️  Re-importing feedback workflow with late callback fixture"
patch_workflow 21
import_patched_workflow

echo "▶️  Executing feedback workflow (late callback)"
execute_workflow "$EXECUTION_LOG_LATE" ""
verify_late_feedback

echo "✅ Feedback workflow integration tests passed"
