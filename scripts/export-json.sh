#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA_DIR=${DATA_DIR:-"$ROOT_DIR/site/data"}
TEMP_POSTGRES=${TEMP_POSTGRES:-"$ROOT_DIR/scripts/temp-postgres.sh"}
ROOT_BRANCH=${ROOT_BRANCH:-master}
REPOSITORY_PATH=${REPOSITORY_PATH:-}

mkdir -p "$DATA_DIR"
find "$DATA_DIR" -maxdepth 1 -type f -name '*.json' -delete

export_json()
{
	local output_name=$1
	local order_clause=$2
	local query=$3
	local output_path=$DATA_DIR/$output_name

	"$TEMP_POSTGRES" psql -At > "$output_path" <<SQL
WITH dataset AS (
$query
)
SELECT COALESCE(
    jsonb_pretty(jsonb_agg(to_jsonb(dataset) ORDER BY $order_clause)),
    '[]'
)
FROM dataset;
SQL
}

export_json "trailer_fields.json" "ordinality" "
SELECT
    ordinality,
    trailer_field,
    column_name,
    category
FROM trailer_field_catalog
"

export_json "commits.json" "branch, author_date DESC, commit_id" "
SELECT
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
FROM commits
"

export_json "authors.json" "branch, commit_count DESC, last_commit_at DESC, author_email" "
SELECT
    branch,
    author_name,
    author_email,
    commit_count,
    total_insertions,
    total_deletions,
    total_changed_files,
    last_commit_at
FROM author_activity
"

export_json "daily_activity.json" "branch, commit_day" "
SELECT
    branch,
    commit_day,
    commit_count,
    total_insertions,
    total_deletions,
    total_changed_files
FROM daily_activity
"

export_json "trailer_summary.json" "branch, trailer_field, last_commit_at DESC, trailer_value" "
SELECT
    branch,
    trailer_field,
    trailer_category,
    trailer_value,
    entry_count,
    commit_count,
    first_commit_at,
    last_commit_at
FROM trailer_summary
"

export_json "commit_trailers.json" "branch, author_date DESC, commit_id, trailer_field, trailer_value" "
SELECT
    branch,
    commit_id,
    summary,
    trailer_field,
    trailer_category,
    trailer_value,
    people,
    urls,
    author_name,
    author_date
FROM commit_trailers
"

export_json "trailer_people_summary.json" "branch, last_commit_at DESC, person" "
SELECT
    branch,
    person,
    mention_count,
    commit_count,
    trailer_fields,
    first_commit_at,
    last_commit_at
FROM trailer_people_summary
"

export_json "branch_summary.json" "CASE WHEN branch = $(printf "'%s'" "${ROOT_BRANCH//\'/\'\'}") THEN 0 ELSE 1 END, branch" "
SELECT
    branch,
    count(*) AS commit_count,
    count(DISTINCT author_email) AS author_count,
    min(author_date) AS first_commit_at,
    max(author_date) AS last_commit_at,
    sum(insertions) AS total_insertions,
    sum(deletions) AS total_deletions,
    sum(changed_files) AS total_changed_files
FROM commits
GROUP BY branch
"

"$TEMP_POSTGRES" psql -At > "$DATA_DIR/grafana.json" <<SQL
WITH metadata AS (
    SELECT jsonb_build_object(
        'generated_at', to_char(current_timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'root_branch', $(printf "'%s'" "${ROOT_BRANCH//\'/\'\'}"),
        'repository_path', $(printf "'%s'" "${REPOSITORY_PATH//\'/\'\'}"),
        'branches',
            COALESCE(
                (
                    SELECT jsonb_agg(branch ORDER BY CASE WHEN branch = $(printf "'%s'" "${ROOT_BRANCH//\'/\'\'}") THEN 0 ELSE 1 END, branch)
                    FROM (
                        SELECT DISTINCT branch
                        FROM commits
                    ) branch_list
                ),
                '[]'::jsonb
            )
    ) AS value
),
trailer_fields_data AS (
    SELECT
        ordinality,
        trailer_field,
        column_name,
        category
    FROM trailer_field_catalog
),
branch_summary_data AS (
    SELECT
        branch,
        count(*) AS commit_count,
        count(DISTINCT author_email) AS author_count,
        min(author_date) AS first_commit_at,
        max(author_date) AS last_commit_at,
        sum(insertions) AS total_insertions,
        sum(deletions) AS total_deletions,
        sum(changed_files) AS total_changed_files
    FROM commits
    GROUP BY branch
),
author_summary_data AS (
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
),
daily_activity_data AS (
    SELECT
        branch,
        author_date::date AS commit_day,
        to_char(author_date::date::timestamp, 'YYYY-MM-DD"T"00:00:00"Z"') AS time,
        (extract(epoch FROM author_date::date::timestamp) * 1000)::bigint AS time_unix_ms,
        count(*) AS commit_count,
        sum(insertions) AS total_insertions,
        sum(deletions) AS total_deletions,
        sum(changed_files) AS total_changed_files
    FROM commits
    GROUP BY branch, author_date::date
),
trailer_summary_data AS (
    SELECT
        branch,
        trailer_field,
        trailer_category,
        trailer_value,
        entry_count,
        commit_count,
        first_commit_at,
        last_commit_at
    FROM trailer_summary
),
trailer_people_summary_data AS (
    SELECT
        branch,
        person,
        mention_count,
        commit_count,
        trailer_fields,
        first_commit_at,
        last_commit_at
    FROM trailer_people_summary
),
recent_commits_data AS (
    SELECT
        branch,
        commit_id,
        author_name,
        author_email,
        author_date AS time,
        (extract(epoch FROM author_date) * 1000)::bigint AS time_unix_ms,
        summary,
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
        mentioned_urls,
        insertions,
        deletions,
        changed_files
    FROM commits
    ORDER BY author_date DESC, commit_id
    LIMIT 250
),
commits_data AS (
    SELECT
        branch,
        commit_id,
        author_name,
        author_email,
        author_date AS time,
        (extract(epoch FROM author_date) * 1000)::bigint AS time_unix_ms,
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
    FROM commits
)
SELECT jsonb_pretty(
    jsonb_build_object(
        'metadata', (SELECT value FROM metadata),
        'trailer_fields',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.ordinality)
                    FROM trailer_fields_data t
                ),
                '[]'::jsonb
            ),
        'branch_summary',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY CASE WHEN t.branch = $(printf "'%s'" "${ROOT_BRANCH//\'/\'\'}") THEN 0 ELSE 1 END, t.branch)
                    FROM branch_summary_data t
                ),
                '[]'::jsonb
            ),
        'author_summary',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.branch, t.commit_count DESC, t.last_commit_at DESC, t.author_email)
                    FROM author_summary_data t
                ),
                '[]'::jsonb
            ),
        'daily_activity',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.branch, t.commit_day)
                    FROM daily_activity_data t
                ),
                '[]'::jsonb
            ),
        'trailer_summary',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.branch, t.trailer_field, t.last_commit_at DESC, t.trailer_value)
                    FROM trailer_summary_data t
                ),
                '[]'::jsonb
            ),
        'trailer_people_summary',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.branch, t.last_commit_at DESC, t.person)
                    FROM trailer_people_summary_data t
                ),
                '[]'::jsonb
            ),
        'recent_commits',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.time DESC, t.commit_id)
                    FROM recent_commits_data t
                ),
                '[]'::jsonb
            ),
        'commits',
            COALESCE(
                (
                    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.branch, t.time DESC, t.commit_id)
                    FROM commits_data t
                ),
                '[]'::jsonb
            )
    )
);
SQL
