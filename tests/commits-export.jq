# Exact values and order in all three commit representations, including keys
# with empty arrays. Raw messages are checked separately, never scrubbed.
def expected:
  {reported_by: ["Reporter"], suggested_by: ["Suggester"], diagnosed_by: ["Diagnoser"],
   trailer_author: ["Patch Author <patch@example.test>"],
   co_authored_by: ["Co One <co1@example.test>", "Shared Person <shared@example.test>"],
   reviewed_by: ["Reviewer Two", "Reviewer One", "Reviewer Two"], tested_by: ["Tester"],
   bug: ["https://example.test/bug"], discussion: ["https://example.test/discussion"],
   backpatch_through: ["18"],
   mentioned_people: ["Reporter", "Suggester", "Diagnoser", "Patch Author <patch@example.test>",
     "Co One <co1@example.test>", "Shared Person <shared@example.test>", "Reviewer Two", "Reviewer One", "Tester"],
   mentioned_urls: ["https://example.test/bug", "https://example.test/discussion"]};
def one($id): map(select(.commit_id == $id)) | if length == 1 then .[0] else error("fixture missing/duplicated: " + $id) end;
def has_fields($expected): . as $row | all($expected | to_entries[]; $row[.key] == .value);
def no_decoys: all(.. | strings; (contains("Body Decoy") or contains("body-decoy")) | not);
def trailer_sets:
  {"Reported-by": expected.reported_by, "Suggested-by": expected.suggested_by,
   "Diagnosed-by": expected.diagnosed_by, "Author": expected.trailer_author,
   "Co-authored-by": expected.co_authored_by, "Reviewed-by": expected.reviewed_by,
   "Tested-by": expected.tested_by, "Bug": expected.bug,
   "Discussion": expected.discussion, "Backpatch-through": expected.backpatch_through};
def summary_matches:
  . as $rows | all(trailer_sets | to_entries[];
    .key as $field | all(.value | group_by(.)[];
      . as $values |
      [$rows[] | select(.branch == "master" and .trailer_field == $field and .trailer_value == $values[0])] |
      length == 1 and .[0].entry_count == ($values | length) and .[0].commit_count == 1));

([$commits[0], $grafana[0].commits, $grafana[0].recent_commits] |
  all(.[];
    (one("patch-provenance") | has_fields(expected)) and
    (one("release-one-only") | has_fields(expected | map_values([]))) and
    (map(del(.message)) | no_decoys))) and
([$commits[0], $grafana[0].commits] |
  all(.[]; (one("patch-provenance") | .message == $fixture.message))) and
([$trailers[0], $summary[0], $people[0], $grafana[0].trailer_summary, $grafana[0].trailer_people_summary] |
  all(.[]; no_decoys)) and
($trailers[0] | map(select(.commit_id == "patch-provenance")) |
  . as $rows |
  (length == 13) and
  all(trailer_sets | to_entries[];
    . as $set |
    ($rows | map(select(.trailer_field == $set.key) | .trailer_value) | sort) == ($set.value | sort))) and
([$summary[0], $grafana[0].trailer_summary] | all(.[]; summary_matches)) and
($trailers[0] | map(select(.commit_id == "release-one-only")) | length == 0)
