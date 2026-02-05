# Prompt Versioning

This repo tracks prompt changes with a simple version string stored in the workflow.

## Policy

- The Prompt Builder defines a single constant `PROMPT_VERSION`.
- Any change to the prompt template must bump `PROMPT_VERSION`.
- The value is persisted to `run_artifacts.promptVersion` for audit and comparison.

## Where it lives

- Workflow: `workflows/running_coach_workflow.json` (Prompt Builder code node).
- Persistence: `run_artifacts` collection (`promptVersion` field).

## Version format

Use a stable, human-readable string. Recommended: `YYYY-MM-DD` or `YYYY-MM-DD.N`.

Example:

```
const PROMPT_VERSION = "2026-02-05";
```
