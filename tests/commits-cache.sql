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

CREATE TABLE public.git_log_rel_19_stable (LIKE public.git_log_master);
CREATE TABLE public.git_log_rel_18_stable (LIKE public.git_log_master);

-- Keep this raw text intact through cache population, migration and export.
CREATE TEMP TABLE provenance_fixture AS
SELECT E'Patch provenance\n\nAuthor: Body Decoy <body@example.test>\nCo-authored-by: Body Decoy <body@example.test>\nReviewed-by: Body Decoy <body@example.test>\nBug: https://example.test/body-decoy\nMore body prose.\n\nAuthor: Patch Author <patch@example.test>\nCo-authored-by: Co One <co1@example.test>\nCo-authored-by: Shared Person <shared@example.test>\nReported-by: Reporter\nSuggested-by: Suggester\nDiagnosed-by: Diagnoser\nReviewed-by: Reviewer Two\nReviewed-by: Reviewer One\nReviewed-by: Reviewer Two\nTested-by: Tester\nBug: https://example.test/bug\nDiscussion: https://example.test/discussion\nBackpatch-through: 18\n' AS message;

INSERT INTO public.git_log_master
SELECT 'patch-provenance', 'Git Author', 'git@example.test', clock_timestamp(),
       'Git Committer', 'committer@example.test', clock_timestamp(),
       'Patch provenance', message, 1, 2, 1, 1
FROM provenance_fixture;

INSERT INTO public.git_log_master
VALUES
    ('shared-root', 'Root Author', 'root@example.test', clock_timestamp() - interval '1 day', 'Root Committer', 'root-committer@example.test', clock_timestamp() - interval '1 day', 'root commit', 'Reviewed-by: Root Reviewer <root-review@example.test>', 1, 2, 1, 1),
    ('master-only', 'Main Author', 'main@example.test', clock_timestamp() - interval '2 days', 'Main Committer', 'main-committer@example.test', clock_timestamp() - interval '2 days', 'master only', 'Bug: https://example.test/master-only', 1, 3, 1, 2),
    ('old-delete', 'Old Author', 'old@example.test', clock_timestamp() - interval '40 days', 'Old Committer', 'old-committer@example.test', clock_timestamp() - interval '40 days', 'will be deleted outside overlap', '', 0, 0, 0, 0);

INSERT INTO public.git_log_rel_19_stable
VALUES
    ('shared-root', 'Release Author', 'release@example.test', clock_timestamp() - interval '1 day', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '1 day', 'must be hidden by root', '', 0, 0, 0, 0),
    ('cross-branch', 'Release One', 'release-one@example.test', clock_timestamp() - interval '3 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '3 days', 'same ID as another release branch', 'Tested-by: One Tester <one@example.test>', 1, 1, 0, 1),
    ('release-one-only', 'Release One', 'release-one@example.test', clock_timestamp() - interval '4 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '4 days', 'release one only', '', 0, 0, 0, 0);

INSERT INTO public.git_log_rel_18_stable
VALUES
    ('cross-branch', 'Release Two', 'release-two@example.test', clock_timestamp() - interval '5 days', 'Release Committer', 'release-committer@example.test', clock_timestamp() - interval '5 days', 'same ID as release one', 'Reviewed-by: Two Reviewer <two@example.test>', 1, 1, 0, 1);

SET apotelesma.root_branch = 'master';
SET apotelesma.branches = 'master, REL_19_STABLE, REL_18_STABLE';
\ir ../views.sql

-- Each template is exercised for every enum field and both public overloads.
-- {other} is always a different recognized field; repeats test source order.
CREATE TEMP TABLE parser_cases (name text, message text, expected text[]);
INSERT INTO parser_cases VALUES
    ('terminal', E'Subject\nBody\n\n{field}: Two\n{other}: Other\n{field}: One\n{field}: Two', ARRAY['Two', 'One', 'Two']),
    ('trailer only', E'{field}: Two\n{other}: Other\n{field}: One\n{field}: Two', ARRAY['Two', 'One', 'Two']),
    ('earlier block', E'{field}: Decoy\n\nBody\n\n{field}: Value', ARRAY['Value']),
    ('subject decoy', E'{field}: Decoy\nBody\n\n{field}: Value', ARRAY['Value']),
    ('no boundary', E'Subject\n{field}: Value', ARRAY[]::text[]),
    ('body no boundary', E'Subject\n\nBody\n{field}: Value', ARRAY[]::text[]),
    ('following prose', E'Subject\n\n{field}: Value\nBody', ARRAY[]::text[]),
    ('nonterminal', E'{field}: Decoy\n\nBody', ARRAY[]::text[]),
    ('absent field', '{other}: Other', ARRAY[]::text[]),
    ('null', NULL, ARRAY[]::text[]),
    ('empty', '', ARRAY[]::text[]),
    ('blanks only', E' \t\n\t\n', ARRAY[]::text[]),
    ('spaces trimmed', '{field}:   Value   ', ARRAY['Value']),
    ('empty values omitted', E'{field}:\n{field}:   \n{field}: Value', ARRAY['Value']),
    ('tabs retained', E'{field}: \tValue\t \n{field}: \t ', ARRAY[E'\tValue\t', E'\t']);

-- Unknown labels are valid trailer syntax, but are not exported fields.
INSERT INTO parser_cases
SELECT 'unknown trailer ' || placement.name, placement.message, ARRAY['Value']
FROM (VALUES
    ('before', E'Subject\n\nSecurity: CVE-2026-6464\n{field}: Value'),
    ('between', E'Subject\n\n{other}: Other\nDiscusssion: https://example.test/thread\n{field}: Value'),
    ('after', E'Subject\n\n{field}: Value\nUnknown: Ignored')
) AS placement(name, message);

-- Invalid lines at any position invalidate the WHOLE terminal block, even
-- when an earlier valid block or a recognized suffix could otherwise match.
INSERT INTO parser_cases
SELECT 'invalid ' || bad.name || ' ' || placement.name,
       E'{field}: Earlier\n\n' || placement.message,
       ARRAY[]::text[]
FROM (VALUES
    ('space continuation', ' continued'),
    ('tab continuation', E'\tcontinued'),
    ('space indentation', ' {field}: Bad'),
    ('tab indentation', E'\t{field}: Bad'),
    ('space before colon', '{field} : Bad'),
    ('tab before colon', E'{field}\t: Bad'),
    ('no colon', '{field}'),
    ('prose', 'ordinary prose')
) AS bad(name, line)
CROSS JOIN LATERAL (VALUES
    ('before', bad.line || E'\n{field}: Value'),
    ('between', E'{field}: Value\n' || bad.line || E'\n{field}: Another'),
    ('after', E'{field}: Value\n' || bad.line)
) AS placement(name, message);

DO $$
DECLARE
    field commit_trailer_field;
    other_field text;
    test_case record;
    line_ending text;
    blank text;
    trailing_blanks text;
    field_spelling text;
    message text;
    enum_result text[];
    text_result text[];
    bad_argument text;
BEGIN
    FOREACH field IN ARRAY enum_range(NULL::commit_trailer_field) LOOP
        other_field := CASE WHEN field = 'Reviewed-by' THEN 'Bug' ELSE 'Reviewed-by' END;
        FOREACH field_spelling IN ARRAY ARRAY[
            field::text, lower(field::text), upper(field::text),
            overlay(upper(field::text) placing lower(substr(field::text, 2, 1)) from 2 for 1)
        ] LOOP
            FOR test_case IN SELECT * FROM parser_cases LOOP
                FOREACH line_ending IN ARRAY ARRAY[E'\n', E'\r\n'] LOOP
                    FOREACH blank IN ARRAY ARRAY['', ' ', E'\t', E' \t '] LOOP
                        FOREACH trailing_blanks IN ARRAY ARRAY['', E'\n', E'\n\n', E'\n \t\n\t'] LOOP
                            message := replace(replace(test_case.message, '{field}', field_spelling), '{other}', other_field);
                            message := replace(message, E'\n\n', E'\n' || blank || E'\n');
                            message := replace(message || trailing_blanks, E'\n', line_ending);
                            enum_result := extract_field(message, field);
                            text_result := extract_field(message, field::text);
                            IF enum_result IS DISTINCT FROM test_case.expected
                               OR text_result IS DISTINCT FROM test_case.expected THEN
                                RAISE EXCEPTION 'parser case %, field %, spelling %, message %, enum %, text %, expected %',
                                    test_case.name, field, field_spelling, message, enum_result, text_result, test_case.expected;
                            END IF;
                        END LOOP;
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
    END LOOP;

    FOREACH bad_argument IN ARRAY ARRAY['Unknown', 'author', 'AUTHOR', 'Author ', ''] LOOP
        BEGIN
            PERFORM extract_field('Author: Value', bad_argument);
            RAISE EXCEPTION 'invalid text field argument accepted: %', bad_argument;
        EXCEPTION WHEN invalid_text_representation THEN
            NULL; -- The text overload must retain its strict enum-cast contract.
        END;
    END LOOP;
END;
$$;

CREATE TEMP TABLE expected_trailers (field text, column_name text, values text[]);
-- Exercise the actual SQL parser against EVERY commit in the frozen branch
-- cohort, not just a Python model of the changed extraction rules.
\if :{?rel19_fixture}
CREATE TEMP TABLE rel19_cohort AS
SELECT value AS commit FROM jsonb_array_elements(pg_read_file(:'rel19_fixture')::jsonb);
DO $$
DECLARE
    row record;
    expected text[];
    recovered integer;
BEGIN
    IF (SELECT count(*) FROM rel19_cohort) <> 619 THEN
        RAISE EXCEPTION 'unexpected REL_19_STABLE cohort size';
    END IF;
    FOR row IN SELECT commit FROM rel19_cohort LOOP
        SELECT COALESCE(array_agg(value), ARRAY[]::text[]) INTO expected
        FROM jsonb_array_elements_text(row.commit->'trailer_author');
        IF extract_field(row.commit->>'message', 'Author') IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'REL19 parser mismatch for %', row.commit->>'commit_id';
        END IF;
    END LOOP;
    SELECT count(*) INTO recovered FROM rel19_cohort
    WHERE commit->'trailer_author' <> commit->'exported_trailer_author';
    IF recovered <> 30 THEN
        RAISE EXCEPTION 'expected 30 recovered REL19 patch credits, got %', recovered;
    END IF;
END;
$$;
\endif

INSERT INTO expected_trailers VALUES
    ('Reported-by', 'reported_by', ARRAY['Reporter']),
    ('Suggested-by', 'suggested_by', ARRAY['Suggester']),
    ('Diagnosed-by', 'diagnosed_by', ARRAY['Diagnoser']),
    ('Author', 'trailer_author', ARRAY['Patch Author <patch@example.test>']),
    ('Co-authored-by', 'co_authored_by', ARRAY['Co One <co1@example.test>', 'Shared Person <shared@example.test>']),
    ('Reviewed-by', 'reviewed_by', ARRAY['Reviewer Two', 'Reviewer One', 'Reviewer Two']),
    ('Tested-by', 'tested_by', ARRAY['Tester']),
    ('Bug', 'bug', ARRAY['https://example.test/bug']),
    ('Discussion', 'discussion', ARRAY['https://example.test/discussion']),
    ('Backpatch-through', 'backpatch_through', ARRAY['18']);

DO $$
DECLARE
    expected record;
    cached jsonb;
    actual_values text[];
    sorted_values text[];
    expected_value record;
BEGIN
    SELECT to_jsonb(c) INTO STRICT cached FROM public.commits c WHERE commit_id = 'patch-provenance';
    FOR expected IN SELECT * FROM expected_trailers LOOP
        IF cached -> expected.column_name IS DISTINCT FROM to_jsonb(expected.values) THEN
            RAISE EXCEPTION 'wrong cached array for %: %', expected.field, cached;
        END IF;
        SELECT array_agg(trailer_value ORDER BY trailer_value) INTO actual_values
        FROM public.commit_trailers
        WHERE commit_id = 'patch-provenance' AND trailer_field = expected.field;
        SELECT array_agg(v ORDER BY v) INTO sorted_values FROM unnest(expected.values) AS v;
        IF actual_values IS DISTINCT FROM sorted_values THEN
            RAISE EXCEPTION 'wrong trailer multiset/count for %: %', expected.field, actual_values;
        END IF;
        FOR expected_value IN SELECT v, count(*) AS occurrences FROM unnest(expected.values) AS v GROUP BY v LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.trailer_summary
                WHERE branch = 'master' AND trailer_field = expected.field
                  AND trailer_value = expected_value.v
                  AND entry_count = expected_value.occurrences AND commit_count = 1
            ) THEN
                RAISE EXCEPTION 'missing/wrong trailer summary for %: %', expected.field, expected_value;
            END IF;
            IF is_person_trailer(expected.field::commit_trailer_field) AND NOT EXISTS (
                SELECT 1 FROM public.trailer_people_summary
                WHERE branch = 'master' AND person = expected_value.v
                  AND mention_count = expected_value.occurrences AND commit_count = 1
                  AND trailer_fields = ARRAY[expected.field]
            ) THEN
                RAISE EXCEPTION 'missing/wrong people summary for %: %', expected.field, expected_value;
            END IF;
        END LOOP;
        IF (SELECT to_jsonb(c) -> expected.column_name FROM public.commits c WHERE commit_id = 'release-one-only')
           IS DISTINCT FROM '[]'::jsonb THEN
            RAISE EXCEPTION 'no-trailer fixture has nonempty/null %', expected.field;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM public.commit_trailers WHERE commit_id = 'patch-provenance') <> 13
       OR EXISTS (SELECT 1 FROM public.commit_trailers WHERE commit_id = 'release-one-only') THEN
        RAISE EXCEPTION 'wrong total trailer count';
    END IF;
    IF cached -> 'mentioned_people' IS DISTINCT FROM to_jsonb(ARRAY[
        'Reporter', 'Suggester', 'Diagnoser', 'Patch Author <patch@example.test>',
        'Co One <co1@example.test>', 'Shared Person <shared@example.test>',
        'Reviewer Two', 'Reviewer One', 'Tester'
    ]) OR cached -> 'mentioned_urls' IS DISTINCT FROM to_jsonb(ARRAY[
        'https://example.test/bug', 'https://example.test/discussion'
    ]) THEN
        RAISE EXCEPTION 'wrong derived people/URLs: %', cached;
    END IF;
    IF EXISTS (SELECT 1 FROM public.commit_trailers WHERE trailer_value LIKE '%Body Decoy%' OR trailer_value LIKE '%body-decoy%')
       OR EXISTS (SELECT 1 FROM public.trailer_summary WHERE trailer_value LIKE '%Body Decoy%' OR trailer_value LIKE '%body-decoy%')
       OR EXISTS (SELECT 1 FROM public.trailer_people_summary WHERE person LIKE '%Body Decoy%') THEN
        RAISE EXCEPTION 'body decoy leaked into derived rows/summaries';
    END IF;
    IF cached ->> 'message' IS DISTINCT FROM (SELECT message FROM provenance_fixture) THEN
        RAISE EXCEPTION 'raw message was changed';
    END IF;
END;
$$;

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

    IF (SELECT count(*) FROM public.commits) <> 7 THEN
        RAISE EXCEPTION 'initial backfill row count is wrong';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.commits
        WHERE branch = 'REL_19_STABLE'
          AND commit_id = 'shared-root'
    ) THEN
        RAISE EXCEPTION 'root branch de-duplication semantics were not preserved';
    END IF;

    IF (SELECT count(*) FROM public.commits WHERE commit_id = 'cross-branch') <> 2 THEN
        RAISE EXCEPTION 'duplicate commit IDs across branches were not preserved';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.commits
        WHERE branch = 'REL_19_STABLE' AND commit_id = 'release-one-only'
    ) OR NOT EXISTS (
        SELECT 1 FROM public.commits
        WHERE branch = 'REL_18_STABLE' AND commit_id = 'cross-branch'
    ) THEN
        RAISE EXCEPTION 'original uppercase release branch labels were not preserved';
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
