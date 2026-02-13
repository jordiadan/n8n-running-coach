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
    --eval "db.feedback_events.deleteMany({}); db.feedback_events.insertMany([{sessionKey:'itest-pain-recent-${recent_date}',runId:'itest-prior-run-recent',response:'pain',sessionDate:'${recent_date}',sessionDay:'Monday',chatId:'730354404',messageId:111,userId:1,username:'itest',receivedAt:'${now_iso}'},{sessionKey:'itest-pain-stale-${stale_date}',runId:'itest-prior-run-stale',response:'pain',sessionDate:'${stale_date}',sessionDay:'Monday',chatId:'730354404',messageId:112,userId:1,username:'itest',receivedAt:'${stale_iso}'}]);" >/dev/null
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
    | .connections["Build Feedback Prompt"].main[0] += [
        { "node": "Telegram Feedback Trigger", "type": "main", "index": 0 }
      ]
  ' "$WORKFLOW_FILE" > "$PATCHED_JSON"
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
required_sections = [
    "<b>Last-week summary</b>",
    "<b>This-week goal</b>",
    "<b>Daily plan</b>",
    "<b>Key session</b>",
    "<b>Warnings</b>",
]
missing = [section for section in required_sections if section not in html]
if missing:
    raise SystemExit("❌ Missing fixed Telegram sections: " + ", ".join(missing))

template_version = payload.get("telegramTemplateVersion")
if template_version != "telegram-v2.0":
    raise SystemExit(f"❌ Unexpected telegramTemplateVersion: {template_version!r}")

completeness = payload.get("sectionCompleteness")
required_keys = {"lastWeekSummary", "thisWeekGoal", "dailyPlan", "keySession", "warnings"}
if not isinstance(completeness, dict):
    raise SystemExit("❌ sectionCompleteness is missing or invalid")
missing_keys = sorted(required_keys - set(completeness.keys()))
if missing_keys:
    raise SystemExit("❌ sectionCompleteness missing keys: " + ", ".join(missing_keys))

missing_count = payload.get("sectionMissingCount")
if not isinstance(missing_count, int):
    raise SystemExit("❌ sectionMissingCount is missing or invalid")

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
if risk_feedback.get("painEventCount") != 1:
    raise SystemExit(f"❌ Expected only recent pain event count = 1, got {risk_feedback.get('painEventCount')!r}")

html = str(payload.get("htmlMessage") or "")
if "Pain feedback reported" not in html:
    raise SystemExit("❌ Pain warning text missing in htmlMessage")

print("✅ Pain-triggered risk metadata is present and time-windowed")
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

print("✅ Quick-feedback buttons and callback parsing are valid")
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

echo "▶️  Executing workflow"
timeout_cmd="$(command -v gtimeout || command -v timeout || true)"
if [[ -n "$timeout_cmd" ]]; then
  set +e
  $timeout_cmd 120 docker exec -u node "$CID" sh -lc "cd /home/node && n8n execute --rawOutput --id $workflow_id" | tee "$EXECUTION_LOG"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" -eq 124 || "$status" -eq 143 ]]; then
    echo "❌ Execution timed out"
    exit 1
  fi
else
  docker exec -u node "$CID" sh -lc "cd /home/node && n8n execute --rawOutput --id $workflow_id" | tee "$EXECUTION_LOG"
  status=${PIPESTATUS[0]}
fi

if [[ "$status" -ne 0 ]]; then
  echo "❌ Workflow execution failed (exit $status)"
  exit "$status"
fi

verify_execution
verify_golden_snapshot
verify_telegram_template
verify_why_this_plan
verify_preview_mode_metadata
verify_risk_warning_metadata
verify_feedback_quick_replies
