\set ON_ERROR_STOP on

-- Emergency rollback for sql/migrate-commits-cache.sql.  This restores the
-- materialized-view relation retained by that migration.  Stop the scheduler
-- first; this script intentionally does not restart old REFRESH jobs.
BEGIN;

LOCK TABLE public.commits IN ACCESS EXCLUSIVE MODE;

DO $$
DECLARE
    cache_kind "char";
    legacy_kind "char";
BEGIN
    SELECT relkind INTO cache_kind
    FROM pg_class
    WHERE oid = to_regclass('public.commits');
    SELECT relkind INTO legacy_kind
    FROM pg_class
    WHERE oid = to_regclass('public.commits_cache_legacy_mv');

    IF cache_kind <> 'r' OR legacy_kind <> 'm' THEN
        RAISE EXCEPTION
            'Rollback expects table public.commits and materialized view public.commits_cache_legacy_mv, found % and %',
            cache_kind, legacy_kind;
    END IF;

    IF to_regclass('public.commits_cache_failed_table') IS NOT NULL THEN
        RAISE EXCEPTION
            'public.commits_cache_failed_table already exists; inspect it before retrying rollback';
    END IF;
END;
$$;

ALTER TABLE public.commits RENAME TO commits_cache_failed_table;
ALTER MATERIALIZED VIEW public.commits_cache_legacy_mv RENAME TO commits;

-- Point compatible derived views back at the restored MV.  This does not
-- restore freshness; run a manual REFRESH only if reverting to the old model.
\ir commits-cache-dependent-views.sql

COMMIT;
