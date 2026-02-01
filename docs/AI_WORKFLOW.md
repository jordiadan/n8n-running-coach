# AI / Codex Workflow Rules

This document defines the required execution workflow for AI agents and contributors.
If there is any conflict with other docs, this file is the source of truth.

Jira board:
- `https://jordiadan.atlassian.net/jira/software/projects/RC/boards/34/backlog`
- Board name: `Running Coach`

The authoritative Jira workspace for this repo is `Running Coach` (project `RC`, board `34`). Do not use any other Jira board for active work on this repository.

## 1) One Jira ticket = one branch

- Always start from an up-to-date `main`.
- Branch naming format:
  - `RC-<id>-<task-title-in-kebab-case>`
  - Example: `RC-123-add-migrate-mongo-bootstrap`
- Before starting work:
  - ticket must exist in `Running Coach` board
  - ticket must be in the active sprint
  - ticket must be assigned to the work owner
  - ticket must be linked to the correct epic

Kebab-case rules:
- lowercase only
- spaces become `-`
- normalize accents to base letters
- remove special characters (`/`, `:`, `?`, etc.)

## 2) One task = one Pull Request

- Never mix multiple tickets in one PR.
- If extra scope appears:
  - create a new Jira ticket
  - create a new branch
  - open a separate PR

## 3) Commit conventions

- Small, incremental commits.
- Commit message format:
  - `RC-<id>: short description`
  - Example: `RC-123: add mongo migration bootstrap`

## 4) PR conventions

- PR title format:
  - `RC-<id>: short clear title`
- Every PR must use `.github/pull_request_template.md`.
- No direct pushes to `main` or `master`.

Required Jira status transitions:
- Move issue to `In progress` when branch is created.
- Move issue to `In review` when PR is opened.
- Move issue to `Done` only after merge.

## 5) Minimum checks before opening a PR

- tests pass
- lint/format checks pass
- no dead code
- docs updated when behavior changes
- rollback plan included in PR description

## 6) Execution flow (exact order)

1. Sync main
   - `git checkout main`
   - `git pull --rebase`
2. Create branch
   - `git checkout -b RC-<id>-<task-title>`
3. Implement with small commits
4. Run local checks/tests
5. Push branch
   - `git push -u origin <branch>`
6. Open PR using template
7. Update Jira statuses according to the required transitions
