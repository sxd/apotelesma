\set ON_ERROR_STOP on

DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

CREATE TABLE public.git_log_master (
    commit_id text,
    author_name text,
    author_email text,
    author_date timestamp with time zone,
    committer_name text,
    committer_email text,
    commit_date timestamp with time zone,
    summary text,
    message text,
    deltas integer,
    insertions integer,
    deletions integer,
    changed_files integer
);

CREATE TABLE public.git_log_release_one (LIKE public.git_log_master);
CREATE TABLE public.git_log_release_two (LIKE public.git_log_master);

INSERT INTO public.git_log_master
VALUES
    ('shared-root', 'Root Author', 'root@example.test', clock_timestamp() - interval '1 day', 'Root Committer', 'root-committer@example.test', clock_timestamp() - interval '1 day', 'root commit', 'Reviewed-by: Root Reviewer <root-review@example.test>', 1, 2, 1, 1),
    ('master-only', 'Main Author', 'main@example.test', clock_timestamp() - interval '2 days', 'Main Committer', 'main-committer@example.test', clock_timestamp() - interval '2 days', 'master only', 'Bug: https://example.test/master-only', 1, 3, 1, 2),
    ('old-delete', 'Old Author', 'old@example.test', clock_timestamp() - interval '40 days', 'Old Committer', 'old-committer@example.test', clock_timestamp() - interval '40 days', 'will be deleted outside overlap', '', 0, 0, 0, 0);

INSERT INTO public.git_log_release_one
VALUES
    ('shared-root', 'Release Author', 'release@example.test', clock_timestamp() - interval '1 day', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '1 day', 'must be hidden by root', '', 0, 0, 0, 0),
    ('cross-branch', 'Release One', 'release-one@example.test', clock_timestamp() - interval '3 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '3 days', 'same ID as another release branch', 'Tested-by: One Tester <one@example.test>', 1, 1, 0, 1),
    ('release-one-only', 'Release One', 'release-one@example.test', clock_timestamp() - interval '4 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '4 days', 'release one only', '', 0, 0, 0, 0);

INSERT INTO public.git_log_release_two
VALUES
    ('cross-branch', 'Release Two', 'release-two@example.test', clock_timestamp() - interval '5 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '5 days', 'same ID as release one', 'Reviewed-by: Two Reviewer <two@example.test>', 1, 1, 0, 1);

\ir ../views.sql

DO $$
DECLARE
    relation_kind "char";
    actual_columns text[];
    expected_columns text[] := ARRAY[
        'branch', 'commit_id', 'author_name', 'author_email', 'author_date',
        'committer_name', 'committer_email', 'commit_date', 'summary',
        'message', 'deltas', 'insertions', 'deletions', 'changed_files',
        'reported_by', 'suggested_by', 'diagnosed_by', 'trailer_author',
        'co_authored_by', 'reviewed_by', 'tested_by', 'bug', 'discussion',
        'backpatch_through', 'mentioned_people', 'mentioned_urls'
    ];
BEGIN
    SELECT relkind INTO relation_kind
    FROM pg_class
    WHERE oid = 'public.commits'::regclass;
    IF relation_kind <> 'r' THEN
        RAISE EXCEPTION 'initial backfill did not create a regular commits table';
    END IF;

    SELECT array_agg(attname ORDER BY attnum)
    INTO actual_columns
    FROM pg_attribute
    WHERE attrelid = 'public.commits'::regclass
      AND attnum > 0
      AND NOT attisdropped;
    IF actual_columns IS DISTINCT FROM expected_columns THEN
        RAISE EXCEPTION 'commits output columns changed: %', actual_columns;
    END IF;

    IF (SELECT count(*) FROM public.commits) <> 6 THEN
        RAISE EXCEPTION 'initial backfill row count is wrong';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.commits
        WHERE branch = 'release_one'
          AND commit_id = 'shared-root'
    ) THEN
        RAISE EXCEPTION 'root branch de-duplication semantics were not preserved';
    END IF;

    IF (SELECT count(*) FROM public.commits WHERE commit_id = 'cross-branch') <> 2 THEN
        RAISE EXCEPTION 'duplicate commit IDs across branches were not preserved';
    END IF;
END;
$$;

CREATE TEMP TABLE sync_result AS
SELECT *
FROM public.sync_commits_cache(false, interval '14 days', interval '365 days');

DO $$
DECLARE
    result record;
BEGIN
    SELECT * INTO result FROM sync_result;
    IF result.status <> 'ok'
       OR result.mode <> 'incremental'
       OR result.inserted <> 0
       OR result.updated <> 0
       OR result.deleted <> 0 THEN
        RAISE EXCEPTION 'repeat sync was not idempotent: %', result;
    END IF;
END;
$$;

INSERT INTO public.git_log_master
VALUES (
    'new-commit', 'New Author', 'new@example.test', clock_timestamp(),
    'New Committer', 'new-committer@example.test', clock_timestamp(),
    'new commit', 'Reported-by: New Reporter <new-reporter@example.test>',
    1, 5, 2, 1
);

TRUNCATE sync_result;
INSERT INTO sync_result
SELECT *
FROM public.sync_commits_cache(false, interval '14 days', interval '365 days');

DO $$
DECLARE
    result record;
BEGIN
    SELECT * INTO result FROM sync_result;
    IF result.inserted <> 1
       OR NOT EXISTS (SELECT 1 FROM public.commits WHERE branch = 'master' AND commit_id = 'new-commit') THEN
        RAISE EXCEPTION 'new commit was not incrementally inserted: %', result;
    END IF;
END;
$$;

INSERT INTO public.git_log_master
VALUES (
    'late-commit', 'Late Author', 'late@example.test', clock_timestamp() - interval '5 days',
    'Late Committer', 'late-committer@example.test', clock_timestamp() - interval '5 days',
    'late but inside overlap', '', 0, 0, 0, 0
);

TRUNCATE sync_result;
INSERT INTO sync_result
SELECT *
FROM public.sync_commits_cache(false, interval '14 days', interval '365 days');

DO $$
DECLARE
    result record;
BEGIN
    SELECT * INTO result FROM sync_result;
    IF result.inserted <> 1
       OR NOT EXISTS (SELECT 1 FROM public.commits WHERE branch = 'master' AND commit_id = 'late-commit') THEN
        RAISE EXCEPTION 'late/backdated commit inside overlap was not inserted: %', result;
    END IF;
END;
$$;

UPDATE public.git_log_master
SET summary = 'rewritten new commit',
    message = 'Reviewed-by: Rewritten Reviewer <rewrite@example.test>'
WHERE commit_id = 'new-commit';

TRUNCATE sync_result;
INSERT INTO sync_result
SELECT *
FROM public.sync_commits_cache(false, interval '14 days', interval '365 days');

DO $$
DECLARE
    result record;
BEGIN
    SELECT * INTO result FROM sync_result;
    IF result.updated <> 1
       OR (SELECT summary FROM public.commits WHERE branch = 'master' AND commit_id = 'new-commit') <> 'rewritten new commit' THEN
        RAISE EXCEPTION 'rewritten commit was not updated: %', result;
    END IF;
END;
$$;

DELETE FROM public.git_log_master
WHERE commit_id = 'old-delete';

TRUNCATE sync_result;
INSERT INTO sync_result
SELECT *
FROM public.sync_commits_cache(false, interval '7 days', interval '365 days');

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.commits WHERE branch = 'master' AND commit_id = 'old-delete') THEN
        RAISE EXCEPTION 'incremental sync unexpectedly deleted a row outside its overlap';
    END IF;
END;
$$;

TRUNCATE sync_result;
INSERT INTO sync_result
SELECT *
FROM public.sync_commits_cache(true, interval '7 days', interval '365 days');

DO $$
DECLARE
    result record;
BEGIN
    SELECT * INTO result FROM sync_result;
    IF result.mode <> 'reconcile'
       OR result.deleted <> 1
       OR EXISTS (SELECT 1 FROM public.commits WHERE branch = 'master' AND commit_id = 'old-delete') THEN
        RAISE EXCEPTION 'full reconciliation did not remove deleted history: %', result;
    END IF;

    IF (SELECT sum(commit_count) FROM public.daily_activity) <> (SELECT count(*) FROM public.commits) THEN
        RAISE EXCEPTION 'daily_activity is not compatible with the commits cache';
    END IF;
END;
$$;

-- Exercise the in-place migration from the materialized-view layout.  The
-- bootstrap above already provides the real source projection and parser
-- functions, so this is the same relation shape deployed before the change.
DROP MATERIALIZED VIEW public.authors;
DROP TABLE public.commits CASCADE;
CREATE MATERIALIZED VIEW public.commits AS
SELECT *
FROM public.commits_cache_source;

CREATE ROLE commits_cache_reader;
GRANT USAGE ON SCHEMA public TO commits_cache_reader;
GRANT SELECT ON public.commits TO commits_cache_reader;

\ir ../sql/migrate-commits-cache.sql

DO $$
DECLARE
    relation_kind "char";
    source_count bigint;
    cache_count bigint;
    source_latest timestamp with time zone;
    cache_latest timestamp with time zone;
BEGIN
    SELECT relkind INTO relation_kind
    FROM pg_class
    WHERE oid = 'public.commits'::regclass;
    IF relation_kind <> 'r' THEN
        RAISE EXCEPTION 'migration did not replace the MV with a table';
    END IF;

    IF (SELECT relkind FROM pg_class WHERE oid = 'public.commits_cache_legacy_mv'::regclass) <> 'm' THEN
        RAISE EXCEPTION 'migration did not retain the legacy MV for rollback';
    END IF;

    SELECT count(*), max(commit_date)
    INTO source_count, source_latest
    FROM public.commits_cache_source;
    SELECT count(*), max(commit_date)
    INTO cache_count, cache_latest
    FROM public.commits;
    IF source_count <> cache_count OR source_latest IS DISTINCT FROM cache_latest THEN
        RAISE EXCEPTION 'migration validation was not preserved';
    END IF;

    IF (SELECT last_run_mode FROM public.apotelesma_commits_cache_state WHERE singleton) <> 'migration' THEN
        RAISE EXCEPTION 'migration did not record successful cache state';
    END IF;
END;
$$;

SET ROLE commits_cache_reader;
SELECT count(*) FROM public.commits;
RESET ROLE;

\ir ../sql/rollback-commits-cache.sql

DO $$
BEGIN
    IF (SELECT relkind FROM pg_class WHERE oid = 'public.commits'::regclass) <> 'm' THEN
        RAISE EXCEPTION 'rollback did not restore public.commits as a materialized view';
    END IF;

    IF (SELECT sum(commit_count) FROM public.daily_activity) <> (SELECT count(*) FROM public.commits) THEN
        RAISE EXCEPTION 'rollback did not restore compatible derived views';
    END IF;
END;
$$;

SELECT 'commits cache tests passed' AS result;
