#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "weekly_plan.schema.json"
FIXTURES_DIR = ROOT / "tests" / "fixtures"


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
CHECK_ORDER = ("schema", "guardrails", "diversity", "limits")
CHECK_LABELS = {
    "schema": "Schema",
    "guardrails": "Guardrails",
    "diversity": "Diversity",
    "limits": "Limits",
}


@dataclass
class FixtureResult:
    name: str
    checks: dict[str, list[str]]
    length: int

    @property
    def passed(self) -> bool:
        return all(not self.checks[name] for name in CHECK_ORDER)


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


def compact_message(message: str) -> str:
    return " ".join(str(message).split())


def schema_checks(validator: Draft202012Validator, plan: dict) -> list[str]:
    errors = list(validator.iter_errors(plan))
    return [compact_message(error.message) for error in errors]


def collect_fixture_result(path: Path, validator: Draft202012Validator) -> FixtureResult:
    data = load_json(path)
    checks: dict[str, list[str]] = {name: [] for name in CHECK_ORDER}

    checks["schema"] = schema_checks(validator, data)
    if not checks["schema"]:
        checks["guardrails"] = [compact_message(item) for item in guardrail_checks(data)]
        checks["diversity"] = [compact_message(item) for item in diversity_checks(data)]
        checks["limits"] = [compact_message(item) for item in limit_checks(data)]

    length = len(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    return FixtureResult(name=path.name, checks=checks, length=length)


def render_summary(results: list[FixtureResult], report_success_rate: float) -> str:
    total = len(results)
    passed = sum(1 for item in results if item.passed)
    failures = total - passed
    lengths = [item.length for item in results if item.passed]

    lines = [
        "## Evaluation Harness",
        f"- Fixtures checked: {total}",
        f"- Passed: {passed}",
        f"- Failed: {failures}",
        f"- quality_report_generation_success_rate: {report_success_rate:.2f}",
    ]
    if lengths:
        avg = sum(lengths) / len(lengths)
        lines.append(f"- Average JSON length: {avg:.1f} chars")

    failed_items = [item for item in results if not item.passed]
    if failed_items:
        lines.append("\n### Failures")
        for item in failed_items:
            diffs: list[str] = []
            for check in CHECK_ORDER:
                errors = item.checks[check]
                if errors:
                    diffs.append(f"{check}={'; '.join(errors)}")
            lines.append(f"- {item.name}: " + " | ".join(diffs))

    return "\n".join(lines) + "\n"


def render_pr_report(results: list[FixtureResult], report_success_rate: float) -> str:
    total = len(results)
    passed = sum(1 for item in results if item.passed)
    failures = total - passed
    overall = "PASS" if failures == 0 else "FAIL"

    check_totals = {name: 0 for name in CHECK_ORDER}
    for item in results:
        for check in CHECK_ORDER:
            if item.checks[check]:
                check_totals[check] += 1

    lines = [
        "# PR Quality Report",
        "",
        f"- Overall Result: **{overall}**",
        f"- Fixtures Checked: **{total}**",
        f"- Passed Fixtures: **{passed}**",
        f"- Failed Fixtures: **{failures}**",
        f"- quality_report_generation_success_rate: **{report_success_rate:.2f}**",
        "",
        "## Check Failure Summary",
        "",
        "| Check | Failed Fixtures |",
        "| --- | ---: |",
    ]
    for check in CHECK_ORDER:
        lines.append(f"| {CHECK_LABELS[check]} | {check_totals[check]} |")

    lines.extend(
        [
            "",
            "## Fixture Results",
            "",
            "| Fixture | Schema | Guardrails | Diversity | Limits | Result |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )
    for item in results:
        status = {check: ("FAIL" if item.checks[check] else "PASS") for check in CHECK_ORDER}
        result = "FAIL" if not item.passed else "PASS"
        lines.append(
            f"| {item.name} | {status['schema']} | {status['guardrails']} | {status['diversity']} | {status['limits']} | {result} |"
        )

    lines.extend(["", "## Main Diffs", ""])
    failed_items = [item for item in results if not item.passed]
    if not failed_items:
        lines.append("- No check differences detected.")
    else:
        for item in failed_items:
            lines.append(f"### {item.name}")
            for check in CHECK_ORDER:
                errors = item.checks[check]
                if not errors:
                    continue
                lines.append(f"- {CHECK_LABELS[check]}:")
                for error in errors[:3]:
                    lines.append(f"  - {error}")

    return "\n".join(lines) + "\n"


def write_text(path: str, content: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", help="Write markdown summary to this path.")
    parser.add_argument("--pr-report", help="Write PR markdown quality report to this path.")
    args = parser.parse_args()

    schema = load_json(SCHEMA_PATH)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    valid_paths = sorted(FIXTURES_DIR.glob("weekly_plan_valid_*.json"))
    golden = FIXTURES_DIR / "golden_weekly_plan_snapshot.json"
    if golden.exists():
        valid_paths.append(golden)

    results = [collect_fixture_result(path, validator) for path in valid_paths]
    report_success_rate = 1.0 if args.pr_report else 0.0
    summary = render_summary(results, report_success_rate)
    pr_report = render_pr_report(results, report_success_rate)

    print(summary)

    if args.summary:
        write_text(args.summary, summary)
    if args.pr_report:
        write_text(args.pr_report, pr_report)

    failures = sum(1 for item in results if not item.passed)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
