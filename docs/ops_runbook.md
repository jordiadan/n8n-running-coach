# Operations Runbook: Weekly Delivery Failure

This runbook is referenced by `RC_ALERT_RUNBOOK_URL` and linked in Telegram failure alerts.

## Trigger

Use this runbook when:
- the weekly workflow run fails, or
- delivery misses the SLA configured by `RC_WEEKLY_DELIVERY_SLA_MINUTES`.

## Immediate Checks

1. Confirm service health:
   - `GET /healthz` on the deployed n8n instance.
2. Confirm latest execution status in n8n:
   - open the latest `Running Coach` execution and identify the failing node.
3. Confirm Mongo connectivity:
   - verify recent writes to `run_events` and `run_artifacts`.
4. Confirm external dependencies:
   - Intervals API reachability
   - OpenAI model availability
   - Telegram API availability

## Containment

1. Pause non-essential workflow changes until incident is resolved.
2. Re-run the workflow manually only after the failing dependency is healthy.
3. If Telegram delivery is failing, send a manual fallback message to the athlete/admin chat.

## Recovery

1. Fix the failing component (credentials, API availability, schema mismatch, or node logic).
2. Re-run a single execution and confirm:
   - `run_events.status = success`
   - `deliveryHealth.missed = false` (or expected for SLA breach tests)
   - Telegram plan message is delivered to the expected chat.
3. Document root cause and corrective action in the Jira ticket.

## Rollback

If the incident was introduced by a recent workflow change:
1. Revert the affected PR in GitHub.
2. Re-import `workflows/running_coach_workflow.json` from the last known-good commit.
3. Re-run one validation execution.
4. Keep the issue in `In review` or `In progress` until a stable fix is merged.
