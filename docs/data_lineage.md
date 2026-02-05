# Data Lineage

This document captures the MongoDB collections written by the workflow and how they are produced.

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

## Indexes

Recommended indexes for `run_events`:
- Unique: `{ runId: 1 }`
- Time-based lookup: `{ createdAt: -1 }`
- Status filter: `{ status: 1, createdAt: -1 }`

## Bootstrap

Run with a MongoDB connection string that has permissions to create indexes:

```bash
mongosh "$MONGO_URL" --file scripts/bootstrap_run_events_indexes.js
```
