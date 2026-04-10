# Grafana Starter

This directory contains a starter dashboard for the exported
[`site/data/grafana.json`](../site/data/grafana.json) dataset and a second starter dashboard
that queries PostgreSQL directly.

Available dashboards:

- [`apotelesma-starter-dashboard.json`](./apotelesma-starter-dashboard.json): static JSON over HTTP via the Infinity datasource
- [`apotelesma-postgresql-dashboard.json`](./apotelesma-postgresql-dashboard.json): direct SQL queries via Grafana's built-in PostgreSQL datasource

## Plugin Requirement

The dashboard uses the Infinity datasource plugin:

- plugin id: `yesoreyeram-infinity-datasource`
- plugin docs: <https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/setup/installation/>

Install it before importing the dashboard.

### Install In Grafana UI

1. Open Grafana.
2. Go to `Administration` -> `Plugins and data` -> `Plugins`.
3. Search for `Infinity`.
4. Open the `Infinity` datasource plugin page and install it.
5. Restart Grafana if your deployment requires it.

### Install With `grafana-cli`

Official plugin docs currently list this command:

```sh
grafana-cli plugins install yesoreyeram-infinity-datasource
```

Restart Grafana after the install.

### Install In Docker

Grafana also supports preinstalling plugins at container start. The current
Infinity plugin docs use `GF_PLUGINS_PREINSTALL_SYNC` for this. A simple example is:

```sh
docker run --rm -p 3000:3000 \
  -e GF_PLUGINS_PREINSTALL_SYNC=yesoreyeram-infinity-datasource \
  grafana/grafana
```

### Restricted Or Air-Gapped Environments

The official Infinity plugin docs also describe manual installation from a downloaded release archive.
Use that path when the Grafana host cannot reach `grafana.com` directly.

## Create The Datasource

After the plugin is installed:

1. Go to `Connections` -> `Data sources`.
2. Click `Add new data source`.
3. Choose `Infinity`.
4. Name it something obvious, for example `Apotelesma Infinity`.
5. Save the datasource.

This dashboard uses per-panel URLs, so the datasource itself does not need a fixed base URL.

## Import The Dashboard

1. Open `Dashboards` -> `New` -> `Import`.
2. Upload [`apotelesma-starter-dashboard.json`](./apotelesma-starter-dashboard.json) or paste its JSON.
3. When Grafana asks for `DS_INFINITY`, select your Infinity datasource instance.
4. Import the dashboard.
5. Set the `grafana_json_url` dashboard variable to the exported JSON URL.

Examples:

- Published project site:

```text
https://code.emacs.cl/apotelesma/data/grafana.json
```

- Local static preview served from this repository:

```text
http://127.0.0.1:8000/data/grafana.json
```

## What The Dashboard Shows

The starter dashboard is intentionally close to the static site:

- daily commit count by branch
- daily insertions by branch
- branch summary table
- top authors table
- recent commits table with summary and churn columns

If the export was built with `INCLUDE_DIFF=false`, the churn-related fields
(`total_insertions`, `total_deletions`, `total_changed_files`, `insertions`,
`deletions`, `changed_files`) will be present but zeroed by design. In that
mode, the most useful panels are commit-count, branch, author, and recent-commit
views.

## Troubleshooting

If Grafana says the datasource type is missing:

1. Install the Infinity plugin first.
2. Restart Grafana.
3. Re-import the dashboard.

If the panels load but show no data:

1. Verify the `grafana_json_url` value points to a reachable `grafana.json`.
2. Remember that Infinity backend queries are executed by Grafana, not by your browser.
3. Make sure the Grafana server can reach that URL from its own network namespace.

Common local cases:

- Grafana running directly on your machine can use `http://127.0.0.1:8000/data/grafana.json`.
- Grafana running in Docker may need `--network host` on Linux, or `http://host.docker.internal:8000/data/grafana.json` on Docker Desktop.

## Validate The Dashboard

This repository includes a validation script that checks the starter dashboard against a generated
[`site/data/grafana.json`](../site/data/grafana.json) export:

```sh
python3 scripts/validate-grafana-dashboard.py
```

The script verifies:

- every panel root selector exists
- every selected column exists
- the result sets are non-empty

## Smoke Test In Grafana

This repository also includes a live smoke test that exercises the dashboard through Grafana itself:

```sh
python3 scripts/smoke-test-grafana.py
```

What it does:

- serves `site/dist` locally
- starts a temporary Grafana container
- installs the Infinity plugin
- creates an `Apotelesma Infinity` datasource
- imports the starter dashboard
- queries every panel through Grafana's datasource API

Useful environment overrides:

- `SITE_PORT=18000`
- `GRAFANA_PORT=3300`
- `GRAFANA_IMAGE=grafana/grafana`
- `GRAFANA_JSON_URL=http://host.docker.internal:18000/data/grafana.json`

Notes:

- the smoke test needs Docker
- the Grafana container must be able to reach `grafana.com` to download the Infinity plugin unless you use a custom image that already includes it

## PostgreSQL Dashboard

[`apotelesma-postgresql-dashboard.json`](./apotelesma-postgresql-dashboard.json) queries the
database directly and does not require the Infinity plugin.

### PostgreSQL Datasource

Use Grafana's built-in PostgreSQL datasource. Official docs:
<https://grafana.com/docs/grafana/latest/datasources/postgres/>

The dashboard expects the relations created by [`views.sql`](../views.sql), specifically:

- `commits`
- `daily_activity`

If the underlying repository data changes, refresh the materialized views before relying on the
dashboard:

```sql
REFRESH MATERIALIZED VIEW authors;
REFRESH MATERIALIZED VIEW commits;
```

The Grafana database user needs `SELECT` access to the relations the dashboard queries:

```sql
GRANT SELECT ON commits, daily_activity TO grafana_reader;
```

### Import The PostgreSQL Dashboard

1. Create a PostgreSQL datasource in Grafana that points at the database populated by Apotelesma.
2. Open `Dashboards` -> `New` -> `Import`.
3. Upload [`apotelesma-postgresql-dashboard.json`](./apotelesma-postgresql-dashboard.json) or paste its JSON.
4. When Grafana asks for `DS_POSTGRES`, select your PostgreSQL datasource.
5. Import the dashboard.

Notes:

- this dashboard uses Grafana's time picker directly in SQL with `$__timeFilter(...)`
- unlike the static JSON dashboard, it does not need a `grafana_json_url` variable
- if the dataset was generated with `INCLUDE_DIFF=false`, churn columns remain present but zero-valued here as well
