#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

WORKFLOW_PATH = "workflows/running_coach_workflow.json"
NODE_NAME = "Prompt Builder"
VERSION_RE = re.compile(r"PROMPT_VERSION\s*=\s*\"([^\"]+)\"")
PROMPT_BEGIN = "// PROMPT_BEGIN"
PROMPT_END = "// PROMPT_END"


def run_git(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        check=False,
        text=True,
        capture_output=True,
    )


def load_workflow_from_git(ref: str) -> dict:
    show = run_git(["show", f"{ref}:{WORKFLOW_PATH}"])
    if show.returncode != 0:
        fetch = run_git(["fetch", "origin", "main", "--depth=1"])
        if fetch.returncode != 0:
            print("Failed to fetch origin/main:", fetch.stderr.strip())
            sys.exit(1)
        show = run_git(["show", f"{ref}:{WORKFLOW_PATH}"])
        if show.returncode != 0:
            print("Failed to read workflow from", ref)
            print(show.stderr.strip())
            sys.exit(1)
    return json.loads(show.stdout)


def load_workflow_from_disk() -> dict:
    return json.loads(Path(WORKFLOW_PATH).read_text())


def extract_prompt_and_version(workflow: dict) -> tuple[str | None, str | None]:
    nodes = workflow.get("nodes", [])
    node = next((n for n in nodes if n.get("name") == NODE_NAME), None)
    if not node:
        print(f"Missing node {NODE_NAME}")
        sys.exit(1)
    code = node.get("parameters", {}).get("jsCode", "")
    version_match = VERSION_RE.search(code)
    if not version_match:
        return None, None
    start = code.find(PROMPT_BEGIN)
    end = code.find(PROMPT_END)
    if start == -1 or end == -1 or end <= start:
        return None, None
    prompt_body = code[start + len(PROMPT_BEGIN) : end].strip()
    return prompt_body, version_match.group(1)


def main() -> int:
    base = load_workflow_from_git("origin/main")
    head = load_workflow_from_disk()

    base_prompt, base_version = extract_prompt_and_version(base)
    head_prompt, head_version = extract_prompt_and_version(head)

    if base_prompt is None or base_version is None:
        print("Base prompt versioning not initialized; skipping check.")
        return 0

    if head_prompt is None or head_version is None:
        print("Prompt markers or PROMPT_VERSION missing in workflow.")
        return 1

    if base_prompt != head_prompt and base_version == head_version:
        print("Prompt template changed without bumping PROMPT_VERSION.")
        print(f"Current PROMPT_VERSION: {head_version}")
        return 1

    print("Prompt version check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
