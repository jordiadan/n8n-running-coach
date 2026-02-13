#!/usr/bin/env python3
"""Lightweight repository secret scan for obvious credential leaks."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]

# Binary-ish or non-source files we do not need to scan.
SKIP_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".ico",
    ".pdf",
    ".db",
    ".sqlite",
    ".woff",
    ".woff2",
    ".zip",
    ".gz",
}

# Known token formats.
TOKEN_PATTERNS = [
    ("openai_api_key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
    ("github_token", re.compile(r"\bgh[opusr]_[A-Za-z0-9]{20,}\b")),
    ("aws_access_key_id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("telegram_bot_token", re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b")),
]

# Generic assignment pattern catches many accidental hardcoded secrets:
# SOME_SECRET = "verylongvalue..."
GENERIC_ASSIGNMENT = re.compile(
    r"(?ix)"
    r"\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API[_-]?KEY|PRIVATE[_-]?KEY)[A-Z0-9_]*)\b"
    r"\s*[:=]\s*"
    r"['\"]([A-Za-z0-9._/+~-]{16,})['\"]"
)

SAFE_VALUE_MARKERS = {
    "example",
    "placeholder",
    "changeme",
    "your_",
    "xxxx",
    "dummy",
    "sample",
}


def tracked_files() -> Iterable[Path]:
    output = subprocess.check_output(["git", "ls-files"], cwd=REPO_ROOT, text=True)
    for raw in output.splitlines():
        path = REPO_ROOT / raw
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        yield path


def should_skip_value(value: str) -> bool:
    lower = value.lower()
    if any(marker in lower for marker in SAFE_VALUE_MARKERS):
        return True
    if value.startswith("${{") or value.startswith("${"):
        return True
    if value.startswith("<") and value.endswith(">"):
        return True
    return False


def scan_file(path: Path) -> list[tuple[int, str, str]]:
    findings: list[tuple[int, str, str]] = []
    text = path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()

    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        for label, pattern in TOKEN_PATTERNS:
            if pattern.search(line):
                findings.append((index, label, stripped[:200]))

        generic_match = GENERIC_ASSIGNMENT.search(line)
        if generic_match:
            value = generic_match.group(2)
            if not should_skip_value(value):
                findings.append((index, "generic_secret_assignment", stripped[:200]))

    return findings


def main() -> int:
    all_findings: list[tuple[Path, int, str, str]] = []
    for file_path in tracked_files():
        for line, label, snippet in scan_file(file_path):
            all_findings.append((file_path, line, label, snippet))

    if not all_findings:
        print("✅ No obvious hardcoded secrets found in tracked files.")
        return 0

    print("❌ Potential secrets found. Review these lines:")
    for file_path, line, label, snippet in all_findings:
        rel = file_path.relative_to(REPO_ROOT)
        print(f"- {rel}:{line} [{label}] {snippet}")
    print("\nIf these are expected test placeholders, replace with clearer dummy values.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
