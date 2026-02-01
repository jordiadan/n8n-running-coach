# n8n Running Coach

An automated running coach built on top of n8n.

This project collects training and wellness data, computes weekly load/recovery metrics, asks an LLM to generate a next-week plan, and sends the plan to Telegram.

## What This Project Does

- Pulls athlete data from Intervals.icu (`activities` + `wellness` endpoints).
- Normalizes and stores data in MongoDB collections.
- Computes weekly metrics (training load, recovery, volume, session mix).
- Merges current week context with recent historical weeks.
- Builds a structured coaching prompt for OpenAI.
- Requests a weekly plan as strict JSON output.
- Formats that output as an HTML message and sends it to Telegram.
- Supports both manual execution and scheduled execution in n8n.

## End-to-End Workflow

Main workflow file: `workflows/running_coach_workflow.json`

1. Trigger:
   - Manual trigger (`When clicking 'Execute workflow'`)
   - Scheduled trigger (`Schedule Trigger`)
2. Data ingestion:
   - `GET Activities` from Intervals.icu
   - `GET Wellness` from Intervals.icu
3. Data shaping + persistence:
   - `Shape Activities` -> Mongo `activities` (upsert)
   - `Shape Wellness` -> Mongo `wellness` (upsert)
4. Weekly feature engineering:
   - `Map Activities + Wellness`
   - `Shape Weekly Metrics` -> Mongo `weekly_metrics` (upsert by `weekStart`)
   - `Read Previous Weeks` -> fetch historical weekly records
   - `Merge Current & History` + `Map Current + History`
5. Prompt + inference:
   - `Prompt Builder` -> builds structured system prompt + context
   - `Message a model` -> OpenAI (configured as `gpt-5` in workflow)
6. Delivery:
   - `Build Telegram Message` -> HTML message body
   - `Send a text message` -> Telegram API node

## Tech Stack

- n8n (workflow orchestration)
- MongoDB (storage for raw and aggregated metrics)
- Intervals.icu API (training + wellness source)
- OpenAI (plan generation)
- Telegram Bot API (plan delivery)
- Docker / Docker Compose (local integration testing)
- GitHub Actions (CI and deployment automation)
- Fly.io (runtime deployment target)

## Repository Layout

- `workflows/running_coach_workflow.json`: n8n workflow definition.
- `tests/run-it.sh`: full integration test runner.
- `tests/mockserver-expectations.json`: mocked API payloads for tests.
- `tests/credentials/mongo.json`: n8n credential fixture for Mongo tests.
- `docker-compose.itest.yml`: test stack (n8n + mongo + mockserver).
- `Dockerfile`: n8n image definition.
- `fly.toml`: Fly.io app config.
- `.github/workflows/ci.yml`: integration tests on PR/push.
- `.github/workflows/deploy-fly.yml`: deploy after successful CI on `main`.

## Scheduling

The workflow includes a cron schedule expression:

- `0 0 21 * * 0` -> every Sunday at 21:00 (n8n timezone dependent).

Production timezone is configured in Fly as `Europe/Madrid`.

## Local Development

This repository currently focuses on integration testing and deployment, not a full local dev compose for production behavior.

You can:

- Import `workflows/running_coach_workflow.json` in your n8n instance.
- Configure credentials in n8n (Intervals.icu, MongoDB, OpenAI, Telegram).
- Execute manually from n8n UI.

## Integration Testing

Run:

```bash
bash tests/run-it.sh
```

What the integration test does:

- Boots `mockserver`, `mongo`, and `n8n` via `docker-compose.itest.yml`.
- Injects mocked Intervals.icu responses into MockServer.
- Imports MongoDB credentials fixture into n8n.
- Patches workflow for test mode:
  - Replaces live Intervals.icu calls with MockServer URLs.
  - Replaces OpenAI + Telegram nodes with deterministic code nodes.
- Imports the patched workflow into n8n.
- Executes it via n8n CLI.
- Verifies that all workflow nodes are executed at least once
  (except schedule trigger, which is intentionally skipped).

## CI/CD

### CI (`.github/workflows/ci.yml`)

Triggers:

- Pull requests to `main`
- Pushes to `main`

Actions:

- Installs test dependencies (including `sqlite3`)
- Runs `bash tests/run-it.sh`
- Uploads `.tmp` artifacts on failure

### Deployment (`.github/workflows/deploy-fly.yml`)

Triggers:

- Successful `CI` workflow completion on `main` push
- Manual `workflow_dispatch`

Required GitHub secrets:

- `FLY_API_TOKEN`
- `N8N_ENCRYPTION_KEY`

Deploy action:

- Stages encryption secret in Fly
- Deploys app using `fly.toml`

## Runtime and Configuration Notes

- The workflow currently contains hardcoded values (for example athlete ID and Telegram chat ID).
- The OpenAI model is configured directly in workflow node settings.
- The Dockerfile sets `DB_TYPE=postgres`; integration tests override this to SQLite.
- For production, ensure DB config and credentials are aligned with your actual infrastructure.

## Security Considerations

- Never commit real API keys, bot tokens, or production credentials.
- Store secrets in n8n credentials and deployment secret managers (GitHub/Fly).
- Keep `N8N_ENCRYPTION_KEY` stable across deployments to preserve credential decryption.
- Prefer least-privilege API scopes for Intervals.icu, Telegram, and OpenAI keys.

## Next Steps

1. Parameterize athlete identity and Telegram destination
   - Move athlete ID/chat ID into env vars or n8n variables.
   - Support multi-athlete or multi-chat operation.
2. Improve configuration hygiene
   - Externalize model selection and planning constants (race date, plan start date).
   - Remove hardcoded logic from code nodes where possible.
3. Strengthen reliability
   - Add retries/backoff and explicit error handling for upstream API failures.
   - Add fallback behavior when one data source is temporarily unavailable.
4. Expand test coverage
   - Add focused tests for each transformation step (weekly metrics, prompt builder, formatter).
   - Add contract tests for Intervals.icu payload shape changes.
5. Harden production operations
   - Align database config across Dockerfile, runtime env, and infrastructure.
   - Add observability (structured logs, alerts, execution failure notifications).
6. Improve coaching output quality
   - Add validation schema for LLM JSON output before Telegram delivery.
   - Track generated plan quality and adherence metrics over time.

## License

No license file is currently included in this repository. Add one if you plan to distribute or open source the project.

