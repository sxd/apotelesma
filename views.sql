DROP VIEW IF EXISTS ticket_summary;
DROP VIEW IF EXISTS reviewer_summary;
DROP VIEW IF EXISTS trailer_people_summary;
DROP VIEW IF EXISTS trailer_summary;
DROP VIEW IF EXISTS daily_activity;
DROP VIEW IF EXISTS commit_trailers;
DROP VIEW IF EXISTS author_activity;
DROP VIEW IF EXISTS trailer_field_catalog;
DROP VIEW IF EXISTS commits_cache_source;
DROP MATERIALIZED VIEW IF EXISTS authors;
DROP FUNCTION IF EXISTS commits_cache_health(interval);
DROP FUNCTION IF EXISTS sync_commits_cache(boolean, interval, interval);
DROP TABLE IF EXISTS apotelesma_commits_cache_runs;
DROP TABLE IF EXISTS apotelesma_commits_cache_state;
DO $$
DECLARE
    relation_kind "char";
BEGIN
    SELECT c.relkind
    INTO relation_kind
    FROM pg_class AS c
    WHERE c.oid = to_regclass('public.commits');

    IF relation_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW public.commits';
    ELSIF relation_kind = 'r' THEN
        EXECUTE 'DROP TABLE public.commits';
    ELSIF relation_kind IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot reset public.commits with relkind %', relation_kind;
    END IF;
END;
$$;
DROP FUNCTION IF EXISTS ensure_git_log_views(text, text, text);
DROP FUNCTION IF EXISTS apotelesma_branch_suffix(text);
DROP FUNCTION IF EXISTS extract_urls(text[]);
DROP FUNCTION IF EXISTS unique_text_array(text[]);
DROP FUNCTION IF EXISTS extract_field(text, text);
DROP TYPE IF EXISTS commit_trailer_field CASCADE;

CREATE TYPE commit_trailer_field AS ENUM (
    'Reported-by',
    'Suggested-by',
    'Diagnosed-by',
    'Author',
    'Co-authored-by',
    'Reviewed-by',
    'Tested-by',
    'Bug',
    'Discussion',
    'Backpatch-through'
);

CREATE OR REPLACE FUNCTION apotelesma_branch_suffix(input_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE(
        NULLIF(
            substring(
                regexp_replace(lower(COALESCE(input_value, '')), '[^a-z0-9]', '_', 'g')
                FROM 1 FOR 40
            ),
            ''
        ),
        'head'
    );
$$;

CREATE OR REPLACE FUNCTION ensure_git_log_views(
    schema_name text DEFAULT current_schema(),
    root_branch text DEFAULT NULLIF(current_setting('apotelesma.root_branch', true), ''),
    branches_csv text DEFAULT NULLIF(current_setting('apotelesma.branches', true), '')
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_root_branch text := COALESCE(root_branch, 'master');
    root_table_name text := format('git_log_%s', apotelesma_branch_suffix(COALESCE(root_branch, 'master')));
    branch_table_names text[];
    branch_table_name text;
    branch_name text;
    branch_list text[] := ARRAY[]::text[];
    select_sql_parts text[] := ARRAY[]::text[];
BEGIN
    SELECT COALESCE(array_agg(c.relname ORDER BY c.relname), ARRAY[]::text[])
    INTO branch_table_names
    FROM pg_class AS c
    JOIN pg_namespace AS n
      ON n.oid = c.relnamespace
    WHERE n.nspname = schema_name
      AND c.relname LIKE 'git_log_%'
      AND c.relname NOT IN ('git_log', 'git_log_all')
      AND c.relkind IN ('f', 'm', 'p', 'r', 'v');

    IF cardinality(branch_table_names) = 0 THEN
        RAISE EXCEPTION
            'No git_log_* relations found in schema "%". Import branch tables first before running views.sql.',
            schema_name;
    END IF;

    IF NOT (root_table_name = ANY(branch_table_names)) THEN
        RAISE EXCEPTION
            'Root relation %.% is missing. Set apotelesma.root_branch before running views.sql if your root branch is not "%".',
            schema_name,
            root_table_name,
            normalized_root_branch;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE VIEW %I.git_log AS SELECT * FROM %I.%I',
        schema_name,
        schema_name,
        root_table_name
    );

    branch_list := ARRAY[normalized_root_branch];

    IF branches_csv IS NOT NULL THEN
        branch_list := branch_list || ARRAY(
            SELECT branch_item
            FROM (
                SELECT DISTINCT ON (branch_item)
                    branch_item,
                    ordinality
                FROM unnest(regexp_split_to_array(branches_csv, '\s*,\s*')) WITH ORDINALITY AS items(raw_branch, ordinality)
                CROSS JOIN LATERAL (
                    SELECT btrim(raw_branch) AS branch_item
                ) AS normalized
                WHERE branch_item <> ''
                  AND branch_item <> normalized_root_branch
                ORDER BY branch_item, ordinality
            ) AS deduplicated
            ORDER BY ordinality
        );
    ELSE
        branch_list := branch_list || ARRAY(
            SELECT regexp_replace(relname, '^git_log_', '')
            FROM unnest(branch_table_names) AS relname
            WHERE relname <> root_table_name
            ORDER BY relname
        );
    END IF;

    FOREACH branch_name IN ARRAY branch_list LOOP
        branch_table_name := format('git_log_%s', apotelesma_branch_suffix(branch_name));

        IF NOT (branch_table_name = ANY(branch_table_names)) THEN
            IF branches_csv IS NOT NULL THEN
                RAISE EXCEPTION
                    'Expected relation %.% for branch "%" but it does not exist.',
                    schema_name,
                    branch_table_name,
                    branch_name;
            END IF;

            CONTINUE;
        END IF;

        IF branch_name = normalized_root_branch THEN
            select_sql_parts := select_sql_parts || format(
                'SELECT %L AS branch, t.* FROM %I.%I AS t',
                branch_name,
                schema_name,
                branch_table_name
            );
        ELSE
            select_sql_parts := select_sql_parts || format(
                'SELECT %L AS branch, t.* FROM %I.%I AS t WHERE NOT EXISTS (SELECT 1 FROM %I.%I AS root_table WHERE root_table.commit_id = t.commit_id)',
                branch_name,
                schema_name,
                branch_table_name,
                schema_name,
                root_table_name
            );
        END IF;
    END LOOP;

    EXECUTE format(
        'CREATE OR REPLACE VIEW %I.git_log_all AS %s',
        schema_name,
        array_to_string(select_sql_parts, E'\nUNION ALL\n')
    );
END;
$$;

SELECT ensure_git_log_views();

CREATE OR REPLACE FUNCTION unique_text_array(input_values text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE(array_agg(value ORDER BY first_position), ARRAY[]::text[])
    FROM (
        SELECT
            btrim(value) AS value,
            min(ordinality) AS first_position
        FROM unnest(COALESCE(input_values, ARRAY[]::text[])) WITH ORDINALITY AS item(value, ordinality)
        WHERE btrim(value) <> ''
        GROUP BY btrim(value)
    ) deduplicated;
$$;

CREATE OR REPLACE FUNCTION is_person_trailer(field commit_trailer_field)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT field = ANY (
        ARRAY[
            'Reported-by'::commit_trailer_field,
            'Suggested-by'::commit_trailer_field,
            'Diagnosed-by'::commit_trailer_field,
            'Author'::commit_trailer_field,
            'Co-authored-by'::commit_trailer_field,
            'Reviewed-by'::commit_trailer_field,
            'Tested-by'::commit_trailer_field
        ]
    );
$$;

CREATE OR REPLACE FUNCTION extract_field(
    message text,
    field commit_trailer_field
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE(array_agg(value ORDER BY line_number), ARRAY[]::text[])
    FROM (
        SELECT
            ordinality AS line_number,
            NULLIF(btrim(substring(line FROM position(':' IN line) + 1)), '') AS value
        FROM regexp_split_to_table(COALESCE(message, ''), E'\r?\n') WITH ORDINALITY AS lines(line, ordinality)
        WHERE line ~ '^[A-Za-z0-9-]+:'
          AND split_part(btrim(line), ':', 1) ILIKE field::text
    ) matched
    WHERE value IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION extract_field(
    message text,
    field text
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT extract_field(message, field::commit_trailer_field);
$$;

CREATE OR REPLACE FUNCTION extract_urls(input_values text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE(array_agg(url ORDER BY first_position), ARRAY[]::text[])
    FROM (
        SELECT
            url,
            min(position) AS first_position
        FROM (
            SELECT
                matched.match[1] AS url,
                trailer_value.position
            FROM unnest(COALESCE(input_values, ARRAY[]::text[])) WITH ORDINALITY AS trailer_value(value, position)
            CROSS JOIN LATERAL regexp_matches(
                trailer_value.value,
                '(https?://[^[:space:]<>()"]+)',
                'g'
            ) AS matched(match)
        ) extracted
        GROUP BY url
    ) deduplicated;
$$;

CREATE VIEW trailer_field_catalog AS
SELECT
    ordinality,
    trailer_field::text AS trailer_field,
    column_name,
    category
FROM (
    VALUES
        (1, 'Reported-by'::commit_trailer_field, 'reported_by', 'person'),
        (2, 'Suggested-by'::commit_trailer_field, 'suggested_by', 'person'),
        (3, 'Diagnosed-by'::commit_trailer_field, 'diagnosed_by', 'person'),
        (4, 'Author'::commit_trailer_field, 'trailer_author', 'person'),
        (5, 'Co-authored-by'::commit_trailer_field, 'co_authored_by', 'person'),
        (6, 'Reviewed-by'::commit_trailer_field, 'reviewed_by', 'person'),
        (7, 'Tested-by'::commit_trailer_field, 'tested_by', 'person'),
        (8, 'Bug'::commit_trailer_field, 'bug', 'reference'),
        (9, 'Discussion'::commit_trailer_field, 'discussion', 'reference'),
        (10, 'Backpatch-through'::commit_trailer_field, 'backpatch_through', 'reference')
) AS catalog(ordinality, trailer_field, column_name, category);

\ir sql/commits-cache.sql

SELECT *
FROM sync_commits_cache(
    p_full_reconcile => true,
    p_overlap => interval '14 days',
    p_reconcile_interval => interval '7 days'
);

CREATE MATERIALIZED VIEW authors AS
SELECT
    branch,
    author_name,
    author_email,
    count(*) AS commit_count,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM commits
GROUP BY branch, author_name, author_email;

\ir sql/commits-cache-dependent-views.sql
