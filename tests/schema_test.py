#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "weekly_plan.schema.json"
FIXTURES_DIR = ROOT / "tests" / "fixtures"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def validate(path: Path, validator: Draft202012Validator) -> list:
    data = load_json(path)
    return sorted(validator.iter_errors(data), key=lambda e: list(e.path))


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    valid_files = sorted(FIXTURES_DIR.glob("weekly_plan_valid_*.json"))
    invalid_files = sorted(FIXTURES_DIR.glob("weekly_plan_invalid_*.json"))

    if len(valid_files) < 3 or len(invalid_files) < 3:
        print("Expected at least 3 valid and 3 invalid fixtures.")
        return 1

    failed = False

    for path in valid_files:
        errors = validate(path, validator)
        if errors:
            failed = True
            print(f"[FAIL] Expected valid but found errors: {path.name}")
            for err in errors:
                loc = ".".join([str(p) for p in err.path]) or "(root)"
                print(f"  - {loc}: {err.message}")

    for path in invalid_files:
        errors = validate(path, validator)
        if not errors:
            failed = True
            print(f"[FAIL] Expected invalid but found no errors: {path.name}")

    if failed:
        return 1

    print("Schema tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
