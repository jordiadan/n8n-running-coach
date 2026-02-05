/* eslint-disable no-undef */
const dbName = db.getName();
print(`Using database: ${dbName}`);

const ensureTtlIndex = (collection, name, expireAfterSeconds) => {
  const existing = collection.getIndexes();
  const createdAtIndex = existing.find((idx) => {
    const keys = Object.keys(idx.key || {});
    return keys.length === 1 && keys[0] === "createdAt";
  });

  if (createdAtIndex && createdAtIndex.name !== name) {
    print(`Dropping conflicting index ${createdAtIndex.name} on ${collection.getName()}.createdAt`);
    collection.dropIndex(createdAtIndex.name);
  }

  collection.createIndex(
    { createdAt: 1 },
    { expireAfterSeconds, name }
  );
};

db.run_events.createIndex({ runId: 1 }, { unique: true, name: "run_events_runId_unique" });
db.run_events.createIndex({ status: 1, createdAt: -1 }, { name: "run_events_status_createdAt" });
ensureTtlIndex(db.run_events, "run_events_createdAt_ttl", 60 * 60 * 24 * 90);

db.weekly_metrics.createIndex({ weekStart: 1 }, { unique: true, name: "weekly_metrics_weekStart_unique" });
db.weekly_metrics.createIndex({ createdAt: -1 }, { name: "weekly_metrics_createdAt_desc" });

db.plan_snapshots.createIndex({ runId: 1 }, { unique: true, name: "plan_snapshots_runId_unique" });
db.plan_snapshots.createIndex({ weekStart: 1 }, { name: "plan_snapshots_weekStart" });
ensureTtlIndex(db.plan_snapshots, "plan_snapshots_createdAt_ttl", 60 * 60 * 24 * 365);

print("run_events indexes ensured.");
print("weekly_metrics indexes ensured.");
print("plan_snapshots indexes ensured.");
