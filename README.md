# Apotelesma

Static PostgreSQL branch analytics built at CI time from Git history.

This repository does not contain the `ekorre` FDW source as its own project.
Instead, the build pipeline clones the canonical upstream repository
`https://github.com/sxd/ekorre.git`, builds `ekorre.so` against PostgreSQL 18,
uses that extension inside a temporary PostgreSQL 18 cluster, exports JSON
datasets, and publishes a fully static site.

## Build-Time Pipeline

The pipeline does this:

1. Clone `sxd/ekorre` into a cache directory.
2. Build `ekorre.so` with PostgreSQL 18 using `pg_config`.
3. Start a disposable PostgreSQL 18 cluster.
4. Register the FDW manually from the built shared library.
5. Clone or use a local PostgreSQL source repository.
6. Import one foreign table per branch with `IMPORT FOREIGN SCHEMA`.
7. Build `git_log`, `git_log_all`, and the analytics views in [`views.sql`](./views.sql).
8. Export final datasets as JSON into `site/data/`.
9. Build a static site into `site/dist/`.
10. Stop PostgreSQL.

GitHub Pages serves only the static artifact. PostgreSQL is never used at runtime.
In CI, `INCLUDE_DIFF=false` is used to keep the build practical while preserving
unlimited history.

## Static Site

The published site is fully static but interactive in the browser. It reads the
exported JSON files and lets users:

- select one branch or multiple branches
- filter by one author or multiple authors
- constrain the visible date range
- switch graph metrics between commits, insertions, deletions, and changed files
- compare branch totals, timeline activity, top authors, and recent matching commits

In addition to the site-specific JSON files, the export step also publishes
`site/data/grafana.json`. That file is intended for Grafana consumption and
contains:

- `metadata`
- `trailer_fields`
- `branch_summary`
- `author_summary`
- `daily_activity`
- `trailer_summary`
- `trailer_people_summary`
- `recent_commits`
- `commits`

Commit-level records expose one array per allowed trailer field, plus
`mentioned_people` and `mentioned_urls` for downstream consumers.

The Grafana-oriented datasets use explicit `time` and `time_unix_ms` fields for
time-series friendly queries.

Starter Grafana dashboards are included in
[`grafana/apotelesma-starter-dashboard.json`](./grafana/apotelesma-starter-dashboard.json)
for the static JSON export and
[`grafana/apotelesma-postgresql-dashboard.json`](./grafana/apotelesma-postgresql-dashboard.json)
for direct PostgreSQL queries, with setup notes in [`grafana/README.md`](./grafana/README.md).
That directory also documents the offline validator and the live Grafana smoke test for the
Infinity-based dashboard.

## Branch Model

The default imported branch set is:

- `master`
- `REL_14_STABLE`
- `REL_15_STABLE`
- `REL_16_STABLE`
- `REL_17_STABLE`
- `REL_18_STABLE`

`git_log_all` includes a `branch` column. `master` contains the imported branch
history. Non-master branches include only commits unique to that branch relative
to `master`, matched by `commit_id`.

## Scripts

- [`scripts/prepare-ekorre.sh`](./scripts/prepare-ekorre.sh): clone and build the canonical `ekorre` source tree
- [`scripts/temp-postgres.sh`](./scripts/temp-postgres.sh): bootstrap and control a temporary PostgreSQL 18 cluster
- [`scripts/render-bootstrap-sql.sh`](./scripts/render-bootstrap-sql.sh): generate the branch import SQL and `git_log_all`
- [`scripts/export-json.sh`](./scripts/export-json.sh): export the final datasets to deterministic JSON
- [`scripts/generate-site-data.sh`](./scripts/generate-site-data.sh): run the full build-time pipeline
- [`scripts/build-site.sh`](./scripts/build-site.sh): assemble the static Pages artifact

## Local Usage

Build the site data from a local PostgreSQL clone:

```sh
POSTGRES_REPO=/path/to/postgresql \
./scripts/generate-site-data.sh
```

Useful overrides:

- `PG_CONFIG`
- `EKORRE_SRC_DIR`
- `EKORRE_REPO_URL`
- `EKORRE_REF`
- `BRANCHES`
- `ROOT_BRANCH`
- `INCLUDE_DIFF`
- `MAX_COMMITS`

The GitHub Actions workflow currently keeps `MAX_COMMITS=0` for unlimited
history, but overrides `INCLUDE_DIFF=false`. That CI-specific override was chosen
because a full diff-enabled unlimited-history simulation was too slow in local
end-to-end testing, while the diff-disabled unlimited-history run completed.

## GitHub Actions

The workflow in [`pages.yml`](./.github/workflows/pages.yml) installs PostgreSQL 18, clones both `sxd/ekorre` and the PostgreSQL source repository into cache directories, runs the export pipeline, uploads `site/dist/`, and deploys it to GitHub Pages.
