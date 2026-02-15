#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$REPO_ROOT/.tmp"

COMPOSE_FILE="$REPO_ROOT/docker-compose.itest.yml"
MOCKS_FILE="$REPO_ROOT/tests/mockserver-expectations.json"
CREDS_FILE="$REPO_ROOT/tests/credentials/mongo.json"
PATCHED_JSON="$TMP_DIR/running-coach.itest.json"
EXECUTION_LOG="$TMP_DIR/execution.log"
EXECUTION_LOG_REMINDER_DUP="$TMP_DIR/execution.reminder-dup.log"
EXECUTION_LOG_REMINDER_OPTOUT="$TMP_DIR/execution.reminder-optout.log"

N8N_HOST="localhost"
N8N_PORT="5678"
MOCK_HOST="localhost"
MOCK_PORT="1080"
NETWORK_NAME="integration_test_network"

WORKFLOW_NAME_DEFAULT="Running Coach"
WORKFLOW_NAME="${WORKFLOW_NAME:-$WORKFLOW_NAME_DEFAULT}"
WORKFLOW_FILE="${WORKFLOW_FILE:-}"

COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE")

cleanup() {
  local exit_code=$?
  echo "🧹 Cleanup (exit $exit_code)"
  if command -v docker >/dev/null 2>&1; then
    "${COMPOSE_CMD[@]}" logs --tail 150 || true
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
    local body="$(echo "$response" | sed '$d')"

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

seed_weekly_metrics_history() {
  echo "▶️  Seeding weekly_metrics history"
  local mid
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  python3 - <<'PY' > "$TMP_DIR/weekly_metrics_seed.json"
from datetime import date, timedelta
import json

today = date.today()
monday = today - timedelta(days=today.weekday())

docs = []
for i in range(1, 5):
    week_start = monday - timedelta(days=7 * i)
    week_end = week_start + timedelta(days=6)
    docs.append({
        "athleteId": 372001,
        "weekStart": week_start.isoformat(),
        "weekEnd": week_end.isoformat(),
        "runCount": 3,
        "runDistance": 30000 + i * 1500,
        "runTime": 10800 + i * 300,
        "rideCount": 1,
        "rideDistance": 20000 + i * 500,
        "rideTime": 5400,
        "rideTrimp": 60 + i * 2,
        "vo2Sessions": 1,
        "tempoSessions": 1,
        "longRuns": 1,
        "strengthCount": 2,
        "strengthTrimp": 30,
        "ctlMean": 70 + i,
        "atlMean": 65 + i,
        "rampRateMean": 3 + (i % 2),
        "restHrMean": 52 + i,
        "stepsMean": 9000 + i * 200,
        "sleepScoreMean": 78 + i,
        "hrvMean": 68 + i,
        "createdAt": week_start.isoformat() + "T00:00:00Z",
        "updatedAt": week_start.isoformat() + "T00:00:00Z",
    })

print(json.dumps(docs))
PY

  local seed_json
  seed_json="$(cat "$TMP_DIR/weekly_metrics_seed.json")"
  docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" \
    --eval "db.weekly_metrics.deleteMany({}); db.weekly_metrics.insertMany($seed_json);" >/dev/null
  echo "✅ weekly_metrics history seeded"
}

seed_feedback_events() {
  echo "▶️  Seeding feedback_events history"
  local mid now_iso recent_date stale_iso stale_date
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  recent_date="${now_iso%%T*}"
  stale_iso="$(date -u -v-45d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '45 days ago' +"%Y-%m-%dT%H:%M:%SZ")"
  stale_date="${stale_iso%%T*}"

  docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" \
    --eval "db.feedback_events.deleteMany({}); db.feedback_events.insertMany([{sessionKey:'itest-pain-recent-${recent_date}',sessionRef:'itest-prior-run-recent-111',runId:'itest-prior-run-recent',type:'pain',response:'pain',note:null,sessionDate:'${recent_date}',date:'${recent_date}',sessionDay:'Monday',day:'Monday',chatId:'730354404',messageId:111,userId:1,username:'itest',timestamp:'${now_iso}',receivedAt:'${now_iso}'},{sessionKey:'itest-skipped-recent-a-${recent_date}',sessionRef:'itest-prior-run-recent-113',runId:'itest-prior-run-recent',type:'skipped',response:'skipped',note:null,sessionDate:'${recent_date}',date:'${recent_date}',sessionDay:'Tuesday',day:'Tuesday',chatId:'730354404',messageId:113,userId:1,username:'itest',timestamp:'${now_iso}',receivedAt:'${now_iso}'},{sessionKey:'itest-skipped-recent-b-${recent_date}',sessionRef:'itest-prior-run-recent-114',runId:'itest-prior-run-recent',type:'skipped',response:'skipped',note:null,sessionDate:'${recent_date}',date:'${recent_date}',sessionDay:'Wednesday',day:'Wednesday',chatId:'730354404',messageId:114,userId:1,username:'itest',timestamp:'${now_iso}',receivedAt:'${now_iso}'},{sessionKey:'itest-foreign-pain-${recent_date}',sessionRef:'itest-foreign-run-211',runId:'itest-foreign-run',type:'pain',response:'pain',note:null,sessionDate:'${recent_date}',date:'${recent_date}',sessionDay:'Monday',day:'Monday',chatId:'999000111',messageId:211,userId:2,username:'other',timestamp:'${now_iso}',receivedAt:'${now_iso}'},{sessionKey:'itest-foreign-skipped-${recent_date}',sessionRef:'itest-foreign-run-212',runId:'itest-foreign-run',type:'skipped',response:'skipped',note:null,sessionDate:'${recent_date}',date:'${recent_date}',sessionDay:'Tuesday',day:'Tuesday',chatId:'999000111',messageId:212,userId:2,username:'other',timestamp:'${now_iso}',receivedAt:'${now_iso}'},{sessionKey:'itest-pain-stale-${stale_date}',sessionRef:'itest-prior-run-stale-112',runId:'itest-prior-run-stale',type:'pain',response:'pain',note:null,sessionDate:'${stale_date}',date:'${stale_date}',sessionDay:'Monday',day:'Monday',chatId:'730354404',messageId:112,userId:1,username:'itest',timestamp:'${stale_iso}',receivedAt:'${stale_iso}'}]);" >/dev/null
  echo "✅ feedback_events history seeded"
}

patch_workflow() {
  echo "▶️  Patching workflow JSON"
  local js_mock_llm js_mock_repair_1 js_mock_repair_2 js_mock_telegram js_mock_feedback_trigger

  js_mock_llm=$'return [{\n  json: {\n    activityPlan: {\n      nextWeek: {\n        phase: "Desarrollo",\n        objective: "Consolidar base aerobica",\n        weekStart: "2025-10-13",\n        weekEnd: "2025-10-19"\n      },\n      days: [\n        { day: "Lunes", date: "2025-10-13", activity: "Easy run", distance_time: "40 min", intensity: "Hard", goal: "Recuperacion", note: "Movilidad + foam roller" },\n        { day: "Martes", date: "2025-10-14", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Pecho y brazos)" },\n        { day: "Miercoles", date: "2025-10-15", activity: "VO2 max", distance_time: "4x3 min", intensity: "Z4-Z5 (168-188 bpm)", goal: "Potencia aerobica" },\n        { day: "Jueves", date: "2025-10-16", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Espalda y hombros)" },\n        { day: "Viernes", date: "2025-10-17", activity: "Tempo / Umbral", distance_time: "30 min", intensity: "Z3-Z4 (155-174 bpm)", goal: "Tolerancia lactato" },\n        { day: "Sabado", date: "2025-10-18", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Piernas)" },\n        { day: "Domingo", date: "2025-10-19", activity: "Long run", distance_time: "75 min", intensity: "Z2 (118-138 bpm)", goal: "Base aerobica progresiva", note: "Ultimos 10 min a Z3" }\n      ]\n    },\n    justification: [\n      "Carga coherente con ATL y HRV recientes",\n      "VO2 y tempo separados por >=48h",\n      "Long run progresivo para consolidar CTL"\n    ]\n  }\n}];'

  js_mock_repair_1=$'return [{\n  json: {\n    schema_version: "1.0",\n    activityPlan: {\n      nextWeek: {\n        phase: "Desarrollo",\n        objective: "Consolidar base aerobica",\n        weekStart: "2025-10-13",\n        weekEnd: "2025-10-19"\n      },\n      days: [\n        { day: "Lunes", date: "2025-10-13", activity: "Easy run", distance_time: "40 min", intensity: "Hard", goal: "Recuperacion", note: "Movilidad + foam roller" },\n        { day: "Martes", date: "2025-10-14", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Pecho y brazos)" },\n        { day: "Miercoles", date: "2025-10-15", activity: "VO2 max", distance_time: "4x3 min", intensity: "Z4-Z5 (168-188 bpm)", goal: "Potencia aerobica" },\n        { day: "Jueves", date: "2025-10-16", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Espalda y hombros)" },\n        { day: "Viernes", date: "2025-10-17", activity: "Tempo / Umbral", distance_time: "30 min", intensity: "Z3-Z4 (155-174 bpm)", goal: "Tolerancia lactato" },\n        { day: "Sabado", date: "2025-10-18", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Piernas)" },\n        { day: "Domingo", date: "2025-10-19", activity: "Long run", distance_time: "75 min", intensity: "Z2 (118-138 bpm)", goal: "Base aerobica progresiva", note: "Ultimos 10 min a Z3" }\n      ]\n    },\n    justification: [\n      "Carga coherente con ATL y HRV recientes",\n      "VO2 y tempo separados por >=48h",\n      "Long run progresivo para consolidar CTL"\n    ]\n  }\n}];'

  js_mock_repair_2=$'return [{\n  json: {\n    schema_version: "1.0",\n    activityPlan: {\n      nextWeek: {\n        phase: "Desarrollo",\n        objective: "Consolidar base aerobica",\n        weekStart: "2025-10-13",\n        weekEnd: "2025-10-19"\n      },\n      days: [\n        { day: "Lunes", date: "2025-10-13", activity: "Easy run", distance_time: "40 min", intensity: "Z2 (118-138 bpm)", goal: "Recuperacion", note: "Movilidad + foam roller" },\n        { day: "Martes", date: "2025-10-14", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Pecho y brazos)" },\n        { day: "Miercoles", date: "2025-10-15", activity: "VO2 max", distance_time: "4x3 min", intensity: "Z4-Z5 (168-188 bpm)", goal: "Potencia aerobica" },\n        { day: "Jueves", date: "2025-10-16", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Espalda y hombros)" },\n        { day: "Viernes", date: "2025-10-17", activity: "Tempo / Umbral", distance_time: "30 min", intensity: "Z3-Z4 (155-174 bpm)", goal: "Tolerancia lactato" },\n        { day: "Sabado", date: "2025-10-18", activity: "Gimnasio", distance_time: "60 min", intensity: "-", goal: "Fuerza (Piernas)" },\n        { day: "Domingo", date: "2025-10-19", activity: "Long run", distance_time: "75 min", intensity: "Z2 (118-138 bpm)", goal: "Base aerobica progresiva", note: "Ultimos 10 min a Z3" }\n      ]\n    },\n    justification: [\n      "Carga coherente con ATL y HRV recientes",\n      "VO2 y tempo separados por >=48h",\n      "Long run progresivo para consolidar CTL"\n    ]\n  }\n}];'

  js_mock_telegram=$'return [{\n  json: {\n    ok: true,\n    result: {\n      message_id: 12345,\n      chat: { id: 987654, username: "itest" },\n      date: Math.floor(Date.now() / 1000),\n      text: "Test Telegram message"\n    }\n  }\n}];'

  js_mock_feedback_trigger=$'const runId = items[0].json.runId || "itest-run";\nreturn [{\n  json: {\n    callback_query: {\n      data: `feedback|${runId}|done`,\n      from: { id: 1, username: "itest" },\n      message: {\n        message_id: 12345,\n        chat: { id: 987654, username: "itest" },\n        date: Math.floor(Date.now() / 1000)\n      }\n    }\n  }\n}];'

  jq --arg js_llm "$js_mock_llm" --arg js_repair_1 "$js_mock_repair_1" --arg js_repair_2 "$js_mock_repair_2" --arg js_telegram "$js_mock_telegram" --arg js_feedback "$js_mock_feedback_trigger" --arg mockUrl "http://mock:1080" '
    .nodes |= map(
      if .name == "GET Activities" then
        .parameters.url = $mockUrl + "/api/v1/athlete/i372001/activities"
        | .parameters.sendHeaders = false
        | .parameters.headerParameters.parameters = []
      elif .name == "GET Wellness" then
        .parameters.url = $mockUrl + "/api/v1/athlete/i372001/wellness"
        | .parameters.sendHeaders = false
        | .parameters.headerParameters.parameters = []
      elif .name == "Telegram Feedback Trigger" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_feedback}
        | del(.credentials)
      elif .name == "Message a model" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_llm}
        | del(.credentials)
      elif .name == "Repair Plan 1" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_repair_1}
        | del(.credentials)
      elif .name == "Repair Plan 2" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_repair_2}
        | del(.credentials)
      elif .name == "Send a text message" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      elif .name == "Send Feedback Prompt" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      elif .name == "Send Feedback Ack" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      elif .name == "Send Reminder Message" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      elif .name == "Send Failure Alert" then
        .type = "n8n-nodes-base.code"
        | .typeVersion = 2
        | .parameters = {jsCode: $js_telegram}
        | del(.credentials)
      else .
      end
    )
    | .connections["Is WeeklyPlan valid? (attempt 0)"].main = [
        [{ "node": "Build Repair Prompt (attempt 1)", "type": "main", "index": 0 }],
        [{ "node": "Build Repair Prompt (attempt 1)", "type": "main", "index": 0 }]
      ]
    | .connections["Is WeeklyPlan valid? (attempt 1)"].main = [
        [{ "node": "Build Repair Prompt (attempt 2)", "type": "main", "index": 0 }],
        [{ "node": "Build Repair Prompt (attempt 2)", "type": "main", "index": 0 }]
      ]
    | .connections["Is WeeklyPlan valid? (attempt 2)"].main = [
        [{ "node": "Build Run Event (success)", "type": "main", "index": 0 }],
        [{ "node": "Build Run Event (success)", "type": "main", "index": 0 }]
      ]
    | .connections["Build Run Event (success)"].main[0] += [
        { "node": "Build Reminder Context", "type": "main", "index": 0 }
      ]
    | .connections["Build Feedback Prompt"].main[0] += [
        { "node": "Telegram Feedback Trigger", "type": "main", "index": 0 }
      ]
  ' "$WORKFLOW_FILE" > "$PATCHED_JSON"
}

execute_workflow() {
  local log_file=$1
  local env_prefix=$2
  local timeout_cmd status

  timeout_cmd="$(command -v gtimeout || command -v timeout || true)"
  if [[ -n "$timeout_cmd" ]]; then
    set +e
    $timeout_cmd 120 docker exec -u node "$CID" sh -lc "cd /home/node && $env_prefix n8n execute --rawOutput --id $workflow_id" | tee "$log_file"
    status=${PIPESTATUS[0]}
    set -e
    if [[ "$status" -eq 124 || "$status" -eq 143 ]]; then
      echo "❌ Execution timed out"
      exit 1
    fi
  else
    set +e
    docker exec -u node "$CID" sh -lc "cd /home/node && $env_prefix n8n execute --rawOutput --id $workflow_id" | tee "$log_file"
    status=${PIPESTATUS[0]}
    set -e
  fi

  if [[ "$status" -ne 0 ]]; then
    echo "❌ Workflow execution failed (exit $status)"
    exit "$status"
  fi
}

verify_execution() {
  echo "▶️  Verifying node coverage"
  set +e
  local coverage_json
  coverage_json="$(python3 - "$EXECUTION_LOG" "$WORKFLOW_FILE" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path, workflow_path = sys.argv[1:3]
text = Path(log_path).read_text()
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
    sys.exit(1)

data_root = candidate.get('data', candidate)
run_data = data_root.get('resultData', {}).get('runData', {})
if not isinstance(run_data, dict):
    sys.exit(1)

executed = sorted(run_data.keys())

workflow = json.loads(Path(workflow_path).read_text())
expected = sorted({node.get('name') for node in workflow.get('nodes', []) if node.get('name')})

missing = [name for name in expected if name not in run_data]

json.dump({"executed": executed, "missing": missing}, sys.stdout)
PY
)"
  local status=$?
  set -e

  if [[ "$status" -ne 0 || -z "$coverage_json" ]]; then
    echo "❌ Unable to analyze execution output"
    exit 1
  fi

  local all_executed=true
  local executed_names
  executed_names="$(jq -r '.executed[]' <<<"$coverage_json" | sort -u)"
  local skip_names
  skip_names="$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.scheduleTrigger") | .name' "$WORKFLOW_FILE")"
  skip_names="$(
    printf "%s\n%s\n" \
      "$skip_names" \
      "$(jq -r '.nodes[] | select(.name == "Fallback Trigger") | .name' "$WORKFLOW_FILE")" \
      "$(jq -r '.nodes[] | select(.name == "Build Failure Event") | .name' "$WORKFLOW_FILE")" \
      "$(jq -r '.nodes[] | select(.name == "Run Events DB (failure)") | .name' "$WORKFLOW_FILE")" \
      "$(jq -r '.nodes[] | select(.name == "Send Failure Alert") | .name' "$WORKFLOW_FILE")" \
    | sed '/^$/d'
  )"

  while IFS= read -r node_name; do
    printf "   • %-30s" "$node_name"
    if grep -Fxq "$node_name" <<<"$skip_names"; then
      echo "SKIP"
      continue
    fi
    if grep -Fxq "$node_name" <<<"$executed_names"; then
      echo "✅"
    else
      echo "❌"
      all_executed=false
    fi
  done < <(jq -r '.nodes[].name' "$WORKFLOW_FILE" | sort -u)

  if [[ "$all_executed" == false ]]; then
    echo "❌ Missing node executions"
    jq -r '.missing[]?' <<<"$coverage_json" | awk '{print "   - " $0}'
    exit 1
  fi
  echo "✅ All nodes executed at least once"
}

verify_golden_snapshot() {
  echo "▶️  Verifying golden weekly plan snapshot"
  local fixture="$REPO_ROOT/tests/fixtures/golden_weekly_plan_snapshot.json"
  local output="$TMP_DIR/weekly_plan.snapshot.json"

  python3 - "$EXECUTION_LOG" "$fixture" "$output" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path, fixture_path, output_path = sys.argv[1:4]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
node_names = [
    "Validate WeeklyPlan (attempt 2)",
    "Validate WeeklyPlan (attempt 1)",
    "Validate WeeklyPlan (attempt 0)",
]

plan = None
for name in node_names:
    runs = run_data.get(name) or []
    for run in runs:
        data = run.get("data", {}).get("main", [])
        if not data or not data[0]:
            continue
        for item in data[0]:
            payload = item.get("json", {})
            if payload.get("__valid") is True:
                plan = {k: v for k, v in payload.items() if not k.startswith("__")}
                break
        if plan is not None:
            break
    if plan is not None:
        break

if plan is None:
    raise SystemExit("❌ No valid weekly plan found in execution output")

Path(output_path).write_text(json.dumps(plan, indent=2, sort_keys=True))
expected = json.loads(Path(fixture_path).read_text())

if plan != expected:
    print("❌ Golden snapshot mismatch")
    print("Actual saved at:", output_path)
    print("Expected fixture:", fixture_path)
    raise SystemExit(1)

print("✅ Golden snapshot matches")
PY
}

verify_telegram_template() {
  echo "▶️  Verifying Telegram template sections"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
runs = run_data.get("Build Telegram Message") or []
if not runs:
    raise SystemExit("❌ Build Telegram Message node output not found")

payload = None
for run in runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        payload = main[0][0].get("json", {})
        break

if not payload:
    raise SystemExit("❌ Build Telegram Message payload is empty")

html = payload.get("htmlMessage") or ""
max_telegram_length = 3900
if len(html) > max_telegram_length:
    raise SystemExit(f"❌ htmlMessage exceeds Telegram safe budget ({len(html)} > {max_telegram_length})")
required_sections = [
    "<b>Last-week summary</b>",
    "<b>Weekly adherence</b>",
    "<b>This-week goal</b>",
    "<b>Daily plan</b>",
    "<b>Key session</b>",
    "<b>Warnings</b>",
]
missing = [section for section in required_sections if section not in html]
if missing:
    raise SystemExit("❌ Missing fixed Telegram sections: " + ", ".join(missing))

template_version = payload.get("telegramTemplateVersion")
if template_version != "telegram-v2.1":
    raise SystemExit(f"❌ Unexpected telegramTemplateVersion: {template_version!r}")

if payload.get("telegramMessageBudget") != 3900:
    raise SystemExit(f"❌ telegramMessageBudget should be 3900, got {payload.get('telegramMessageBudget')!r}")
if payload.get("telegramMessageLength") != len(html):
    raise SystemExit(
        f"❌ telegramMessageLength mismatch: payload={payload.get('telegramMessageLength')!r}, actual={len(html)}"
    )

completeness = payload.get("sectionCompleteness")
required_keys = {"lastWeekSummary", "weeklyAdherence", "thisWeekGoal", "dailyPlan", "keySession", "warnings"}
if not isinstance(completeness, dict):
    raise SystemExit("❌ sectionCompleteness is missing or invalid")
missing_keys = sorted(required_keys - set(completeness.keys()))
if missing_keys:
    raise SystemExit("❌ sectionCompleteness missing keys: " + ", ".join(missing_keys))

missing_count = payload.get("sectionMissingCount")
if not isinstance(missing_count, int):
    raise SystemExit("❌ sectionMissingCount is missing or invalid")

weekly = payload.get("weeklyAdherenceSummary")
if not isinstance(weekly, dict):
    raise SystemExit("❌ weeklyAdherenceSummary is missing or invalid")
counts = weekly.get("counts")
if not isinstance(counts, dict):
    raise SystemExit("❌ weeklyAdherenceSummary.counts is missing or invalid")
for key in ("done", "skipped", "hard", "pain"):
    if key not in counts:
        raise SystemExit(f"❌ weeklyAdherenceSummary.counts missing key: {key}")

print("✅ Telegram template includes all fixed sections and observability fields")
PY
}

verify_why_this_plan() {
  echo "▶️  Verifying metrics-backed Why this plan bullets"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
runs = run_data.get("Build Telegram Message") or []
if not runs:
    raise SystemExit("❌ Build Telegram Message output not found")

payload = None
for run in runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        payload = main[0][0].get("json", {})
        break

if not payload:
    raise SystemExit("❌ Build Telegram Message payload is empty")

html = payload.get("htmlMessage") or ""
if "<b>Why this plan</b>" not in html:
    raise SystemExit("❌ Missing Why this plan section in Telegram HTML")

bullets = payload.get("whyThisPlan")
if not isinstance(bullets, list):
    raise SystemExit("❌ whyThisPlan is missing or invalid")
if len(bullets) < 2 or len(bullets) > 4:
    raise SystemExit(f"❌ whyThisPlan bullet count must be 2-4, got {len(bullets)}")
if any(not isinstance(item, str) or not item.strip() for item in bullets):
    raise SystemExit("❌ whyThisPlan contains empty bullet text")

metric_keys = payload.get("whyPlanMetricKeys")
if not isinstance(metric_keys, list):
    raise SystemExit("❌ whyPlanMetricKeys is missing or invalid")

failures = payload.get("whyPlanHallucinationFailures")
if failures != 0:
    raise SystemExit(f"❌ whyPlanHallucinationFailures expected 0, got {failures}")

print("✅ Why this plan bullets are metrics-backed and validated")
PY
}

verify_preview_mode_metadata() {
  echo "▶️  Verifying preview mode metadata defaults"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
runs = run_data.get("Build Telegram Message") or []
if not runs:
    raise SystemExit("❌ Build Telegram Message output not found")

payload = None
for run in runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        payload = main[0][0].get("json", {})
        break

if not payload:
    raise SystemExit("❌ Build Telegram Message payload is empty")

if payload.get("previewMode") is not False:
    raise SystemExit(f"❌ Expected previewMode=false by default, got {payload.get('previewMode')!r}")
if str(payload.get("previewChatId")) != "730354404":
    raise SystemExit(f"❌ Expected previewChatId=730354404 by default, got {payload.get('previewChatId')!r}")
if str(payload.get("chatId")) != "730354404":
    raise SystemExit(f"❌ Expected chatId=730354404 by default, got {payload.get('chatId')!r}")

print("✅ Preview mode metadata defaults are correct")
PY
}

verify_risk_warning_metadata() {
  echo "▶️  Verifying pain-triggered risk warning metadata"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
runs = run_data.get("Build Telegram Message") or []
if not runs:
    raise SystemExit("❌ Build Telegram Message output not found")

payload = None
for run in runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        payload = main[0][0].get("json", {})
        break

if not payload:
    raise SystemExit("❌ Build Telegram Message payload is empty")

counts = payload.get("riskWarningTriggerCounts")
if not isinstance(counts, dict):
    raise SystemExit("❌ riskWarningTriggerCounts missing")
if counts.get("painReported") != 1:
    raise SystemExit(f"❌ Expected painReported trigger count = 1, got {counts.get('painReported')!r}")

triggers = payload.get("riskWarningTriggers")
if not isinstance(triggers, list) or "painReported" not in triggers:
    raise SystemExit("❌ painReported missing from riskWarningTriggers")

risk_feedback = payload.get("riskFeedback")
if not isinstance(risk_feedback, dict):
    raise SystemExit("❌ riskFeedback missing")
if str(risk_feedback.get("chatId")) != "730354404":
    raise SystemExit(f"❌ riskFeedback should be scoped to default athlete chat, got {risk_feedback.get('chatId')!r}")
if risk_feedback.get("painEventCount") != 1:
    raise SystemExit(f"❌ Expected only recent pain event count = 1, got {risk_feedback.get('painEventCount')!r}")

html = str(payload.get("htmlMessage") or "")
if "Pain feedback reported" not in html:
    raise SystemExit("❌ Pain warning text missing in htmlMessage")

print("✅ Pain-triggered risk metadata is present and time-windowed")
PY
}

verify_feedback_adaptation_metadata() {
  echo "▶️  Verifying feedback adaptation summary and triggers"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})

prompt_runs = run_data.get("Prompt Builder") or []
if not prompt_runs:
    raise SystemExit("❌ Prompt Builder output not found")

prompt_payload = None
for run in prompt_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        prompt_payload = main[0][0].get("json", {})
        break

if not prompt_payload:
    raise SystemExit("❌ Prompt Builder payload is empty")

feedback = prompt_payload.get("feedbackSummary")
if not isinstance(feedback, dict):
    raise SystemExit("❌ feedbackSummary missing from Prompt Builder output")

activities = prompt_payload.get("activities")
wellness = prompt_payload.get("wellness")
if not isinstance(activities, list) or len(activities) == 0:
    raise SystemExit("❌ Prompt Builder should receive non-empty activities context")
if not isinstance(wellness, list) or len(wellness) == 0:
    raise SystemExit("❌ Prompt Builder should receive non-empty wellness context")

counts = feedback.get("counts")
if not isinstance(counts, dict):
    raise SystemExit("❌ feedbackSummary.counts missing")
if str(feedback.get("chatId")) != "730354404":
    raise SystemExit(f"❌ feedbackSummary.chatId should be scoped to default athlete chat, got {feedback.get('chatId')!r}")
if counts.get("pain") != 1:
    raise SystemExit(f"❌ Expected recent pain count = 1, got {counts.get('pain')!r}")
if counts.get("skipped") != 2:
    raise SystemExit(f"❌ Expected skipped count = 2 for scoped low adherence scenario, got {counts.get('skipped')!r}")

if feedback.get("hasRecentPain") is not True:
    raise SystemExit("❌ hasRecentPain should be true")
if feedback.get("hasLowAdherence") is not True:
    raise SystemExit("❌ hasLowAdherence should be true when skipped sessions are high")

adherence_rate = feedback.get("adherenceRate")
skip_rate = feedback.get("skipRate")
if adherence_rate is None or adherence_rate >= 0.6:
    raise SystemExit(f"❌ adherenceRate should indicate low adherence, got {adherence_rate!r}")
if skip_rate is None or skip_rate <= 0.4:
    raise SystemExit(f"❌ skipRate should indicate low adherence, got {skip_rate!r}")

triggers = feedback.get("adaptationTriggers")
if not isinstance(triggers, list):
    raise SystemExit("❌ adaptationTriggers missing")
expected_triggers = {"painReported", "lowAdherence"}
if not expected_triggers.issubset(set(triggers)):
    raise SystemExit(f"❌ adaptationTriggers missing expected values, got {triggers!r}")

reasons = feedback.get("adaptationReasons")
if not isinstance(reasons, list) or len(reasons) < 2:
    raise SystemExit("❌ adaptationReasons should include both pain and adherence rationale")

event_runs = run_data.get("Build Run Event (success)") or []
if not event_runs:
    raise SystemExit("❌ Build Run Event (success) output not found")

event_payload = None
for run in event_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        event_payload = main[0][0].get("json", {})
        break

if not event_payload:
    raise SystemExit("❌ Build Run Event payload is empty")

if event_payload.get("feedbackAdaptationApplied") is not True:
    raise SystemExit("❌ feedbackAdaptationApplied should be true")

trigger_count = event_payload.get("adaptationTriggerCount")
if not isinstance(trigger_count, int) or trigger_count < 2:
    raise SystemExit(f"❌ adaptationTriggerCount should be >= 2, got {trigger_count!r}")

event_triggers = event_payload.get("adaptationTriggers")
if not isinstance(event_triggers, list) or not expected_triggers.issubset(set(event_triggers)):
    raise SystemExit(f"❌ run event adaptationTriggers missing expected values, got {event_triggers!r}")

event_feedback = event_payload.get("feedbackSummary")
if not isinstance(event_feedback, dict) or event_feedback.get("hasLowAdherence") is not True:
    raise SystemExit("❌ run event should persist feedbackSummary with hasLowAdherence=true")

structured_logs = event_payload.get("structuredLogs")
if not isinstance(structured_logs, list) or len(structured_logs) < 2:
    raise SystemExit("❌ structuredLogs should contain at least 2 entries")

required_log_fields = {"run_id", "node_name", "duration_ms", "status", "error_type"}
for entry in structured_logs:
    if not isinstance(entry, dict):
        raise SystemExit("❌ structuredLogs contains a non-object entry")
    missing_log_fields = required_log_fields - set(entry.keys())
    if missing_log_fields:
        raise SystemExit(f"❌ structured log entry missing fields: {sorted(missing_log_fields)}")
    if str(entry.get("run_id")) != str(event_payload.get("runId")):
        raise SystemExit("❌ structured log run_id must match runId")
    if not isinstance(entry.get("duration_ms"), (int, float)) or entry.get("duration_ms") < 0:
        raise SystemExit("❌ structured log duration_ms must be a non-negative number")

coverage_rate = event_payload.get("structuredLogCoverageRate")
if not isinstance(coverage_rate, (int, float)) or coverage_rate < 0.99:
    raise SystemExit(f"❌ structuredLogCoverageRate should be >= 0.99, got {coverage_rate!r}")
snake_coverage = event_payload.get("structured_log_coverage_rate")
if snake_coverage != coverage_rate:
    raise SystemExit("❌ structured_log_coverage_rate should mirror structuredLogCoverageRate")

structured_count = event_payload.get("structuredLogCount")
if not isinstance(structured_count, int) or structured_count != len(structured_logs):
    raise SystemExit("❌ structuredLogCount should match structuredLogs length")

artifact_runs = run_data.get("Build Run Artifact (outputs)") or []
if not artifact_runs:
    raise SystemExit("❌ Build Run Artifact (outputs) output not found")

artifact_payload = None
for run in artifact_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        artifact_payload = main[0][0].get("json", {})
        break

if not artifact_payload:
    raise SystemExit("❌ Build Run Artifact payload is empty")

if artifact_payload.get("structuredLogCount") != structured_count:
    raise SystemExit("❌ run artifact structuredLogCount should match run event")
if artifact_payload.get("structuredLogCoverageRate") != coverage_rate:
    raise SystemExit("❌ run artifact structuredLogCoverageRate should match run event")

core_metrics = event_payload.get("coreMetrics")
if not isinstance(core_metrics, dict):
    raise SystemExit("❌ coreMetrics missing from run event")
for key in ("successRate", "retryCount", "invalidJsonRate", "latencyMs"):
    if key not in core_metrics:
        raise SystemExit(f"❌ coreMetrics missing key: {key}")
if core_metrics.get("successRate") != 1:
    raise SystemExit(f"❌ coreMetrics.successRate should be 1 for success path, got {core_metrics.get('successRate')!r}")
if not isinstance(core_metrics.get("retryCount"), int) or core_metrics.get("retryCount") < 0:
    raise SystemExit("❌ coreMetrics.retryCount should be a non-negative integer")
if not isinstance(core_metrics.get("invalidJsonRate"), (int, float)):
    raise SystemExit("❌ coreMetrics.invalidJsonRate should be numeric")
if not isinstance(core_metrics.get("latencyMs"), (int, float)) or core_metrics.get("latencyMs") < 0:
    raise SystemExit("❌ coreMetrics.latencyMs should be a non-negative number")

event_run_id = event_payload.get("runId")
validate_nodes = [
    "Validate WeeklyPlan (attempt 0)",
    "Validate WeeklyPlan (attempt 1)",
    "Validate WeeklyPlan (attempt 2)",
]
attempt_payloads = []
for node_name in validate_nodes:
    for run in run_data.get(node_name) or []:
        main = run.get("data", {}).get("main", [])
        if main and main[0]:
            payload = main[0][0].get("json", {})
            if isinstance(payload, dict):
                payload_run_id = payload.get("__runId") or payload.get("runId")
                if event_run_id and payload_run_id and str(payload_run_id) != str(event_run_id):
                    continue
                attempt_payloads.append(payload)

if not attempt_payloads:
    raise SystemExit("❌ validate attempt payloads missing for core metrics cross-check")

derived_attempt_count = len(attempt_payloads)
derived_invalid_json_count = sum(
    1
    for payload in attempt_payloads
    if any(
        str(err or "").lower().startswith("invalid_json")
        for err in (payload.get("__errors") if isinstance(payload.get("__errors"), list) else [])
    )
)
if core_metrics.get("validationAttemptCount") != derived_attempt_count:
    raise SystemExit(
        "❌ coreMetrics.validationAttemptCount should equal executed validation attempts "
        f"({derived_attempt_count}), got {core_metrics.get('validationAttemptCount')!r}"
    )
if core_metrics.get("invalidJsonCount") != derived_invalid_json_count:
    raise SystemExit(
        "❌ coreMetrics.invalidJsonCount should accumulate invalid_json attempts across retries "
        f"({derived_invalid_json_count}), got {core_metrics.get('invalidJsonCount')!r}"
    )
expected_invalid_json_rate = (
    derived_invalid_json_count / derived_attempt_count if derived_attempt_count else 0
)
if core_metrics.get("invalidJsonRate") != expected_invalid_json_rate:
    raise SystemExit(
        "❌ coreMetrics.invalidJsonRate should match invalid_json attempts / validation attempts "
        f"({expected_invalid_json_rate}), got {core_metrics.get('invalidJsonRate')!r}"
    )

thresholds = event_payload.get("coreMetricThresholds")
if not isinstance(thresholds, dict):
    raise SystemExit("❌ coreMetricThresholds missing from run event")
for key in ("minSuccessRate", "maxRetries", "maxInvalidJsonRate", "maxLatencyMs"):
    if key not in thresholds:
        raise SystemExit(f"❌ coreMetricThresholds missing key: {key}")

report_payload = event_payload.get("coreMetricsReport")
if not isinstance(report_payload, dict):
    raise SystemExit("❌ coreMetricsReport missing from run event")
report_metrics = report_payload.get("metrics")
if not isinstance(report_metrics, dict):
    raise SystemExit("❌ coreMetricsReport.metrics is missing or invalid")

artifact_core_metrics = artifact_payload.get("coreMetrics")
if not isinstance(artifact_core_metrics, dict):
    raise SystemExit("❌ coreMetrics missing from run artifact")
for key in ("successRate", "retryCount", "invalidJsonRate", "latencyMs"):
    if artifact_core_metrics.get(key) != core_metrics.get(key):
        raise SystemExit(f"❌ run artifact coreMetrics.{key} should align with run event")

failure_runs = run_data.get("Build Failure Event") or []
if failure_runs:
    failure_payload = None
    for run in failure_runs:
        main = run.get("data", {}).get("main", [])
        if main and main[0]:
            failure_payload = main[0][0].get("json", {})
            break
    if failure_payload:
        failure_logs = failure_payload.get("structuredLogs")
        if not isinstance(failure_logs, list) or not failure_logs:
            raise SystemExit("❌ failure structuredLogs should be present when failure path runs")
        for entry in failure_logs:
            if not isinstance(entry, dict):
                raise SystemExit("❌ failure structuredLogs contains non-object entry")
            missing_log_fields = required_log_fields - set(entry.keys())
            if missing_log_fields:
                raise SystemExit(f"❌ failure structured log entry missing fields: {sorted(missing_log_fields)}")
            if str(entry.get("status")) != "failure":
                raise SystemExit("❌ failure structured log status must be 'failure'")
        failure_core_metrics = failure_payload.get("coreMetrics")
        if not isinstance(failure_core_metrics, dict):
            raise SystemExit("❌ failure coreMetrics should be present when failure path runs")
        if failure_core_metrics.get("successRate") != 0:
            raise SystemExit("❌ failure coreMetrics.successRate should be 0")
        if not isinstance(failure_core_metrics.get("invalidJsonRate"), (int, float)):
            raise SystemExit("❌ failure coreMetrics.invalidJsonRate should be numeric")

print("✅ Feedback adaptation summary and triggers are correct")
PY
}

verify_feedback_quick_replies() {
  echo "▶️  Verifying quick-feedback buttons and callback parsing"

  python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})

prompt_runs = run_data.get("Build Feedback Prompt") or []
if not prompt_runs:
    raise SystemExit("❌ Build Feedback Prompt output not found")

prompt_payload = None
for run in prompt_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        prompt_payload = main[0][0].get("json", {})
        break

if not prompt_payload:
    raise SystemExit("❌ Build Feedback Prompt payload is empty")

keyboard = prompt_payload.get("replyMarkup", {}).get("inline_keyboard", [])
buttons = []
for row in keyboard:
    for button in row:
        if isinstance(button, dict):
            buttons.append(button)

button_texts = [str(button.get("text", "")) for button in buttons]
expected_texts = ["✅ Done", "❌ Skipped", "😵 Hard", "🦵 Pain"]
for expected in expected_texts:
    if expected not in button_texts:
        raise SystemExit(f"❌ Missing quick-feedback button: {expected}")

callback_values = [str(button.get("callback_data", "")) for button in buttons]
for response in ["done", "skipped", "hard", "pain"]:
    if not any(value.startswith("feedback|") and value.endswith(f"|{response}") for value in callback_values):
        raise SystemExit(f"❌ Missing callback_data for response '{response}'")

parse_runs = run_data.get("Parse Feedback") or []
if not parse_runs:
    raise SystemExit("❌ Parse Feedback output not found")

parse_payload = None
for run in parse_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        parse_payload = main[0][0].get("json", {})
        break

if not parse_payload:
    raise SystemExit("❌ Parse Feedback payload is empty")

session_key = str(parse_payload.get("sessionKey", ""))
if not re.search(r"-12345-1$", session_key):
    raise SystemExit(f"❌ sessionKey should include message/user ids, got: {session_key!r}")

if parse_payload.get("isLateResponse") is not False:
    raise SystemExit("❌ Expected test callback to be classified as non-late feedback")

feedback_type = str(parse_payload.get("type", ""))
if feedback_type not in {"done", "skipped", "hard", "pain"}:
    raise SystemExit(f"❌ Parsed feedback type is invalid: {feedback_type!r}")

if parse_payload.get("response") != feedback_type:
    raise SystemExit("❌ response alias should match type")

if parse_payload.get("note", None) is not None:
    raise SystemExit("❌ Expected note to default to null when omitted")

for required in ["sessionRef", "date", "day", "timestamp"]:
    if required not in parse_payload:
        raise SystemExit(f"❌ Missing expected parsed field: {required}")

print("✅ Quick-feedback buttons and callback parsing are valid")
PY
}

verify_feedback_event_storage_and_aggregation() {
  echo "▶️  Verifying FeedbackEvent write/read and aggregation"

  local session_key run_id mid mongo_payload

  read -r session_key run_id < <(python3 - "$EXECUTION_LOG" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})
parse_runs = run_data.get("Parse Feedback") or []
if not parse_runs:
    raise SystemExit("❌ Parse Feedback output not found")

payload = None
for run in parse_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        payload = main[0][0].get("json", {})
        break

if not payload:
    raise SystemExit("❌ Parse Feedback payload is empty")

session_key = str(payload.get("sessionKey", "")).strip()
run_id = str(payload.get("runId", "")).strip()
if not session_key or not run_id:
    raise SystemExit("❌ Missing sessionKey/runId in Parse Feedback payload")

print(session_key, run_id)
PY
)

  [[ -n "$session_key" && -n "$run_id" ]] || { echo "❌ Could not resolve feedback identifiers"; exit 1; }

  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  mongo_payload="$(docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" --eval "const doc = db.feedback_events.findOne({ sessionKey: '${session_key}' }); const agg = db.feedback_events.aggregate([{ \$match: { runId: '${run_id}' } }, { \$group: { _id: '\$type', count: { \$sum: 1 } } }]).toArray(); print(JSON.stringify({ doc, agg }));")"

  python3 - "$mongo_payload" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
if not raw:
    raise SystemExit("❌ MongoDB verification returned empty output")

try:
    payload = json.loads(raw.splitlines()[-1])
except json.JSONDecodeError as exc:
    raise SystemExit(f"❌ Failed to parse MongoDB verification payload: {exc}")

doc = payload.get("doc")
if not isinstance(doc, dict):
    raise SystemExit("❌ Feedback event was not persisted")

required_fields = [
    "sessionKey",
    "sessionRef",
    "runId",
    "type",
    "note",
    "sessionDate",
    "sessionDay",
    "timestamp",
]
missing = [field for field in required_fields if field not in doc]
if missing:
    raise SystemExit(f"❌ Persisted feedback event is missing fields: {missing}")

if doc.get("type") != "done":
    raise SystemExit(f"❌ Persisted feedback type mismatch: {doc.get('type')!r}")

if doc.get("note", None) is not None:
    raise SystemExit("❌ Persisted feedback note should be null when omitted")

agg = payload.get("agg")
if not isinstance(agg, list):
    raise SystemExit("❌ Aggregation output missing")

done_count = 0
for row in agg:
    if isinstance(row, dict) and row.get("_id") == "done":
        done_count = int(row.get("count", 0))
        break

if done_count < 1:
    raise SystemExit(f"❌ Expected aggregated done feedback count >= 1, got {done_count}")

print("✅ FeedbackEvent write/read and aggregation checks passed")
PY
}

verify_reminder_delivery_and_metrics() {
  local log_path=$1
  echo "▶️  Verifying reminder delivery and metrics"

  local reminder_date chat_id
  read -r reminder_date chat_id < <(python3 - "$log_path" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})

msg_runs = run_data.get("Build Reminder Message") or []
if not msg_runs:
    raise SystemExit("❌ Build Reminder Message output not found")

msg_payload = None
for run in msg_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        msg_payload = main[0][0].get("json", {})
        break

if not msg_payload:
    raise SystemExit("❌ Build Reminder Message payload is empty")

if msg_payload.get("shouldSend") is not True:
    raise SystemExit("❌ Reminder should be sendable in opt-in run")
if msg_payload.get("reminderTime") != "09:30":
    raise SystemExit(f"❌ reminderTime should reflect config (09:30), got {msg_payload.get('reminderTime')!r}")
if msg_payload.get("reminderTimezone") != "UTC":
    raise SystemExit(f"❌ reminderTimezone should reflect config (UTC), got {msg_payload.get('reminderTimezone')!r}")
session = msg_payload.get("session")
if not isinstance(session, dict) or not session.get("activity"):
    raise SystemExit("❌ Reminder should include a daily planned session")
if "<b>Training reminder</b>" not in str(msg_payload.get("text") or ""):
    raise SystemExit("❌ Reminder text template missing")

event_runs = run_data.get("Build Reminder Event") or []
if not event_runs:
    raise SystemExit("❌ Build Reminder Event output not found")

event_payload = None
for run in event_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        event_payload = main[0][0].get("json", {})
        if event_payload.get("deliveryStatus") == "sent":
            break

if not event_payload or event_payload.get("deliveryStatus") != "sent":
    raise SystemExit("❌ Reminder event should be marked as sent")
if event_payload.get("reminder_sent_count") != 1:
    raise SystemExit("❌ reminder_sent_count should be 1 when reminder is sent")
if event_payload.get("reminder_opt_in_users_count") != 1:
    raise SystemExit("❌ reminder_opt_in_users_count should be 1 for enabled reminders")

run_event_writes = run_data.get("Run Events DB (reminder)") or []
if not run_event_writes:
    raise SystemExit("❌ Run Events DB (reminder) output not found")

print(msg_payload.get("reminderDate"), msg_payload.get("chatId"))
PY
)

  [[ -n "$reminder_date" && -n "$chat_id" ]] || { echo "❌ Could not resolve reminder identifiers"; exit 1; }

  local mid sent_count
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  sent_count="$(docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" --eval "print(db.reminder_events.countDocuments({ chatId: '${chat_id}', reminderDate: '${reminder_date}', deliveryStatus: 'sent' }));")"
  sent_count="$(echo "$sent_count" | tail -n1 | tr -d '[:space:]')"
  if [[ "$sent_count" != "1" ]]; then
    echo "❌ Expected exactly 1 sent reminder for ${chat_id}/${reminder_date}, got ${sent_count:-<empty>}"
    exit 1
  fi

  echo "✅ Reminder delivery and metrics are correct"
}

verify_reminder_daily_dedupe() {
  local log_path=$1
  echo "▶️  Verifying reminder daily dedupe"

  local reminder_date chat_id
  read -r reminder_date chat_id < <(python3 - "$log_path" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})

msg_runs = run_data.get("Build Reminder Message") or []
if not msg_runs:
    raise SystemExit("❌ Build Reminder Message output not found")

msg_payload = None
for run in msg_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        msg_payload = main[0][0].get("json", {})
        break

if not msg_payload:
    raise SystemExit("❌ Build Reminder Message payload is empty")
if msg_payload.get("shouldSend") is not False:
    raise SystemExit("❌ Reminder should be blocked on duplicate daily send")
if msg_payload.get("deliveryStatus") != "skipped_already_sent":
    raise SystemExit(f"❌ Expected skipped_already_sent, got {msg_payload.get('deliveryStatus')!r}")

event_runs = run_data.get("Build Reminder Event") or []
if not event_runs:
    raise SystemExit("❌ Build Reminder Event output not found")

event_payload = None
for run in event_runs:
    main = run.get("data", {}).get("main", [])
    if main and main[0]:
        event_payload = main[0][0].get("json", {})
        break

if not event_payload:
    raise SystemExit("❌ Build Reminder Event payload is empty")
if event_payload.get("deliveryStatus") != "skipped_already_sent":
    raise SystemExit("❌ Reminder dedupe event should persist skipped_already_sent status")
if event_payload.get("reminder_sent_count") != 0:
    raise SystemExit("❌ reminder_sent_count should be 0 for duplicate reminders")

print(msg_payload.get("reminderDate"), msg_payload.get("chatId"))
PY
)

  [[ -n "$reminder_date" && -n "$chat_id" ]] || { echo "❌ Could not resolve reminder identifiers"; exit 1; }

  local mid sent_count
  mid=$("${COMPOSE_CMD[@]}" ps -q mongo)
  [[ -n "$mid" ]] || { echo "❌ Unable to resolve mongo container id"; exit 1; }

  sent_count="$(docker exec "$mid" mongosh --quiet "mongodb://localhost:27017/running_coach_itest" --eval "print(db.reminder_events.countDocuments({ chatId: '${chat_id}', reminderDate: '${reminder_date}', deliveryStatus: 'sent' }));")"
  sent_count="$(echo "$sent_count" | tail -n1 | tr -d '[:space:]')"
  if [[ "$sent_count" != "1" ]]; then
    echo "❌ Dedupe failed; expected sent reminder count to remain 1, got ${sent_count:-<empty>}"
    exit 1
  fi

  echo "✅ Reminder daily dedupe works"
}

verify_reminder_opt_out() {
  local log_path=$1
  echo "▶️  Verifying reminder opt-out path"

  python3 - "$log_path" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = sys.argv[1]
text = Path(log_path).read_text()
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

data_root = candidate.get("data", candidate)
run_data = data_root.get("resultData", {}).get("runData", {})

def has_non_empty_output(node_name: str) -> bool:
    runs = run_data.get(node_name) or []
    for run in runs:
        main = run.get("data", {}).get("main", [])
        if main and main[0]:
            return True
    return False

if has_non_empty_output("Build Reminder Context"):
    raise SystemExit("❌ Reminder context should not emit items when RC_REMINDER_ENABLED=false")
if has_non_empty_output("Build Reminder Message"):
    raise SystemExit("❌ Reminder message should not be generated when reminders are disabled")
if has_non_empty_output("Send Reminder Message"):
    raise SystemExit("❌ Reminder should not be sent when reminders are disabled")
if has_non_empty_output("Build Reminder Event"):
    raise SystemExit("❌ Reminder event should not be persisted when reminders are disabled")

print("✅ Reminder opt-out path is respected")
PY
}

# Preconditions
require_tool jq
require_tool docker
require_tool curl
require_tool sqlite3
discover_workflow

[[ -f "$COMPOSE_FILE" ]] || { echo "❌ Missing $COMPOSE_FILE"; exit 1; }
[[ -f "$MOCKS_FILE" ]] || { echo "❌ Missing $MOCKS_FILE"; exit 1; }
[[ -f "$CREDS_FILE" ]] || { echo "❌ Missing $CREDS_FILE"; exit 1; }

docker info >/dev/null 2>&1 || {
  echo "❌ Docker daemon not running"
  exit 1
}

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$TMP_DIR/n8n"
mkdir -p "$REPO_ROOT/.tmp/n8n"
chmod -R 777 "$TMP_DIR" "$REPO_ROOT/.tmp/n8n"

"${COMPOSE_CMD[@]}" down -v >/dev/null 2>&1 || true
docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true

echo "▶️  Starting services"
"${COMPOSE_CMD[@]}" up -d

wait_for_service "MockServer" "http://$MOCK_HOST:$MOCK_PORT/mockserver/status" 30 2
wait_for_service "n8n" "http://$N8N_HOST:$N8N_PORT/healthz" 60 2

echo "▶️  Injecting HTTP mocks"
mock_response="$(
  curl -sS -w '\n%{http_code}' -X PUT "http://$MOCK_HOST:$MOCK_PORT/mockserver/expectation" \
    -H 'Content-Type: application/json' \
    -d @"$MOCKS_FILE" 2>&1
)"
mock_code="$(echo "$mock_response" | tail -n1)"
mock_body="$(echo "$mock_response" | sed '$d')"

if [[ "$mock_code" != "200" && "$mock_code" != "201" && "$mock_code" != "202" ]]; then
  echo "❌ Failed to load mock expectations (HTTP $mock_code)"
  echo "$mock_body"
  exit 1
fi

CID=$("${COMPOSE_CMD[@]}" ps -q n8n)
[[ -n "$CID" ]] || { echo "❌ Unable to resolve n8n container id"; exit 1; }

seed_credentials
seed_weekly_metrics_history
seed_feedback_events
patch_workflow

docker cp "$PATCHED_JSON" "$CID:/home/node/itest.workflow.json"

echo "▶️  Importing workflow"
set +e
import_output="$(docker exec -u node "$CID" sh -lc "cd /home/node && n8n import:workflow --input itest.workflow.json")"
import_status=$?
set -e

clean_import_output="$(echo "$import_output" | sed -E $'s/\\x1B\\[[0-9;]*[A-Za-z]//g')"

if [[ "$import_status" -ne 0 ]]; then
  echo "❌ Workflow import failed (exit $import_status)"
  echo "$clean_import_output"
  exit "$import_status"
fi
set +e
workflow_id="$(sqlite3 "$REPO_ROOT/.tmp/n8n/database.sqlite" "SELECT id FROM workflow_entity WHERE name = 'Running Coach' ORDER BY updatedAt DESC LIMIT 1;" 2>"$TMP_DIR/sqlite.err")"
sqlite_status=$?
set -e

if [[ "$sqlite_status" -ne 0 || -z "$workflow_id" ]]; then
  echo "❌ Could not fetch workflow ID from database"
  echo "$clean_import_output"
  cat "$TMP_DIR/sqlite.err" || true
  exit 1
fi
workflow_id="$(echo "$workflow_id" | tr -d '[:space:]')"

echo "✅ Workflow imported with ID $workflow_id"

echo "▶️  Executing workflow (reminders opt-in path)"
execute_workflow "$EXECUTION_LOG" "RC_REMINDER_ENABLED=true RC_REMINDER_FORCE_SEND=true RC_REMINDER_TIME=09:30 RC_REMINDER_TIMEZONE=UTC"

verify_execution
verify_golden_snapshot
verify_telegram_template
verify_why_this_plan
verify_preview_mode_metadata
verify_risk_warning_metadata
verify_feedback_adaptation_metadata
verify_feedback_quick_replies
verify_feedback_event_storage_and_aggregation
verify_reminder_delivery_and_metrics "$EXECUTION_LOG"

echo "▶️  Executing workflow (reminder dedupe check)"
execute_workflow "$EXECUTION_LOG_REMINDER_DUP" "RC_REMINDER_ENABLED=true RC_REMINDER_FORCE_SEND=true RC_REMINDER_TIME=09:30 RC_REMINDER_TIMEZONE=UTC"
verify_reminder_daily_dedupe "$EXECUTION_LOG_REMINDER_DUP"

echo "▶️  Executing workflow (reminder opt-out check)"
execute_workflow "$EXECUTION_LOG_REMINDER_OPTOUT" "RC_REMINDER_ENABLED=false RC_REMINDER_FORCE_SEND=true RC_REMINDER_TIME=09:30 RC_REMINDER_TIMEZONE=UTC"
verify_reminder_opt_out "$EXECUTION_LOG_REMINDER_OPTOUT"
