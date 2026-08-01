-- The Git source's commit_date is the committer timestamp emitted by ekorre.
-- Keep this projection byte-for-byte compatible with the former commits
-- materialized view; public.commits is the cached copy of this view.
CREATE OR REPLACE VIEW public.commits_cache_source AS
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
FROM public.git_log_all AS g
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
