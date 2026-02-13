# Secrets Management (Fly.io + GitHub + n8n)

This document defines how secrets are stored, rotated, and validated for this repository.

## Principles

- Never commit real credentials to git.
- Keep secrets in secret managers, not in workflow JSON, scripts, or docs.
- Use least-privilege credentials and rotate regularly.
- Treat leaked credentials as incidents: revoke and replace immediately.

## Secret Inventory

### GitHub Actions secrets

- `FLY_API_TOKEN`
  - Used by: `.github/workflows/deploy-fly.yml`
  - Purpose: authenticate `flyctl` for deploy and secret staging.
- `N8N_ENCRYPTION_KEY`
  - Used by: `.github/workflows/deploy-fly.yml` (`flyctl secrets set ...`)
  - Purpose: stable n8n credential encryption/decryption key.
- `N8N_API_KEY`
  - Used by: `.github/workflows/deploy-fly.yml` (workflow update via n8n API)
  - Purpose: authenticate API calls to n8n.

### Runtime/provider secrets (not stored in this repo)

- OpenAI API key
- Telegram bot token
- Intervals.icu credentials
- Any provider-specific API keys used by n8n credentials

These must live in n8n credentials and/or platform secret managers, never in tracked files.

## Deployment Wiring (Fly.io)

- Deploy workflow references only `secrets.*` in GitHub Actions.
- `N8N_ENCRYPTION_KEY` is staged on Fly using:
  - `flyctl secrets set N8N_ENCRYPTION_KEY=... --app running-coach-n8n --stage`
- No raw secret values are echoed in deploy logs.

## Rotation Playbook

Run rotation in non-production first, then production.

1. Prepare replacement credentials in providers (OpenAI/Telegram/etc.).
2. Update GitHub Action secrets:
   - `gh secret set FLY_API_TOKEN`
   - `gh secret set N8N_API_KEY`
   - `gh secret set N8N_ENCRYPTION_KEY` (only when planned; see note below)
3. Update Fly runtime secrets as needed:
   - `flyctl secrets set NAME=value --app running-coach-n8n --stage`
4. Update n8n credentials to use rotated provider keys.
5. Trigger deploy and verify:
   - CI green
   - deploy workflow green
   - workflow update/verification step green
6. Revoke old credentials after verification.

Important:
- Rotating `N8N_ENCRYPTION_KEY` invalidates decryption of existing n8n credentials unless migrated. Plan this as a controlled maintenance operation.

## PR / Release Secret Hygiene Checklist

- Run `python3 scripts/scan_secrets.py` before opening PR.
- Confirm no new hardcoded secrets in changed files.
- If a new secret is required, add it to the appropriate manager (GitHub/Fly/n8n), not to git.
- Document any secret wiring/rotation changes in this file and PR rollback plan.

## Audit Report

### 2026-02-13 (RC-32)

- Automated scan:
  - Command: `python3 scripts/scan_secrets.py`
  - Result: no obvious hardcoded secrets found.
- Manual review:
  - New ops variables (`RC_WEEKLY_DELIVERY_SLA_MINUTES`, `RC_TELEGRAM_ADMIN_CHAT_ID`, `RC_ALERT_RUNBOOK_URL`) are read from env/vars and not hardcoded as secrets in tracked files.

### 2026-02-13 (RC-31)

- Automated scan:
  - Command: `python3 scripts/scan_secrets.py`
  - Result: no obvious hardcoded secrets found.
- Manual review:
  - `.github/workflows/deploy-fly.yml` uses GitHub `secrets.*` inputs for deploy credentials.
  - No raw secret values are committed in tracked files.

## Incident Response (Leak Suspected)

1. Revoke exposed credential immediately.
2. Rotate credential in provider and secret manager.
3. Validate service health and affected integrations.
4. Add a Jira incident/follow-up task with root cause and prevention action.
