#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "weekly_plan.schema.json"
GOLDEN_WEEKS_SCHEMA_PATH = ROOT / "schemas" / "golden_weeks_dataset.schema.json"
FIXTURES_DIR = ROOT / "tests" / "fixtures"
GOLDEN_WEEKS_PATH = FIXTURES_DIR / "golden_weeks_dataset_v1.json"


HARD_TOKENS = ["z4", "z5", "vo2", "interval", "umbral", "tempo", "threshold"]
EASY_TOKENS = ["z1", "z2", "easy", "recovery", "recuper", "suave"]
REST_TOKENS = ["descanso", "rest", "off"]
LONG_TOKENS = ["tirada", "larga", "long"]
GYM_TOKENS = ["gimnasio", "gym", "fuerza", "strength"]
RUN_TOKENS = [
    "run",
    "tempo",
    "vo2",
    "interval",
    "umbral",
    "threshold",
    "rodaje",
    "carrera",
    "trote",
    "continu",
]
REQUIRED_DAYS = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
PII_FORBIDDEN_KEYS = {
    "name",
    "firstName",
    "lastName",
    "fullName",
    "email",
    "phone",
    "chatId",
    "username",
    "userId",
    "telegramId",
    "address",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def normalize_day(value: str) -> str:
    text = (value or "").strip().lower()
    text = (
        text.replace("á", "a")
        .replace("à", "a")
        .replace("ä", "a")
        .replace("é", "e")
        .replace("è", "e")
        .replace("ë", "e")
        .replace("í", "i")
        .replace("ì", "i")
        .replace("ï", "i")
        .replace("ó", "o")
        .replace("ò", "o")
        .replace("ö", "o")
        .replace("ú", "u")
        .replace("ù", "u")
        .replace("ü", "u")
        .replace("ñ", "n")
    )
    return text


def contains_token(text: str, tokens: list[str]) -> bool:
    return any(token in text for token in tokens)


def guardrail_checks(plan: dict) -> list[str]:
    errors: list[str] = []
    days = plan.get("activityPlan", {}).get("days", [])
    if not isinstance(days, list) or len(days) != 7:
        return errors

    normalized_days = [normalize_day(day.get("day", "")) for day in days]
    unique_days = set(normalized_days)
    if len(unique_days) != 7:
        errors.append("guardrail: days must cover all weekdays exactly once")
    for name in REQUIRED_DAYS:
        if name not in unique_days:
            errors.append(f"guardrail: missing weekday {name}")

    def activity_text(day: dict) -> str:
        return f"{day.get('activity','')} {day.get('goal','')} {day.get('note','')}".lower()

    def intensity_text(day: dict) -> str:
        return (day.get("intensity") or "").lower()

    def is_hard(day: dict) -> bool:
        return contains_token(intensity_text(day), HARD_TOKENS) or contains_token(activity_text(day), HARD_TOKENS)

    def is_easy(day: dict) -> bool:
        return contains_token(intensity_text(day), EASY_TOKENS) or contains_token(activity_text(day), EASY_TOKENS)

    def is_rest(day: dict) -> bool:
        return contains_token(activity_text(day), REST_TOKENS) or (day.get("intensity", "").strip() in {"-", "--", "—", "–"})

    def is_long(day: dict) -> bool:
        return contains_token(activity_text(day), LONG_TOKENS)

    hard_count = sum(1 for day in days if is_hard(day))
    if hard_count > 2:
        errors.append(f"guardrail: too many hard sessions ({hard_count} > 2)")

    for i in range(1, len(days)):
        if is_hard(days[i]) and is_hard(days[i - 1]):
            errors.append(f"guardrail: back-to-back hard sessions (days {i} and {i + 1})")

    if not any(is_rest(day) or is_easy(day) for day in days):
        errors.append("guardrail: must include at least one rest or recovery day")

    long_count = sum(1 for day in days if is_long(day))
    if long_count > 1:
        errors.append("guardrail: only one long run per week")

    for idx, day in enumerate(days, start=1):
        if is_long(day) and is_hard(day):
            errors.append(f"guardrail: long run cannot be hard intensity (day {idx})")

    for name in ["martes", "jueves", "sabado"]:
        day = next((d for d in days if normalize_day(d.get("day", "")) == name), None)
        if day and not contains_token(activity_text(day), GYM_TOKENS):
            errors.append(f"guardrail: {name} should include gym/strength")

    return errors


def diversity_checks(plan: dict) -> list[str]:
    errors: list[str] = []
    days = plan.get("activityPlan", {}).get("days", [])
    if not isinstance(days, list) or len(days) != 7:
        return errors

    activities = {str(day.get("activity", "")).strip().lower() for day in days}
    activities.discard("")
    if len(activities) < 3:
        errors.append("diversity: expected at least 3 unique activity labels")

    def activity_text(day: dict) -> str:
        return f"{day.get('activity','')} {day.get('goal','')} {day.get('note','')}".lower()

    if not any(contains_token(activity_text(day), GYM_TOKENS) for day in days):
        errors.append("diversity: expected at least one gym/strength day")

    if not any(contains_token(activity_text(day), RUN_TOKENS) for day in days):
        errors.append("diversity: expected at least one run session")

    return errors


def limit_checks(plan: dict) -> list[str]:
    errors: list[str] = []
    serialized = json.dumps(plan, ensure_ascii=False, separators=(",", ":"))
    if len(serialized) > 3000:
        errors.append("limits: serialized plan exceeds 3000 characters")
    return errors


def _collect_forbidden_paths(payload: object, prefix: str = "") -> list[str]:
    matches: list[str] = []
    if isinstance(payload, dict):
        for key, value in payload.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            if key in PII_FORBIDDEN_KEYS:
                matches.append(path)
            matches.extend(_collect_forbidden_paths(value, path))
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            path = f"{prefix}[{index}]"
            matches.extend(_collect_forbidden_paths(value, path))
    return matches


def golden_weeks_checks() -> tuple[list[str], dict | None]:
    errors: list[str] = []
    metadata: dict | None = None

    if not GOLDEN_WEEKS_PATH.exists():
        return ["golden_weeks: missing tests/fixtures/golden_weeks_dataset_v1.json"], None
    if not GOLDEN_WEEKS_SCHEMA_PATH.exists():
        return ["golden_weeks: missing schemas/golden_weeks_dataset.schema.json"], None

    schema = load_json(GOLDEN_WEEKS_SCHEMA_PATH)
    dataset = load_json(GOLDEN_WEEKS_PATH)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    schema_errors = sorted(validator.iter_errors(dataset), key=lambda err: list(err.absolute_path))
    if schema_errors:
        first = schema_errors[0]
        where = ".".join(str(part) for part in first.absolute_path) or "<root>"
        return [f"golden_weeks: schema validation failed at {where}: {first.message}"], None

    fixtures = dataset.get("fixtures", [])
    if not isinstance(fixtures, list):
        return ["golden_weeks: fixtures must be an array"], None

    fixture_ids = [str(item.get("fixtureId", "")) for item in fixtures if isinstance(item, dict)]
    if len(set(fixture_ids)) != len(fixture_ids):
        errors.append("golden_weeks: fixtureId values must be unique")

    week_starts = [
        str(item.get("week", {}).get("weekStart", ""))
        for item in fixtures
        if isinstance(item, dict) and isinstance(item.get("week"), dict)
    ]
    if len(set(week_starts)) != len(week_starts):
        errors.append("golden_weeks: week.weekStart values must be unique")

    pii_paths = _collect_forbidden_paths(dataset)
    if pii_paths:
        sample = ", ".join(pii_paths[:5])
        errors.append(f"golden_weeks: forbidden PII-like keys detected ({sample})")

    metadata = {
        "datasetVersion": str(dataset.get("datasetVersion", "unknown")),
        "fixtureCount": len(fixtures),
        "fixtureIds": fixture_ids,
    }
    return errors, metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", help="Write markdown summary to this path.")
    args = parser.parse_args()

    schema = load_json(SCHEMA_PATH)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    valid_paths = sorted(FIXTURES_DIR.glob("weekly_plan_valid_*.json"))
    golden = FIXTURES_DIR / "golden_weekly_plan_snapshot.json"
    if golden.exists():
        valid_paths.append(golden)

    failures: list[str] = []
    lengths: list[int] = []

    for path in valid_paths:
        data = load_json(path)
        errors = list(validator.iter_errors(data))
        if errors:
            failures.append(f"{path.name}: schema validation failed")
            continue

        guardrail = guardrail_checks(data)
        diversity = diversity_checks(data)
        limits = limit_checks(data)
        all_errors = guardrail + diversity + limits
        if all_errors:
            failures.append(f"{path.name}: " + "; ".join(all_errors))
            continue

        lengths.append(len(json.dumps(data, ensure_ascii=False, separators=(",", ":"))))

    golden_errors, golden_meta = golden_weeks_checks()
    failures.extend(golden_errors)
    golden_ok = not golden_errors

    weekly_fixture_total = len(valid_paths)
    total_checks = weekly_fixture_total + 1  # golden weeks dataset validation
    passed = total_checks - len(failures)

    lines = [
        "## Evaluation Harness",
        f"- Weekly plan fixtures checked: {weekly_fixture_total}",
        "- Golden weeks checks: 1",
        f"- Passed: {passed}",
        f"- Failed: {len(failures)}",
    ]
    if lengths:
        avg = sum(lengths) / len(lengths)
        lines.append(f"- Average JSON length: {avg:.1f} chars")
    lines.append(f"- Golden weeks dataset check: {'pass' if golden_ok else 'fail'}")
    if golden_meta:
        lines.append(f"- Golden weeks dataset version: {golden_meta['datasetVersion']}")
        lines.append(f"- Golden weeks fixture count: {golden_meta['fixtureCount']}")
        lines.append("- Golden weeks fixture IDs: " + ", ".join(golden_meta["fixtureIds"]))

    if failures:
        lines.append("\n### Failures")
        lines.extend([f"- {item}" for item in failures])

    summary = "\n".join(lines) + "\n"
    print(summary)

    if args.summary:
        Path(args.summary).write_text(summary)

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
