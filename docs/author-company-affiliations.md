# Author/company affiliation pilot

This is an offline, evidence-linked pilot for estimating which companies commit participants were associated with at a recorded commit timestamp. It consumes the existing commits JSON format and never changes the website data pipeline. The checked-in input lives in `data/author-affiliations/`; keep it out of `site/data/`, which `scripts/export-json.sh` clears before export.

The pilot is deliberately small: Robert Haas, Bruce Momjian, and Tom Lane, with seven branch-qualified commits. Its research is agent-inspected and provisional; `agent-reviewed` does not mean human-reviewed. It does not establish company sponsorship or support population-wide company totals.

## Run it

```sh
python3 scripts/author_company_history.py validate \
  --data-dir data/author-affiliations

python3 scripts/author_company_history.py extract-credits \
  --commits data/author-affiliations/commits.json \
  --out /tmp/author-affiliation-credits.json

python3 scripts/author_company_history.py build \
  --data-dir data/author-affiliations \
  --commits data/author-affiliations/commits.json \
  --out-dir /tmp/author-affiliation-build
```

The default timestamp basis is `committer`, which uses `commit_date` (the recorded Git committer timestamp). Use `--timestamp-basis author` to select the separate recorded `author_date`. A missing or invalid selected timestamp remains unknown; the other timestamp is never substituted. The output directory can be reused, with each output replaced atomically after validation. It cannot alias an input file through a path or symlink.

The build writes deterministic `raw_credits.json`, `commit_author_companies.json`, `coverage.json`, and `manifest.json`. The output manifest contains SHA-256 hashes of every input JSON file and the commit snapshot, plus hashes of all generated data files. No build timestamp is injected, so identical inputs produce byte-identical outputs.

## Input contract

All files are required. Array files contain JSON arrays; `manifest.json` is an object. IDs are stable strings within a dataset revision.

`people.json` rows:

```json
{"person_id":"person:robert-haas","display_name":"Robert Haas"}
```

`identity-mappings.json` rows:

```json
{"mapping_id":"map:robert-gmail","email":"robertmhaas@gmail.com","person_id":"person:robert-haas","decision":"reviewed","review_status":"agent-reviewed","evidence_ids":["ev:robert-2011"],"mapping_revision":"pilot-agent-reviewed-2026-09-29-v1"}
```

`decision` is `reviewed`. `review_status` is `agent-reviewed` or `human-reviewed`; use the latter only after an actual human review. Matching trims outer whitespace and ignores case only in the domain. The local part is case-sensitive. Names alone never map identities. A mapping needs evidence for the same person and exact sender address. Mapping revisions allow corrections without losing previous decisions.

`companies.json` rows:

```json
{"company_id":"company:enterprisedb","name":"EnterpriseDB","aliases":["EDB","EnterpriseDB"]}
```

Aliases are historical labels for the same company identity. Do not rewrite an old affiliation to the current name of a successor company.

`evidence.json` rows:

```json
{"evidence_id":"ev:robert-2011","person_id":"person:robert-haas","sender_email":"robertmhaas@gmail.com","company_id":"company:enterprisedb","message_id":"<message-id>","source_url":"https://www.postgresql.org/message-id/...","context":"Robert's first-person statement and own signature","excerpt":"short relevant source excerpt","source_date":"2011-04-21T19:39:18Z","effective_date":null,"retrieved_at":"2026-09-29T00:00:00Z","retrieval_precision":"day","evidence_kind":"mail_body_first_person","review_status":"agent-reviewed"}
```

`source_url` or `message_id` is required. `person_id` identifies whose affiliation is described, and `context` explains why the excerpt belongs to that person. `company_id` may be null for observations that mention no company. `evidence_kind` is `mail_body_first_person`, `mail_signature`, `company_announcement`, `personal_announcement`, `conference_bio`, `mutable_inconclusive_observation`, or `other`. `review_status` is `agent-reviewed`, `human-reviewed`, or `rejected`. Rejected observations remain auditable but cannot support mappings or histories. Source dates describe the message/publication; `effective_date` is reserved for an explicit effective date; `retrieved_at` records collection time. `retrieval_precision` is `instant` or `day`.

Message-IDs are unique within accepted evidence. If a source revision must be retained, give each row a distinct positive `source_revision` and link each newer row to its predecessor with `supersedes_evidence_id`. Do not silently replace the earlier excerpt.

`histories.json` rows:

```json
{"history_id":"hist:bruce-2025-02-18-observation","person_id":"person:bruce-momjian","company_id":"company:enterprisedb","relationship_type":"other","status":"estimated","start_earliest":"2025-02-18T00:00:00Z","start_latest":"2025-02-18T23:59:59Z","start_precision":"day","end_earliest":"2025-02-18T23:59:59Z","end_latest":"2025-02-19T00:00:00Z","end_precision":"day","end_ongoing":false,"evidence_ids":["ev:bruce-2025-02-18"],"history_revision":"pilot-agent-reviewed-2026-09-29-v1","estimation_method":"signature observation on this UTC day only","review_status":"agent-reviewed"}
```

`relationship_type` is `employment`, `consulting`, `other`, or `unknown`; none implies patch sponsorship. `status` is `supported`, `estimated`, `unknown`, or `conflicting`. `start_precision` and `end_precision` are `instant`, `day`, `month`, `year`, or `unknown`. Bounds are timezone-aware ISO-8601 instants in UTC and define half-open periods. A date-only bound is interpreted as midnight UTC; express month/year uncertainty with explicit earliest/latest instants.

For start bounds `[s_min, s_max]` and end bounds `[e_min, e_max]`, possible membership is `[s_min, e_max)` and guaranteed membership under that reviewed period hypothesis is `[s_max, e_min)` when nonempty. An empty guaranteed interval does not strengthen evidence: a merely possible boundary match is estimated, and unknown boundaries stay unknown. A bounded end or `end_ongoing: true` is required for a supported/estimated history. Ongoing histories require an explicit `as_of` timestamp and produce no membership at or after that horizon. Missing signatures never establish departure; one observation is not extended to nearby years.

Optional `relationship_group_id` and `relationship_group_mode` express multiple-company cases. The mode is `concurrent` or `alternative`. Multiple active companies without one explicit shared concurrent group are treated as unclassified/conflicting candidates. Alternative candidates never count as two supported affiliations. Gaps and overlaps are retained.

`retrieval-ledger.json` rows:

```json
{"ledger_id":"ledger:robert-no-match-control","query":"zzamautaaffiliationnomatch73921","senders":["robertmhaas@gmail.com"],"after":"2026-08-01T00:00:00Z","before":"2026-09-29T00:00:00Z","offset":0,"limit":3,"retrieved_at":"2026-09-29T00:00:00Z","retrieval_precision":"day","message_ids":[],"result_count":3,"semantics_verified":false,"coverage_status":"sampled","coverage_note":"Sender/date matches appeared despite no query-term match."}
```

`coverage_status` is `sampled`, `bounded`, or `exhaustive`; exhaustive requires `semantics_verified: true`. The pilot records eight actual search requests with their sender/date filters, pagination and returned Message-IDs. Retrieval times have day-level precision. Only the full messages identified in `evidence.json` were accepted for review; other search hits are discovery results. A sender/date hit is not necessarily a query-term match. Search results do not prove mailbox completeness, and no hit does not prove no affiliation. Re-scan overlapping windows to catch late imports or corrections.

`manifest.json`:

```json
{"schema_version":"1","evidence_snapshot":"...","mapping_revision":"...","history_revision":"...","rule_revision":"author-company-attribution/1","retrieval_ledger_revision":"..."}
```

The checked-in manifest also records the full source-export SHA-256 and the exact branch-qualified selection. Updating any pilot JSON input requires updating the relevant revision and the manifest's evidence/source provenance.

## Output and interpretation

Credits are extracted from Git author fields, `trailer_author`, and `co_authored_by`, retaining every occurrence, role, original value, and stable branch/commit/role/ordinal ID. Unsupported address lists remain opaque. Repeated resolved people on one commit are grouped only after exact-email mapping, with all raw credit IDs and roles retained. Unresolved name-only and unmapped addresses remain output rows with null `person_id`.

`commit_author_companies.json` uses branch plus commit ID, chosen timestamp and basis, separate identity and affiliation status, source mapping/history IDs, raw credit links, candidate company, relationship, and evidence IDs. `coverage.json` reports raw-credit denominators and identity resolution separately by role and by year/role, as well as affiliation status by role/year/role. Invalid timestamps are excluded from time buckets and remain visible in participant records.

The seven-row sample preserves these constraints: Robert's Gmail patch credit maps from inspected mail, while `rhaas@postgresql.org` remains unresolved; Bruce's commit shortly precedes a same-day EDB signature and is only estimated; Tom's inspected message and commit leave company affiliation unknown. Four stable backpatches list Thomas Munro as Git author and Robert's Gmail address as patch author. The Databricks page discrepancy is retained as rejected evidence, with no claimed transition date.

## PostgreSQL schema

`sql/author-company-history.sql` defines parallel `author_company_*` tables for revisions, people, companies/aliases, evidence, exact-email mappings, raw credits and revised resolutions, affiliation history, retrieval runs, and derived attributions. Revision keys are part of mapping/history identities so corrected snapshots can coexist. The schema has no foreign keys into the current commits pipeline. It is DDL only: there is not yet an importer from pilot JSON, and it has not been applied by this command. The offline JSON files remain the pilot's durable source of truth.

## Verification and next milestones

Run the offline regression suite and the optional isolated PostgreSQL schema test:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_author_company_history.py' -v
bash scripts/test-author-company-history.sh
```

The initial implementation passed 20 Python cases, including deterministic
rebuilds, corrected mappings, uncertain periods, concurrent/alternative
companies, missing timestamps and protection of input files. Independent checks
also covered co-author deduplication and branch-qualified backpatches. The
71,200-row local export built successfully into 83,301 raw credits and 82,782
participant records; this demonstrates processing coverage, not researched
company coverage. The schema test runs only in its own temporary PostgreSQL
cluster and checks repeat installation and retained mapping/history revisions.

The seven-commit pilot produces 16 raw credits and 15 participant records: one
estimated affiliation and fourteen unknowns. These intentionally sparse results
must not be presented as a complete employment directory. Robert Haas's
Databricks transition remains undated in the accepted evidence.

Next milestones are broader reviewed research (approximately twenty people),
verified mail-retrieval coverage, and a version-aware JSON-to-PostgreSQL importer.
Automated collection, publication through the site-generation pipeline and
company totals in the UI are not implemented by this pilot.
