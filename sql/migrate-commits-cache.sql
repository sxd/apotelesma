\set ON_ERROR_STOP on

-- In-place migration for installations that still have public.commits as a
-- materialized view.  Run this as the owner of the current materialized view
-- (normally app), after stopping any manual REFRESH MATERIALIZED VIEW jobs.
BEGIN;

-- PostgreSQL does not support LOCK TABLE for materialized views. The final
-- ALTER MATERIALIZED VIEW obtains its own exclusive relation lock; this
-- advisory lock coordinates the new cache runner throughout the backfill.
SELECT pg_advisory_xact_lock(hashtextextended('apotelesma.commits-cache', 0));

DO $$
DECLARE
    relation_kind "char";
    expected_columns text[] := ARRAY[
        'branch', 'commit_id', 'author_name', 'author_email', 'author_date',
        'committer_name', 'committer_email', 'commit_date', 'summary',
        'message', 'deltas', 'insertions', 'deletions', 'changed_files',
        'reported_by', 'suggested_by', 'diagnosed_by', 'trailer_author',
        'co_authored_by', 'reviewed_by', 'tested_by', 'bug', 'discussion',
        'backpatch_through', 'mentioned_people', 'mentioned_urls'
    ];
    actual_columns text[];
BEGIN
    SELECT c.relkind
    INTO relation_kind
    FROM pg_class AS c
    WHERE c.oid = to_regclass('public.commits');

    IF relation_kind <> 'm' THEN
        RAISE EXCEPTION
            'Expected public.commits to be a materialized view, found relkind %',
            relation_kind;
    END IF;

    IF to_regclass('public.git_log_all') IS NULL THEN
        RAISE EXCEPTION 'public.git_log_all is required before migrating the commits cache';
    END IF;

    IF to_regclass('public.commits_cache_legacy_mv') IS NOT NULL
       OR to_regclass('public.commits_cache_next') IS NOT NULL THEN
        RAISE EXCEPTION
            'A previous commits-cache migration artifact exists; inspect commits_cache_legacy_mv or commits_cache_next before retrying';
    END IF;

    SELECT array_agg(a.attname ORDER BY a.attnum)
    INTO actual_columns
    FROM pg_attribute AS a
    WHERE a.attrelid = 'public.commits'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF actual_columns IS DISTINCT FROM expected_columns THEN
        RAISE EXCEPTION
            'public.commits columns do not match the supported materialized-view shape: %',
            actual_columns;
    END IF;

    -- The cache key deliberately includes branch.  A commit ID can appear in
    -- multiple non-root branch sources, even though git_log_all suppresses IDs
    -- duplicated by the root branch.
    IF EXISTS (
        SELECT 1
        FROM public.commits
        GROUP BY branch, commit_id
        HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1
        FROM public.git_log_all
        GROUP BY branch, commit_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Cannot migrate: source or existing commits has duplicate (branch, commit_id) rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.commits
        WHERE branch IS NULL OR commit_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM public.git_log_all
        WHERE branch IS NULL OR commit_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'Cannot migrate: source or existing commits has a NULL branch or commit_id';
    END IF;
END;
$$;

\ir commits-cache-source.sql

-- Start from the existing cache so the switch has a backfill even if the Git
-- source is temporarily unavailable after this point.  The source upsert below
-- then brings it current in the same transaction.
CREATE TABLE public.commits_cache_next
    (LIKE public.commits INCLUDING DEFAULTS INCLUDING GENERATED INCLUDING IDENTITY);

INSERT INTO public.commits_cache_next
SELECT *
FROM public.commits;

ALTER TABLE public.commits_cache_next
    ALTER COLUMN branch SET NOT NULL,
    ALTER COLUMN commit_id SET NOT NULL,
    ALTER COLUMN deltas SET NOT NULL,
    ALTER COLUMN insertions SET NOT NULL,
    ALTER COLUMN deletions SET NOT NULL,
    ALTER COLUMN changed_files SET NOT NULL,
    ALTER COLUMN reported_by SET NOT NULL,
    ALTER COLUMN suggested_by SET NOT NULL,
    ALTER COLUMN diagnosed_by SET NOT NULL,
    ALTER COLUMN trailer_author SET NOT NULL,
    ALTER COLUMN co_authored_by SET NOT NULL,
    ALTER COLUMN reviewed_by SET NOT NULL,
    ALTER COLUMN tested_by SET NOT NULL,
    ALTER COLUMN bug SET NOT NULL,
    ALTER COLUMN discussion SET NOT NULL,
    ALTER COLUMN backpatch_through SET NOT NULL,
    ALTER COLUMN mentioned_people SET NOT NULL,
    ALTER COLUMN mentioned_urls SET NOT NULL,
    ADD PRIMARY KEY (branch, commit_id);

INSERT INTO public.commits_cache_next AS cached
SELECT *
FROM public.commits_cache_source
ON CONFLICT (branch, commit_id) DO UPDATE
SET (
    author_name,
    author_email,
    author_date,
    committer_name,
    committer_email,
    commit_date,
    summary,
    message,
    deltas,
    insertions,
    deletions,
    changed_files,
    reported_by,
    suggested_by,
    diagnosed_by,
    trailer_author,
    co_authored_by,
    reviewed_by,
    tested_by,
    bug,
    discussion,
    backpatch_through,
    mentioned_people,
    mentioned_urls
) = (
    EXCLUDED.author_name,
    EXCLUDED.author_email,
    EXCLUDED.author_date,
    EXCLUDED.committer_name,
    EXCLUDED.committer_email,
    EXCLUDED.commit_date,
    EXCLUDED.summary,
    EXCLUDED.message,
    EXCLUDED.deltas,
    EXCLUDED.insertions,
    EXCLUDED.deletions,
    EXCLUDED.changed_files,
    EXCLUDED.reported_by,
    EXCLUDED.suggested_by,
    EXCLUDED.diagnosed_by,
    EXCLUDED.trailer_author,
    EXCLUDED.co_authored_by,
    EXCLUDED.reviewed_by,
    EXCLUDED.tested_by,
    EXCLUDED.bug,
    EXCLUDED.discussion,
    EXCLUDED.backpatch_through,
    EXCLUDED.mentioned_people,
    EXCLUDED.mentioned_urls
);

-- A full source comparison removes entries that disappeared while the old MV
-- was stale, including source rows made invisible by changed branch ancestry.
DELETE FROM public.commits_cache_next AS cached
WHERE NOT EXISTS (
    SELECT 1
    FROM public.commits_cache_source AS source
    WHERE source.branch = cached.branch
      AND source.commit_id = cached.commit_id
);

DO $$
DECLARE
    source_count bigint;
    cache_count bigint;
    source_latest timestamp with time zone;
    cache_latest timestamp with time zone;
BEGIN
    SELECT count(*), max(commit_date)
    INTO source_count, source_latest
    FROM public.commits_cache_source;

    SELECT count(*), max(commit_date)
    INTO cache_count, cache_latest
    FROM public.commits_cache_next;

    IF source_count <> cache_count
       OR source_latest IS DISTINCT FROM cache_latest THEN
        RAISE EXCEPTION
            'Migration validation failed: source rows/latest = %/%, cache rows/latest = %/%',
            source_count, source_latest, cache_count, cache_latest;
    END IF;
END;
$$;

-- Copy explicit ACL entries before the name switch.  The migration is intended
-- to run as the current MV owner, so ownership and existing Grafana SELECT
-- grants carry over without changing datasource configuration.
DO $$
DECLARE
    grant_row record;
    owner_name text;
BEGIN
    FOR grant_row IN
        SELECT
            CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(role.rolname) END AS grantee,
            acl.privilege_type,
            acl.is_grantable
        FROM pg_class AS relation
        CROSS JOIN LATERAL aclexplode(relation.relacl) AS acl
        LEFT JOIN pg_roles AS role
          ON role.oid = acl.grantee
        WHERE relation.oid = 'public.commits'::regclass
    LOOP
        EXECUTE format(
            'GRANT %s ON TABLE public.commits_cache_next TO %s%s',
            grant_row.privilege_type,
            grant_row.grantee,
            CASE WHEN grant_row.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
        );
    END LOOP;

    SELECT quote_ident(role.rolname)
    INTO owner_name
    FROM pg_class AS relation
    JOIN pg_roles AS role
      ON role.oid = relation.relowner
    WHERE relation.oid = 'public.commits'::regclass;

    EXECUTE format('ALTER TABLE public.commits_cache_next OWNER TO %s', owner_name);
END;
$$;

ALTER MATERIALIZED VIEW public.commits RENAME TO commits_cache_legacy_mv;
ALTER TABLE public.commits_cache_next RENAME TO commits;

-- Install the cache state, metrics, indexes, and sync procedure only after
-- public.commits names the regular table.
\ir commits-cache.sql
\ir commits-cache-dependent-views.sql

WITH summary AS (
    SELECT
        clock_timestamp() AS finished_at,
        count(*) AS source_rows,
        max(commit_date) AS source_watermark
    FROM public.commits
), state_upsert AS (
    INSERT INTO public.apotelesma_commits_cache_state AS state (
        singleton,
        last_successful_at,
        last_source_committer_date,
        last_reconciled_at,
        last_run_mode,
        last_source_rows,
        last_inserted,
        last_updated,
        last_deleted,
        last_duration
    )
    SELECT
        true,
        finished_at,
        source_watermark,
        finished_at,
        'migration',
        source_rows,
        source_rows,
        0,
        0,
        interval '0'
    FROM summary
    ON CONFLICT (singleton) DO UPDATE
    SET
        last_successful_at = EXCLUDED.last_successful_at,
        last_source_committer_date = EXCLUDED.last_source_committer_date,
        last_reconciled_at = EXCLUDED.last_reconciled_at,
        last_run_mode = EXCLUDED.last_run_mode,
        last_source_rows = EXCLUDED.last_source_rows,
        last_inserted = EXCLUDED.last_inserted,
        last_updated = EXCLUDED.last_updated,
        last_deleted = EXCLUDED.last_deleted,
        last_duration = EXCLUDED.last_duration
    RETURNING last_successful_at, last_source_committer_date, last_source_rows
)
INSERT INTO public.apotelesma_commits_cache_runs (
    finished_at,
    mode,
    source_rows,
    inserted,
    updated,
    deleted,
    duration,
    source_watermark
)
SELECT
    last_successful_at,
    'migration',
    last_source_rows,
    last_source_rows,
    0,
    0,
    interval '0',
    last_source_committer_date
FROM state_upsert;

DO $$
BEGIN
    RAISE LOG 'apotelesma commits cache migration completed: public.commits is now a table';
END;
$$;

COMMIT;

-- Keep public.commits_cache_legacy_mv for the documented rollback path.  Do
-- not refresh it: it is a snapshot of the old implementation at switchover.
