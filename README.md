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
7. Build `git_log`, `git_log_all`, and the analytics cache/views in [`views.sql`](./views.sql).
8. Export final datasets as JSON into `site/data/`.
9. Build a static site into `site/dist/`.
10. Stop PostgreSQL.

GitHub Pages serves only the static artifact. The published site never uses
PostgreSQL at runtime, while an optional live PostgreSQL deployment can expose
the same cache to the direct PostgreSQL Grafana dashboard.
In CI, `INCLUDE_DIFF=false` is used to keep the build practical while preserving
unlimited history.

## Static Site

The published site is fully static but interactive in the browser. It reads the
exported JSON files and lets users:

- select one branch or multiple branches
- filter by one or more Git authors or patch contributors from terminal `Author`
  and `Co-authored-by` trailers
- constrain the visible date range
- switch graph metrics between commits, insertions, deletions, and changed files
- compare branch totals, timeline activity, top authors, and recent matching commits

Author selection uses OR across selected entries, combined with branch and
inclusive date restrictions. The recent table shows the latest 25 rows after
filtering. Selector counts count participating branch/commit rows; activity,
change totals and `authors.json` remain attributed to Git authors.

Email identities merge across these three roles using the recorded local part
(case preserved) and a lowercase domain. The browser supports bare ASCII
dot-atom mailboxes with DNS-style domains, or a display name followed by one
terminal `<email>` pair. It does not remove plus tags or dots, join different
addresses, infer names from addresses, or resolve name-only values to emails.
Unsupported forms remain opaque exact-text groups. Shared email means shared
recorded address, not verified personhood.

Labels prefer a patch-recorded name, then a Git name, breaking ties by Unicode
code-point order. Git-only labels omit email; patch labels include it. Global
labels stay fixed when branch/date scope changes.

The compact selector searches names, addresses and aliases and shows at most
eight choices at a time. With an empty search it suggests the top participants
in the current branch/date scope. Selected authors remain pinned as removable
chips above the search field, and changing or clearing the search never changes
the selection or matching commits. Branch/date changes remove only selections
absent from the complete scope; if none remain, author filtering becomes
unrestricted.

Frontend and browser verification instructions and measured results are in
[`tests/author-filtering-verification.md`](./tests/author-filtering-verification.md).

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
Unknown, syntactically valid trailer labels (such as `Security:`) are ignored
without discarding adjacent supported fields. Extraction still requires a
terminal trailer paragraph: body prose, quoted/indented lines and malformed
labels are not accepted, and raw trailer arrays are never filled from Git metadata.

The Grafana-oriented datasets use explicit `time` and `time_unix_ms` fields for
time-series friendly queries.

Starter Grafana dashboards are included in
[`grafana/apotelesma-starter-dashboard.json`](./grafana/apotelesma-starter-dashboard.json)
for the static JSON export and
[`grafana/apotelesma-postgresql-dashboard.json`](./grafana/apotelesma-postgresql-dashboard.json)
for direct PostgreSQL queries, with setup notes in [`grafana/README.md`](./grafana/README.md).
That directory also documents the offline validator and the live Grafana smoke test for the
Infinity-based dashboard.

## Author/company affiliation research

The [affiliation-history pilot](./docs/author-company-affiliations.md)
keeps dated evidence and reviewed identity mappings in durable, versioned files,
then attributes commit participants using either recorded Git timestamp. It
includes 64 researched people, explicit uncertainty, reproducible
exports, and an independent PostgreSQL schema. The site build derives a compact
`company_affiliations.json` from the exact published commits and exposes a
searchable **Patch author companies** multiselect beside the author/date controls. Select any
number of companies; estimates are included by default and can be excluded.
Company matching uses **`trailer_author` first**. If the full message contains
no `Author:` tag, it uses the Git author (`author_name`/`author_email`), including
co-author-only messages. Missing messages and unresolved or unextracted explicit
authors never trigger fallback. Co-authors remain visible but do not independently
supply company matches; the committer is never substituted. Company and author selections are independent
commit-level filters. The UI
shows coverage and uncertainty, not company sponsorship or population-wide
company totals. Microsoft, Amazon/AWS, Databricks, Snowflake, EDB and Percona
remain searchable; companies without usable patch-author evidence show zero
matches. Aliases share one company identity.
The expanded snapshot combines dated mailing-list evidence with primary company
announcements. It is not an exhaustive employment directory. A read-only
`research-coverage` command inventories every primary-author identity in an export,
including unresolved credits, so coverage gaps remain visible. Automatic mail
collection and exhaustive historical coverage remain future work.
The [REL_19_STABLE audit](./data/author-affiliations/RESEARCH.md)
accounts for all 619 published commits since the June 29, 2026 fork, with
company estimates for 178 (143 explicit patch-author matches and 35 Git-author
fallback matches) and explicit reasons for the remaining gaps.
Its frozen messages also exercise the SQL trailer parser in regression tests.

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

## Live PostgreSQL Commits Cache

`public.commits` is a regular table keyed by `(branch, commit_id)`, not a
materialized view. That composite key is intentional: `git_log_all` removes a
stable-branch commit that is present on the root branch, but the same commit ID
can still occur on more than one non-root branch. `public.daily_activity`
remains a view over `public.commits`, so the PostgreSQL Grafana dashboard keeps
using the same two relation names and needs no datasource or dashboard change.

The cache source is `public.commits_cache_source`, a projection of
`public.git_log_all` with exactly the old `commits` columns and trailer
semantics. Ekorre calls its committer timestamp `commit_date`; all cache
watermarks and overlap filtering use that column, not `author_date`.

### Safe migration

On an existing database, first stop any manual materialized-view refreshes and
run the migration as the owner of `public.commits` (normally `app`):

```sh
psql -X -v ON_ERROR_STOP=1 -f sql/migrate-commits-cache.sql
```

The migration takes a short `ACCESS EXCLUSIVE` lock only for the final relation
switch. In one transaction it validates that `(branch, commit_id)` is unique in
both the old cache and current source, copies the old materialized view,
upserts the full source, removes source-deleted rows, validates source/table
row counts and newest committer timestamp, preserves explicit grants and owner,
and leaves the old materialized view as `public.commits_cache_legacy_mv`. The
state row is written only after the backfill and validation succeed.

Check the post-switch shape and freshness with:

```sql
SELECT relkind = 'r' AS commits_is_table
FROM pg_class
WHERE oid = 'public.commits'::regclass;

SELECT * FROM public.commits_cache_health(interval '2 hours');
SELECT * FROM public.apotelesma_commits_cache_runs ORDER BY run_id DESC LIMIT 20;
```

For rollback, stop the cache scheduler, then run:

```sh
psql -X -v ON_ERROR_STOP=1 -f sql/rollback-commits-cache.sql
```

It restores the retained materialized view and leaves the table as
`public.commits_cache_failed_table` for diagnosis. The retained materialized
view is a switchover snapshot, so it is not current; if the old design must be
kept, explicitly refresh it after rollback. Stop any external job that invokes
the cache sync after rollback.

### Syncing and scheduling

Use the database call below from the scheduler or job mechanism chosen by the
deployment. Apotelesma deliberately does not install a cron job, pg_cron job,
or Kubernetes resource.

Run one normal sync:

```sql
SELECT *
FROM public.sync_commits_cache(
    p_full_reconcile => false,
    p_overlap => interval '14 days',
    p_reconcile_interval => interval '7 days'
);
```

Force a full reconciliation, which detects rewritten/deleted history anywhere
in the source, with:

```sql
SELECT *
FROM public.sync_commits_cache(
    p_full_reconcile => true,
    p_overlap => interval '14 days',
    p_reconcile_interval => interval '7 days'
);
```

The default incremental overlap is 14 days. Every run selects source rows whose
Ekorre `commit_date` is at or newer than the recorded committer-date watermark
minus that overlap, then uses `INSERT ... ON CONFLICT (branch, commit_id) DO
UPDATE`. It also removes source-missing rows inside the overlap. The durable
state chooses a full reconciliation if one has not completed inside the
configured interval, so a restart cannot skip one. A transaction-scoped
advisory lock makes overlapping attempts return `skipped_lock` instead of doing
concurrent work. Successful runs return and log source/inserted/updated/deleted
counts and duration, and record the same metrics in
`apotelesma_commits_cache_runs`.

Schedule the first SQL statement at the desired incremental cadence. Its
`p_reconcile_interval` argument controls when an ordinary incremental call
upgrades itself to a full reconciliation based on durable state; therefore the
scheduler only needs to issue one statement. `p_overlap` and
`p_reconcile_interval` are explicit SQL configuration values, not environment
variables. The returned `status` is `ok` or `skipped_lock`; treat only `ok` as
a completed run. A database role used for this needs `EXECUTE` on
`public.sync_commits_cache` and the privileges required by its owner/security
model to read `git_log_all` and modify the cache.

Before enabling the scheduler against an Ekorre build, inspect the actual
foreign-scan plan:

```sql
EXPLAIN (VERBOSE, COSTS OFF)
SELECT source.branch, source.commit_id, source.commit_date
FROM public.git_log_all AS source
WHERE source.commit_date >= TIMESTAMPTZ '2026-01-01 00:00:00+00';
```

The plan must show `Foreign Scan` nodes beneath `git_log_all` with the literal
`commit_date >= ...` predicate at those scans rather than a full source scan
above the union. `sync_commits_cache` intentionally builds the same literal
predicate, rather than a parameter or `author_date`, to let Ekorre push it into
each branch scan when the installed Ekorre version supports that qualifier.
Treat a plan that does not do this as an Ekorre deployment issue: do not claim
the incremental path is efficient until the FDW is upgraded or fixed.

The self-contained regression suite covers initial backfill, idempotence, new
and late commits, duplicate IDs across branches, rewritten rows, incremental
overlap behavior, full-reconciliation deletion, and the materialized-view
migration:

```sh
./scripts/test-commits-cache.sh
```

## GitHub Actions

The workflow in [`pages.yml`](./.github/workflows/pages.yml) installs PostgreSQL 18, clones both `sxd/ekorre` and the PostgreSQL source repository into cache directories, runs the export pipeline, uploads `site/dist/`, and deploys it to GitHub Pages.
