/* eslint-disable no-undef */
const dbName = db.getName();
print(`Using database: ${dbName}`);

db.run_events.createIndex({ runId: 1 }, { unique: true, name: "run_events_runId_unique" });
db.run_events.createIndex({ createdAt: -1 }, { name: "run_events_createdAt_desc" });
db.run_events.createIndex({ status: 1, createdAt: -1 }, { name: "run_events_status_createdAt" });

print("run_events indexes ensured.");
