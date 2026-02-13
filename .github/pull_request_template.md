## What

- 

## Why

- 

## Jira

- Workspace/Board: `Running Coach` (`RC` / board `34`)
- Ticket: RC-
- Epic:
- Sprint:
- Status transition checklist:
  - [ ] moved to `In progress` when work started
  - [ ] moved to `In review` when PR opened
  - [ ] will move to `Done` after merge

## Scope

- [ ] Workflow logic (`workflows/*.json`)
- [ ] Infrastructure / deploy (`Dockerfile`, `fly.toml`, GitHub Actions)
- [ ] Tests (`tests/*`)
- [ ] Docs

## Validation

- [ ] Local checks performed
- [ ] Integration test run (`bash tests/run-it.sh`)
- [ ] CI passed

## Risks & Rollback

- Risk level: Low / Medium / High
- Main risks:
  - 
- Rollback plan:
  - 

## Checklist

- [ ] No secrets committed
- [ ] Secret scan executed (`python3 scripts/scan_secrets.py`)
- [ ] New/changed secrets are stored in secret manager (not in git) and reflected in `docs/secrets_management.md`
- [ ] Backward compatibility considered
- [ ] README/docs updated if behavior changed
- [ ] Branch follows `RC-<id>-<kebab-title>`
- [ ] PR title follows `RC-<id>: short clear title`
- [ ] Jira ticket is in `Running Coach` board (`RC` / board `34`)
