-- Grafana compatibility relations.  Keep their names and result columns
-- stable while changing only public.commits from an MV to a table.
CREATE OR REPLACE VIEW public.author_activity AS
SELECT
    branch,
    author_name,
    author_email,
    count(*) AS commit_count,
    sum(insertions) AS total_insertions,
    sum(deletions) AS total_deletions,
    sum(changed_files) AS total_changed_files,
    max(author_date) AS last_commit_at
FROM public.commits
GROUP BY branch, author_name, author_email
ORDER BY branch, max(author_date) DESC, count(*) DESC;

CREATE OR REPLACE VIEW public.commit_trailers AS
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
FROM public.commits AS c
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

CREATE OR REPLACE VIEW public.daily_activity AS
SELECT
    branch,
    author_date::date AS commit_day,
    count(*) AS commit_count,
    sum(insertions) AS total_insertions,
    sum(deletions) AS total_deletions,
    sum(changed_files) AS total_changed_files
FROM public.commits
GROUP BY branch, author_date::date
ORDER BY branch, author_date::date DESC;

CREATE OR REPLACE VIEW public.trailer_summary AS
SELECT
    branch,
    trailer_field,
    trailer_category,
    trailer_value,
    count(*) AS entry_count,
    count(DISTINCT commit_id) AS commit_count,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM public.commit_trailers
GROUP BY branch, trailer_field, trailer_category, trailer_value
ORDER BY branch, trailer_field, max(author_date) DESC, trailer_value;

CREATE OR REPLACE VIEW public.trailer_people_summary AS
SELECT
    branch,
    mentioned.person,
    count(*) AS mention_count,
    count(DISTINCT commit_id) AS commit_count,
    array_agg(DISTINCT trailer_field ORDER BY trailer_field) AS trailer_fields,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at
FROM public.commit_trailers
CROSS JOIN LATERAL unnest(people) AS mentioned(person)
GROUP BY branch, mentioned.person
ORDER BY branch, max(author_date) DESC, mentioned.person;
