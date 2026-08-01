-- Table-backed, incrementally maintained replacement for the commits
-- materialized view.  This file is idempotent once public.commits is a table.

DO $$
DECLARE
    relation_kind "char";
BEGIN
    SELECT c.relkind
    INTO relation_kind
    FROM pg_class AS c
    WHERE c.oid = to_regclass('public.commits');

    IF relation_kind IS NOT NULL AND relation_kind <> 'r' THEN
        RAISE EXCEPTION
            'public.commits is not a table (relkind %); run sql/migrate-commits-cache.sql first',
            relation_kind;
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.commits (
    branch text NOT NULL,
    commit_id text NOT NULL,
    author_name text,
    author_email text,
    author_date timestamp with time zone,
    committer_name text,
    committer_email text,
    commit_date timestamp with time zone,
    summary text,
    message text,
    deltas integer NOT NULL,
    insertions integer NOT NULL,
    deletions integer NOT NULL,
    changed_files integer NOT NULL,
    reported_by text[] NOT NULL,
    suggested_by text[] NOT NULL,
    diagnosed_by text[] NOT NULL,
    trailer_author text[] NOT NULL,
    co_authored_by text[] NOT NULL,
    reviewed_by text[] NOT NULL,
    tested_by text[] NOT NULL,
    bug text[] NOT NULL,
    discussion text[] NOT NULL,
    backpatch_through text[] NOT NULL,
    mentioned_people text[] NOT NULL,
    mentioned_urls text[] NOT NULL,
    PRIMARY KEY (branch, commit_id)
);

CREATE INDEX IF NOT EXISTS commits_author_date_idx
    ON public.commits (author_date DESC);
CREATE INDEX IF NOT EXISTS commits_commit_date_idx
    ON public.commits (commit_date DESC);
CREATE INDEX IF NOT EXISTS commits_branch_author_date_idx
    ON public.commits (branch, author_date DESC);

CREATE TABLE IF NOT EXISTS public.apotelesma_commits_cache_state (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    last_successful_at timestamp with time zone NOT NULL,
    last_source_committer_date timestamp with time zone,
    last_reconciled_at timestamp with time zone,
    last_run_mode text NOT NULL CHECK (last_run_mode IN ('incremental', 'reconcile', 'migration')),
    last_source_rows bigint NOT NULL,
    last_inserted bigint NOT NULL,
    last_updated bigint NOT NULL,
    last_deleted bigint NOT NULL,
    last_duration interval NOT NULL
);

CREATE TABLE IF NOT EXISTS public.apotelesma_commits_cache_runs (
    run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    finished_at timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    mode text NOT NULL CHECK (mode IN ('incremental', 'reconcile', 'migration')),
    source_rows bigint NOT NULL,
    inserted bigint NOT NULL,
    updated bigint NOT NULL,
    deleted bigint NOT NULL,
    duration interval NOT NULL,
    source_watermark timestamp with time zone
);

\ir commits-cache-source.sql

CREATE OR REPLACE FUNCTION public.sync_commits_cache(
    p_full_reconcile boolean DEFAULT false,
    p_overlap interval DEFAULT interval '14 days',
    p_reconcile_interval interval DEFAULT interval '7 days'
)
RETURNS TABLE (
    status text,
    mode text,
    source_rows bigint,
    inserted bigint,
    updated bigint,
    deleted bigint,
    duration interval,
    source_watermark timestamp with time zone
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_started_at timestamp with time zone := clock_timestamp();
    v_finished_at timestamp with time zone;
    v_watermark timestamp with time zone;
    v_last_reconciled_at timestamp with time zone;
    v_cutoff timestamp with time zone;
    v_source_watermark timestamp with time zone;
    v_full_reconcile boolean;
    v_mode text;
    v_source_query text;
    v_source_rows bigint := 0;
    v_inserted bigint := 0;
    v_updated bigint := 0;
    v_deleted bigint := 0;
    v_duration interval;
BEGIN
    IF p_overlap <= interval '0' THEN
        RAISE EXCEPTION 'p_overlap must be greater than zero';
    END IF;

    IF p_reconcile_interval <= interval '0' THEN
        RAISE EXCEPTION 'p_reconcile_interval must be greater than zero';
    END IF;

    -- A transaction-scoped lock guarantees that state and cache data advance
    -- together, while try-lock keeps a scheduler from piling up blocked jobs.
    IF NOT pg_try_advisory_xact_lock(hashtextextended('apotelesma.commits-cache', 0)) THEN
        RETURN QUERY
        SELECT
            'skipped_lock'::text,
            'incremental'::text,
            0::bigint,
            0::bigint,
            0::bigint,
            0::bigint,
            clock_timestamp() - v_started_at,
            NULL::timestamp with time zone;
        RETURN;
    END IF;

    SELECT
        state.last_source_committer_date,
        state.last_reconciled_at
    INTO
        v_watermark,
        v_last_reconciled_at
    FROM public.apotelesma_commits_cache_state AS state
    WHERE state.singleton;

    v_full_reconcile := p_full_reconcile
        OR v_last_reconciled_at IS NULL
        OR v_last_reconciled_at + p_reconcile_interval <= v_started_at;
    v_mode := CASE WHEN v_full_reconcile THEN 'reconcile' ELSE 'incremental' END;
    v_cutoff := CASE
        WHEN v_watermark IS NULL THEN '-infinity'::timestamp with time zone
        ELSE v_watermark - p_overlap
    END;

    /*
     * Ekorre can only receive a direct immutable timestamp predicate.  Build
     * one with a quoted constant rather than a PL/pgSQL parameter, so this
     * filter is planned at each git_log_* foreign scan below git_log_all.
     */
    v_source_query := 'SELECT * FROM public.commits_cache_source';
    IF NOT v_full_reconcile THEN
        v_source_query := v_source_query
            || format(' WHERE commit_date >= %L::timestamp with time zone', v_cutoff);
    END IF;

    IF to_regclass('pg_temp.apotelesma_commits_sync_source') IS NOT NULL THEN
        DROP TABLE pg_temp.apotelesma_commits_sync_source;
    END IF;
    EXECUTE
        'CREATE TEMPORARY TABLE apotelesma_commits_sync_source ON COMMIT DROP AS '
        || v_source_query;
    ANALYZE pg_temp.apotelesma_commits_sync_source;

    SELECT count(*), max(source.commit_date)
    INTO v_source_rows, v_source_watermark
    FROM pg_temp.apotelesma_commits_sync_source AS source;

    IF EXISTS (
        SELECT 1
        FROM pg_temp.apotelesma_commits_sync_source AS source
        GROUP BY source.branch, source.commit_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'git_log_all is not unique on (branch, commit_id); cannot maintain public.commits safely';
    END IF;

    SELECT
        count(*) FILTER (WHERE cached.commit_id IS NULL),
        count(*) FILTER (
            WHERE cached.commit_id IS NOT NULL
              AND (
                  cached.author_name,
                  cached.author_email,
                  cached.author_date,
                  cached.committer_name,
                  cached.committer_email,
                  cached.commit_date,
                  cached.summary,
                  cached.message,
                  cached.deltas,
                  cached.insertions,
                  cached.deletions,
                  cached.changed_files,
                  cached.reported_by,
                  cached.suggested_by,
                  cached.diagnosed_by,
                  cached.trailer_author,
                  cached.co_authored_by,
                  cached.reviewed_by,
                  cached.tested_by,
                  cached.bug,
                  cached.discussion,
                  cached.backpatch_through,
                  cached.mentioned_people,
                  cached.mentioned_urls
              ) IS DISTINCT FROM (
                  source.author_name,
                  source.author_email,
                  source.author_date,
                  source.committer_name,
                  source.committer_email,
                  source.commit_date,
                  source.summary,
                  source.message,
                  source.deltas,
                  source.insertions,
                  source.deletions,
                  source.changed_files,
                  source.reported_by,
                  source.suggested_by,
                  source.diagnosed_by,
                  source.trailer_author,
                  source.co_authored_by,
                  source.reviewed_by,
                  source.tested_by,
                  source.bug,
                  source.discussion,
                  source.backpatch_through,
                  source.mentioned_people,
                  source.mentioned_urls
              )
        )
    INTO v_inserted, v_updated
    FROM pg_temp.apotelesma_commits_sync_source AS source
    LEFT JOIN public.commits AS cached
      ON cached.branch = source.branch
     AND cached.commit_id = source.commit_id;

    INSERT INTO public.commits AS cached (
        branch,
        commit_id,
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
    )
    SELECT
        source.branch,
        source.commit_id,
        source.author_name,
        source.author_email,
        source.author_date,
        source.committer_name,
        source.committer_email,
        source.commit_date,
        source.summary,
        source.message,
        source.deltas,
        source.insertions,
        source.deletions,
        source.changed_files,
        source.reported_by,
        source.suggested_by,
        source.diagnosed_by,
        source.trailer_author,
        source.co_authored_by,
        source.reviewed_by,
        source.tested_by,
        source.bug,
        source.discussion,
        source.backpatch_through,
        source.mentioned_people,
        source.mentioned_urls
    FROM pg_temp.apotelesma_commits_sync_source AS source
    ON CONFLICT (branch, commit_id) DO UPDATE
    SET
        author_name = EXCLUDED.author_name,
        author_email = EXCLUDED.author_email,
        author_date = EXCLUDED.author_date,
        committer_name = EXCLUDED.committer_name,
        committer_email = EXCLUDED.committer_email,
        commit_date = EXCLUDED.commit_date,
        summary = EXCLUDED.summary,
        message = EXCLUDED.message,
        deltas = EXCLUDED.deltas,
        insertions = EXCLUDED.insertions,
        deletions = EXCLUDED.deletions,
        changed_files = EXCLUDED.changed_files,
        reported_by = EXCLUDED.reported_by,
        suggested_by = EXCLUDED.suggested_by,
        diagnosed_by = EXCLUDED.diagnosed_by,
        trailer_author = EXCLUDED.trailer_author,
        co_authored_by = EXCLUDED.co_authored_by,
        reviewed_by = EXCLUDED.reviewed_by,
        tested_by = EXCLUDED.tested_by,
        bug = EXCLUDED.bug,
        discussion = EXCLUDED.discussion,
        backpatch_through = EXCLUDED.backpatch_through,
        mentioned_people = EXCLUDED.mentioned_people,
        mentioned_urls = EXCLUDED.mentioned_urls
    WHERE (
        cached.author_name,
        cached.author_email,
        cached.author_date,
        cached.committer_name,
        cached.committer_email,
        cached.commit_date,
        cached.summary,
        cached.message,
        cached.deltas,
        cached.insertions,
        cached.deletions,
        cached.changed_files,
        cached.reported_by,
        cached.suggested_by,
        cached.diagnosed_by,
        cached.trailer_author,
        cached.co_authored_by,
        cached.reviewed_by,
        cached.tested_by,
        cached.bug,
        cached.discussion,
        cached.backpatch_through,
        cached.mentioned_people,
        cached.mentioned_urls
    ) IS DISTINCT FROM (
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

    DELETE FROM public.commits AS cached
    WHERE (v_full_reconcile OR cached.commit_date >= v_cutoff)
      AND NOT EXISTS (
          SELECT 1
          FROM pg_temp.apotelesma_commits_sync_source AS source
          WHERE source.branch = cached.branch
            AND source.commit_id = cached.commit_id
      );
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    v_finished_at := clock_timestamp();
    v_duration := v_finished_at - v_started_at;
    v_watermark := GREATEST(v_watermark, v_source_watermark);

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
    VALUES (
        true,
        v_finished_at,
        v_watermark,
        CASE WHEN v_full_reconcile THEN v_finished_at ELSE NULL END,
        v_mode,
        v_source_rows,
        v_inserted,
        v_updated,
        v_deleted,
        v_duration
    )
    ON CONFLICT (singleton) DO UPDATE
    SET
        last_successful_at = EXCLUDED.last_successful_at,
        last_source_committer_date = EXCLUDED.last_source_committer_date,
        last_reconciled_at = CASE
            WHEN v_full_reconcile THEN EXCLUDED.last_successful_at
            ELSE state.last_reconciled_at
        END,
        last_run_mode = EXCLUDED.last_run_mode,
        last_source_rows = EXCLUDED.last_source_rows,
        last_inserted = EXCLUDED.last_inserted,
        last_updated = EXCLUDED.last_updated,
        last_deleted = EXCLUDED.last_deleted,
        last_duration = EXCLUDED.last_duration;

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
    VALUES (
        v_finished_at,
        v_mode,
        v_source_rows,
        v_inserted,
        v_updated,
        v_deleted,
        v_duration,
        v_watermark
    );

    RAISE LOG
        'apotelesma commits cache sync completed: mode=%, source_rows=%, inserted=%, updated=%, deleted=%, duration=%',
        v_mode,
        v_source_rows,
        v_inserted,
        v_updated,
        v_deleted,
        v_duration;

    RETURN QUERY
    SELECT
        'ok'::text,
        v_mode,
        v_source_rows,
        v_inserted,
        v_updated,
        v_deleted,
        v_duration,
        v_watermark;
END;
$$;

CREATE OR REPLACE FUNCTION public.commits_cache_health(
    p_max_age interval DEFAULT interval '2 hours'
)
RETURNS TABLE (
    healthy boolean,
    last_successful_at timestamp with time zone,
    last_source_committer_date timestamp with time zone,
    last_reconciled_at timestamp with time zone,
    age interval,
    last_run_mode text,
    last_source_rows bigint,
    last_inserted bigint,
    last_updated bigint,
    last_deleted bigint,
    last_duration interval
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        state.last_successful_at >= clock_timestamp() - p_max_age,
        state.last_successful_at,
        state.last_source_committer_date,
        state.last_reconciled_at,
        clock_timestamp() - state.last_successful_at,
        state.last_run_mode,
        state.last_source_rows,
        state.last_inserted,
        state.last_updated,
        state.last_deleted,
        state.last_duration
    FROM public.apotelesma_commits_cache_state AS state
    WHERE state.singleton;
$$;
