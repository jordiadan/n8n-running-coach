# Grafana Dashboard (Fly + Pushgateway)

This project ships a versioned Grafana dashboard for workflow telemetry:

- `grafana/dashboards/running_coach_workflows.json`

It uses the metric emitted by n8n workflows:

- `running_coach_run_timestamp_seconds{workflow,status,env}`

## Import in Grafana

1. Open Grafana -> **Dashboards** -> **Import**.
2. Upload `grafana/dashboards/running_coach_workflows.json`.
3. Select your Prometheus datasource when prompted.
4. Save.

## Included panels

- Total runs in selected range.
- Successful runs in selected range.
- Failed runs in selected range.
- Success rate by workflow.
- Run trend by workflow/status.
- Last run timestamp by workflow/status.

## Query model

Because the metric value is a timestamp, run counts are derived with `changes(...)`:

- `sum by (workflow,status) (changes(running_coach_run_timestamp_seconds[$__range]))`

This allows counting executions without storing counters in MongoDB.
