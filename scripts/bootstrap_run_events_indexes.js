/* eslint-disable no-undef */
const dbName = db.getName();
print(`Using database: ${dbName}`);

const ensureTtlIndex = (collection, fieldName, name, expireAfterSeconds) => {
  const existing = collection.getIndexes();
  const ttlIndex = existing.find((idx) => {
    const keys = Object.keys(idx.key || {});
    return idx.expireAfterSeconds != null && keys.length === 1 && keys[0] === fieldName;
  });

  if (ttlIndex && ttlIndex.name !== name) {
    print(`Dropping conflicting TTL index ${ttlIndex.name} on ${collection.getName()}.${fieldName}`);
    collection.dropIndex(ttlIndex.name);
  }

  collection.createIndex(
    { [fieldName]: 1 },
    { expireAfterSeconds, name }
  );
};

db.run_events.createIndex({ runId: 1 }, { unique: true, name: "run_events_runId_unique" });
db.run_events.createIndex({ status: 1, createdAt: -1 }, { name: "run_events_status_createdAt" });
ensureTtlIndex(db.run_events, "createdAt", "run_events_createdAt_ttl", 60 * 60 * 24 * 90);

db.feedback_events.createIndex({ sessionKey: 1 }, { unique: true, name: "feedback_events_sessionKey_unique" });
db.feedback_events.createIndex({ sessionDate: 1, receivedAt: -1 }, { name: "feedback_events_sessionDate_receivedAt" });
db.feedback_events.createIndex({ runId: 1, sessionDay: 1, receivedAt: -1 }, { name: "feedback_events_runId_sessionDay_receivedAt" });
ensureTtlIndex(db.feedback_events, "receivedAt", "feedback_events_receivedAt_ttl", 60 * 60 * 24 * 180);

db.weekly_metrics.createIndex({ weekStart: 1 }, { unique: true, name: "weekly_metrics_weekStart_unique" });
db.weekly_metrics.createIndex({ createdAt: -1 }, { name: "weekly_metrics_createdAt_desc" });

db.plan_snapshots.createIndex({ runId: 1 }, { unique: true, name: "plan_snapshots_runId_unique" });
db.plan_snapshots.createIndex({ weekStart: 1 }, { name: "plan_snapshots_weekStart" });
ensureTtlIndex(db.plan_snapshots, "createdAt", "plan_snapshots_createdAt_ttl", 60 * 60 * 24 * 365);

db.run_artifacts.createIndex({ runId: 1 }, { unique: true, name: "run_artifacts_runId_unique" });
db.run_artifacts.createIndex({ createdAt: -1 }, { name: "run_artifacts_createdAt_desc" });

print("run_events indexes ensured.");
print("feedback_events indexes ensured.");
print("weekly_metrics indexes ensured.");
print("plan_snapshots indexes ensured.");
print("run_artifacts indexes ensured.");
