/* eslint-disable no-undef */
const dbName = db.getName();
print(`Using database: ${dbName}`);

db.run_events.createIndex({ runId: 1 }, { unique: true, name: "run_events_runId_unique" });
db.run_events.createIndex({ createdAt: -1 }, { name: "run_events_createdAt_desc" });
db.run_events.createIndex({ status: 1, createdAt: -1 }, { name: "run_events_status_createdAt" });
db.run_events.createIndex({ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 90, name: "run_events_createdAt_ttl" });

db.weekly_metrics.createIndex({ weekStart: 1 }, { unique: true, name: "weekly_metrics_weekStart_unique" });
db.weekly_metrics.createIndex({ createdAt: -1 }, { name: "weekly_metrics_createdAt_desc" });

db.plan_snapshots.createIndex({ runId: 1 }, { unique: true, name: "plan_snapshots_runId_unique" });
db.plan_snapshots.createIndex({ createdAt: -1 }, { name: "plan_snapshots_createdAt_desc" });
db.plan_snapshots.createIndex({ weekStart: 1 }, { name: "plan_snapshots_weekStart" });
db.plan_snapshots.createIndex({ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 365, name: "plan_snapshots_createdAt_ttl" });

print("run_events indexes ensured.");
print("weekly_metrics indexes ensured.");
print("plan_snapshots indexes ensured.");
