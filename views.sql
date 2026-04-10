DROP VIEW IF EXISTS ticket_summary;
DROP VIEW IF EXISTS reviewer_summary;
DROP VIEW IF EXISTS trailer_people_summary;
DROP VIEW IF EXISTS trailer_summary;
DROP VIEW IF EXISTS daily_activity;
DROP VIEW IF EXISTS commit_trailers;
DROP VIEW IF EXISTS author_activity;
DROP VIEW IF EXISTS trailer_field_catalog;
DROP MATERIALIZED VIEW IF EXISTS commits;
DROP MATERIALIZED VIEW IF EXISTS authors;
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

CREATE MATERIALIZED VIEW authors AS
SELECT
    branch,
    author_name,
    author_email,
    count(*) AS commit_count,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM git_log_all
GROUP BY branch, author_name, author_email;

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

CREATE MATERIALIZED VIEW commits AS
SELECT
    g.branch,
    g.commit_id,
    g.author_name,
    g.author_email,
    g.author_date,
    g.committer_name,
    g.committer_email,
    g.commit_date,
    g.summary,
    g.message,
    COALESCE(g.deltas, 0) AS deltas,
    COALESCE(g.insertions, 0) AS insertions,
    COALESCE(g.deletions, 0) AS deletions,
    COALESCE(g.changed_files, 0) AS changed_files,
    trailers.reported_by,
    trailers.suggested_by,
    trailers.diagnosed_by,
    trailers.trailer_author,
    trailers.co_authored_by,
    trailers.reviewed_by,
    trailers.tested_by,
    trailers.bug,
    trailers.discussion,
    trailers.backpatch_through,
    unique_text_array(
        trailers.reported_by
        || trailers.suggested_by
        || trailers.diagnosed_by
        || trailers.trailer_author
        || trailers.co_authored_by
        || trailers.reviewed_by
        || trailers.tested_by
    ) AS mentioned_people,
    extract_urls(
        trailers.reported_by
        || trailers.suggested_by
        || trailers.diagnosed_by
        || trailers.trailer_author
        || trailers.co_authored_by
        || trailers.reviewed_by
        || trailers.tested_by
        || trailers.bug
        || trailers.discussion
        || trailers.backpatch_through
    ) AS mentioned_urls
FROM git_log_all AS g
CROSS JOIN LATERAL (
    SELECT
        extract_field(g.message, 'Reported-by'::commit_trailer_field) AS reported_by,
        extract_field(g.message, 'Suggested-by'::commit_trailer_field) AS suggested_by,
        extract_field(g.message, 'Diagnosed-by'::commit_trailer_field) AS diagnosed_by,
        extract_field(g.message, 'Author'::commit_trailer_field) AS trailer_author,
        extract_field(g.message, 'Co-authored-by'::commit_trailer_field) AS co_authored_by,
        extract_field(g.message, 'Reviewed-by'::commit_trailer_field) AS reviewed_by,
        extract_field(g.message, 'Tested-by'::commit_trailer_field) AS tested_by,
        extract_field(g.message, 'Bug'::commit_trailer_field) AS bug,
        extract_field(g.message, 'Discussion'::commit_trailer_field) AS discussion,
        extract_field(g.message, 'Backpatch-through'::commit_trailer_field) AS backpatch_through
) AS trailers;

CREATE VIEW author_activity AS
SELECT
    branch,
    author_name,
    author_email,
    count(*) AS commit_count,
    sum(insertions) AS total_insertions,
    sum(deletions) AS total_deletions,
    sum(changed_files) AS total_changed_files,
    max(author_date) AS last_commit_at
FROM commits
GROUP BY branch, author_name, author_email
ORDER BY branch, max(author_date) DESC, count(*) DESC;

CREATE VIEW commit_trailers AS
SELECT
    c.branch,
    c.commit_id,
    c.summary,
    trailer_set.trailer_field::text AS trailer_field,
    CASE
        WHEN is_person_trailer(trailer_set.trailer_field) THEN 'person'
        ELSE 'reference'
    END AS trailer_category,
    trailer_value.value AS trailer_value,
    CASE
        WHEN is_person_trailer(trailer_set.trailer_field) THEN ARRAY[trailer_value.value]
        ELSE ARRAY[]::text[]
    END AS people,
    extract_urls(ARRAY[trailer_value.value]) AS urls,
    c.author_name,
    c.author_date
FROM commits AS c
CROSS JOIN LATERAL (
    VALUES
        ('Reported-by'::commit_trailer_field, c.reported_by),
        ('Suggested-by'::commit_trailer_field, c.suggested_by),
        ('Diagnosed-by'::commit_trailer_field, c.diagnosed_by),
        ('Author'::commit_trailer_field, c.trailer_author),
        ('Co-authored-by'::commit_trailer_field, c.co_authored_by),
        ('Reviewed-by'::commit_trailer_field, c.reviewed_by),
        ('Tested-by'::commit_trailer_field, c.tested_by),
        ('Bug'::commit_trailer_field, c.bug),
        ('Discussion'::commit_trailer_field, c.discussion),
        ('Backpatch-through'::commit_trailer_field, c.backpatch_through)
) AS trailer_set(trailer_field, trailer_values)
CROSS JOIN LATERAL unnest(trailer_set.trailer_values) AS trailer_value(value)
ORDER BY c.branch, c.author_date DESC;

CREATE VIEW daily_activity AS
SELECT
    branch,
    author_date::date AS commit_day,
    count(*) AS commit_count,
    sum(insertions) AS total_insertions,
    sum(deletions) AS total_deletions,
    sum(changed_files) AS total_changed_files
FROM commits
GROUP BY branch, author_date::date
ORDER BY branch, author_date::date DESC;

CREATE VIEW trailer_summary AS
SELECT
    branch,
    trailer_field,
    trailer_category,
    trailer_value,
    count(*) AS entry_count,
    count(DISTINCT commit_id) AS commit_count,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM commit_trailers
GROUP BY branch, trailer_field, trailer_category, trailer_value
ORDER BY branch, trailer_field, max(author_date) DESC, trailer_value;

CREATE VIEW trailer_people_summary AS
SELECT
    branch,
    mentioned.person,
    count(*) AS mention_count,
    count(DISTINCT commit_id) AS commit_count,
    array_agg(DISTINCT trailer_field ORDER BY trailer_field) AS trailer_fields,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM commit_trailers
CROSS JOIN LATERAL unnest(people) AS mentioned(person)
GROUP BY branch, mentioned.person
ORDER BY branch, max(author_date) DESC, mentioned.person;
