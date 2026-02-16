# Data Lineage

This document captures the MongoDB collections written by the workflows and how they are produced.

## Collections

### run_events

Purpose: execution-level observability for weekly plan generation.

Written by:
- `Build Run Event (success)` + `Run Events DB (success)`
- `Build Failure Event` + `Run Events DB (failure)`

Fields (top-level):
- `runId` (string, unique): generated per execution.
- `status` (string): `success` or `failure`.
- `attempt` (number | null): validation attempt that produced the final output.
- `weekStart` (string | null): `YYYY-MM-DD` from `activityPlan.nextWeek`.
- `weekEnd` (string | null): `YYYY-MM-DD` from `activityPlan.nextWeek`.
- `errorCount` (number): number of validation errors.
- `errors` (array): validation error list.
- `createdAt` (string): ISO timestamp.

Nested fields:
- `runEvent` (object): a copy of the run event payload for reference.

Notes:
- The workflow uses `findOneAndUpdate` with `updateKey: runId`, so `runId` must be present.

### feedback_events

Purpose: capture Telegram feedback for completed sessions (done/skipped/hard/pain).

Written by:
- `Parse Feedback` + `Feedback Events DB` (MongoDB node).
- Workflow: `workflows/running_coach_feedback_workflow.json`

Fields (top-level):
- `sessionId` (string): session identifier encoded in callback payload (`session_feedback|runId|sessionId|type`).
- `sessionKey` (string, unique): `${runId}-${sessionId}-${userId|anon}` for idempotency.
- `sessionRef` (string): `${runId}-${sessionId}` reference for a prompted session.
- `runId` (string): links feedback to the originating plan run.
- `type` (string): `done`, `skipped`, `hard`, or `pain`.
- `response` (string): backward-compatible alias of `type`.
- `note` (string | null): optional user note (when provided in callback payload).
- `sessionDate` (string): `YYYY-MM-DD` derived from Telegram message timestamp.
- `date` (string): alias of `sessionDate`.
- `sessionDay` (string): weekday label (e.g., `Monday`).
- `day` (string): alias of `sessionDay`.
- `chatId` (string | null): Telegram chat ID.
- `messageId` (number | null): Telegram message ID.
- `userId` (string | number | null): Telegram user ID.
- `username` (string | null): Telegram username.
- `timestamp` (string): ISO timestamp when feedback was received.
- `receivedAt` (string): ISO timestamp when feedback was received.

Notes:
- The workflow uses `findOneAndUpdate` with `updateKey: sessionKey` to prevent duplicates.
- Late feedback (`isLateResponse=true`) is acknowledged but not persisted.

### weekly_metrics

Purpose: historical rollups used to provide context for weekly plan generation.

Written by:
- `Weekly Metrics DB` (MongoDB node).

Key fields:
- `athleteId`
- `weekStart`, `weekEnd`
- `runCount`, `runDistance`, `runTime`
- `rideCount`, `rideDistance`, `rideTime`
- `vo2Sessions`, `tempoSessions`, `longRuns`
- `strengthCount`, `strengthTrimp`
- `ctlMean`, `atlMean`, `rampRateMean`
- `restHrMean`, `stepsMean`, `sleepScoreMean`, `hrvMean`
- `createdAt`, `updatedAt`

### plan_snapshots

Purpose: store successful weekly plan outputs for audit and comparison.

Written by:
- `Plan Snapshots DB` (MongoDB node).

Fields (top-level):
- `runId` (string, unique): linked to run_events.
- `attempt` (number | null): validation attempt that produced the plan.
- `weekStart`, `weekEnd` (string): `YYYY-MM-DD`.
- `schema_version` (string).
- `activityPlan` (object).
- `justification` (array).
- `createdAt` (string): ISO timestamp.

Notes:
- `runId` is the update key for upserts.

### run_artifacts

Purpose: capture inputs, model metadata, and outputs for each run to enable audit/debugging.

Written by:
- `Run Artifacts DB (inputs)` (MongoDB node).
- `Build Run Artifact (outputs)` + `Run Artifacts DB (outputs)`.

Fields (top-level):
- `runId` (string, unique): linked to run_events and plan_snapshots.
- `promptVersion` (string): prompt version identifier.
- `modelId` (string): LLM model name.
- `prompt` (string): system prompt sent to the model.
- `metrics` (object): computed weekly metrics.
- `history` (array): prior week summaries.
- `activities` (array): raw activity inputs.
- `wellness` (array): raw wellness inputs.
- `status` (string): `success` or `failure`.
- `attempt` (number | null): validation attempt used for final output.
- `outputValidated` (object | null): validated WeeklyPlan payload.
- `outputRaw` (string | null): raw model output (minified JSON string).
- `errors` (array): validation errors (if any).
- `errorCount` (number): number of validation errors.
- `createdAt` (string): ISO timestamp for input capture.
- `updatedAt` (string): ISO timestamp for output capture.

Notes:
- `runId` is the update key for upserts.

## Indexes

Recommended indexes for `run_events`:
- Unique: `{ runId: 1 }`
- Status filter: `{ status: 1, createdAt: -1 }`
- TTL: `{ createdAt: 1 }` (90 days)

Recommended indexes for `feedback_events`:
- Unique: `{ sessionKey: 1 }`
- Date lookups: `{ sessionDate: 1, receivedAt: -1 }`
- Session/day lookups: `{ runId: 1, sessionDay: 1, receivedAt: -1 }`
- TTL: `{ receivedAt: 1 }` (180 days)

Recommended indexes for `weekly_metrics`:
- Unique: `{ weekStart: 1 }` (single-athlete assumption)
- Time-based lookup: `{ createdAt: -1 }`

Recommended indexes for `plan_snapshots`:
- Unique: `{ runId: 1 }`
- Week lookups: `{ weekStart: 1 }`
- TTL: `{ createdAt: 1 }` (365 days)

Recommended indexes for `run_artifacts`:
- Unique: `{ runId: 1 }`
- Time-based lookup: `{ createdAt: -1 }`

## Retention Guidance

- `run_events`: keep at least 90 days of history for debugging/alert review.
- `weekly_metrics`: keep at least 12 months to preserve training trends.
- `plan_snapshots`: keep at least 12 months for audit and comparison.
- `run_artifacts`: keep at least 12 months for audit and debugging.

## Observability Guidance

- `feedback_event_write_success_rate`:
  - Numerator: count of non-late feedback callbacks written to `feedback_events`.
  - Denominator: count of non-late feedback callbacks received by `Parse Feedback`.

## Bootstrap

Run with a MongoDB connection string that has permissions to create indexes:

```bash
mongosh "$MONGO_URL" --file scripts/bootstrap_run_events_indexes.js
```
