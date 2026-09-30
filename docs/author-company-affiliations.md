# Author/company affiliation research

This is an evidence-linked pilot for estimating which companies commit participants were associated with at a recorded commit timestamp. Offline research consumes the existing commits JSON format; the site build now publishes a compact filtering projection. The checked-in input lives in `data/author-affiliations/`; keep it out of `site/data/`, which `scripts/export-json.sh` clears before export.

The 2026-09-30 expansion covers 58 people and 62 reviewed email identities across the six requested companies. The original evidence is preserved. `commits.json` retains the original seven branch-qualified commits; `company-coverage-commits.json` retains the separate six-company regression sample. Research is agent-inspected and provisional; `agent-reviewed` does not mean human-reviewed. It does not establish company sponsorship or support population-wide company totals.

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

# Read-only JSON inventory of every patch-author candidate in the full export.
python3 scripts/author_company_history.py research-coverage \
  --data-dir data/author-affiliations \
  --commits site/data/commits.json
```

The default timestamp basis is `committer`, which uses `commit_date` (the recorded Git committer timestamp). Use `--timestamp-basis author` to select the separate recorded `author_date`. A missing or invalid selected timestamp remains unknown; the other timestamp is never substituted. The output directory can be reused, with each output replaced atomically after validation. It cannot alias an input file through a path or symlink.

The build writes deterministic `raw_credits.json`, `commit_author_companies.json`, `coverage.json`, and `manifest.json`. The output manifest contains SHA-256 hashes of every input JSON file and the commit snapshot, plus hashes of all generated data files. No build timestamp is injected, so identical inputs produce byte-identical outputs.

`research-coverage` prints JSON to stdout without changing any files. It lists
all `trailer_author` candidates, exact raw values, branch-qualified commit
counts, date bounds, reviewed identity status, companies with histories and
actual matched-commit counts. Email keys are not unique people; opaque and
name-only credits remain separate. The report includes input fingerprints and
explicitly does not claim exhaustive affiliation research.

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

`coverage_status` is `sampled`, `bounded`, or `exhaustive`; exhaustive requires `semantics_verified: true`. The expanded ledger records 210 completed search requests with exact filters, pagination and returned Message-IDs. Retrieval times have day-level precision. Only messages identified in `evidence.json` support accepted claims; other search hits are discovery results. A sender/date hit is not necessarily a query-term match. Search results do not prove mailbox completeness, and no hit does not prove no affiliation. Re-scan overlapping windows to catch late imports or corrections.

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

The original seven-commit fixture still produces 16 raw credits and 15 participant
records. New evidence now supports five estimated Robert Haas patch-author
matches that were previously unknown. Robert's Databricks signature is observed
on 2026-09-29; his exact transition date remains unknown.

Next milestones are filling the reported identity/date gaps, verified
mail-retrieval coverage, and a version-aware JSON-to-PostgreSQL importer.
Automated collection and population-wide company totals remain unimplemented.

## Website company selector

`scripts/build-site.sh` now requires Python 3 and generates
`site/dist/data/company_affiliations.json` after copying the published commits.
It uses the full published snapshot, **not** the seven-commit research fixture.
`AFFILIATION_DATA_DIR` can select another validated research directory. No live
database import is necessary. The existing site-generation and Pages workflows
both call this build step; research inputs remain outside their disposable data.

The same export can be generated independently:

```sh
python3 scripts/author_company_history.py build-site \
  --data-dir data/author-affiliations \
  --commits site/data/commits.json \
  --out-dir /tmp/company-site-export \
  --timestamp-basis committer
```

The website JSON uses `schema_version: 2` and
`attribution_source: "trailer_author"`. It contains company IDs/names/aliases,
sparse branch-qualified commit/company matches, supported/estimated labels, and
coverage denominators. The client rejects version 1 all-participant exports and
exports with a different attribution source, even when their commit hash matches.
It retains input hashes and mapping/history/rule revisions. Its commit SHA-256
is verified against the actual fetched commits before filtering. This check
uses Web Crypto (HTTPS, or localhost when previewing). Invalid/stale/missing
company data disables only the company selector; the author/branch/date
dashboard remains usable. Invalid research fails the build rather than
publishing invented affiliations.

The **Patch author companies · Research preview** control supports name/alias search, eight
suggestions, persistent removable chips, multiple checkbox selections, clear
search/selection, and keyboard navigation. Its matching contract is:

- Selected companies are ORed, then ANDed with branch, date and author filters.
- A company can match only through a resolved `trailer_author` (`Author` trailer)
  participant. A Git author, committer or `Co-authored-by` credit alone never
  supplies a match. Missing, name-only or otherwise unresolved patch authors do
  not fall back to another role. Someone with multiple roles qualifies only if
  also resolved from `trailer_author`. The full offline audit retains all roles.
  Author and company filters apply independently to the commit;
  they need not match the same person. This is not a person-at-company query.
- No companies selected means unrestricted, including unknown affiliations.
- Estimates are included by default. Turning them off affects company matches,
  option counts and table labels, but does not exclude otherwise eligible
  commits when company selection is unrestricted.
- Unknown/conflicting participants and candidate affiliations never match.
  Explicit concurrent companies may both match. Each branch/commit is counted
  once; repeated roles or selected companies cannot multiply its metrics.
- A supported patch author takes precedence over an estimated patch author for
  the same company on the same commit. Detailed participant and evidence links
  remain in the offline audit export, not this compact UI projection.
- Option counts and coverage use branch/date scope before author/company
  selection. Search, scope changes and estimate exclusion never silently clear
  company selections. Zero-match selections stay selected and show no results.
- The reviewed company catalog remains searchable even when a company has no
  eligible patch-author matches. Such options show zero, do not manufacture
  evidence, and return no commits if selected alone. Rejected evidence never
  supplies a match.
- Patch-author company histories use Git **committer** timestamps in the site pipeline;
  existing date filters/charts still use Git author dates. Backpatch branch/ID
  pairs remain distinct. This selects the attribution date, not the committer's
  company. The UI explains this difference and does not imply company
  sponsorship. Recent commits show a **Patch author companies** column with
  company names and status labels.

The research now covers 58 people and all six requested companies:
Microsoft, Amazon Web Services (AWS), Databricks, Snowflake, EnterpriseDB and
Percona. Amazon/AWS and EnterpriseDB/EDB aliases do not create duplicate totals;
“Snowflakes” is accepted as a search spelling. The catalog does not imply that
every employee or commit has been researched. More companies appear when added
to the reviewed catalog; only accepted dated patch-author evidence creates matches.

Individual signatures still provide narrow observation-day estimates. The
expansion adds 239 explicitly estimated intervals between consecutive reviewed
same-company observations no more than 366 days apart. These intervals never
extend before the first or beyond the last observed day; another observed
company prevents bridging, and larger gaps remain unknown. This is a curated
continuity hypothesis, not a proven employment interval or an automatic build
inference. Microsoft also supplies an explicit retrospective 2024 team list;
year-only joins retain uncertain boundaries and competing evidence stays
unresolved. Percona's
explicit retrospective statement supplies Zsolt Parragi's uncertain 2017 start
and continuing employment, capped at the retrieval horizon. Snowflake's
retrospective team account supplies an estimated Tom Lane parent/team
association after the June 2025 acquisition, **not** an exact legal-employer
transfer. Crunchy Data is not a Snowflake alias and earlier commits are not
renamed. Robert Haas and Tristan Partin have separately dated company changes;
their unobserved transition gaps remain unknown. All current
website matches are estimates; disabling estimates may show zero matches.
See `data/author-affiliations/RESEARCH.md` for sources, date bounds and caveats.

On the same verified 71,200-row local export, trailer-only attribution now yields
936 distinct branch/commit matches, up from 356 with the seven-person dataset.
These **estimated, sampled counts are not a ranking of
company contributions**; different evidence windows explain their disparity.

| Company | People with dated history | Estimated patch-author matches |
| --- | --- | ---: |
| Microsoft | 15 | 249 |
| Amazon/AWS | 9 | 78 |
| Databricks | 3 | 9 |
| Snowflake | 3 | 334 |
| EnterpriseDB/EDB | 34 | 248 |
| Percona | 2 | 26 |

People and commits may appear under more than one company, so these columns
are not additive. Only 41 researched people currently yield dated patch matches.
The inventory contains 1,787 candidate keys: 548 email keys (61 reviewed,
representing 57 people) and 1,239 unresolved name-only/opaque keys. These are
not counts of employees at the six companies. Bruce is researched but has no
resolved patch credit in this export. Some known authors have no date overlap.
The two additional Snowflake roster observations are from July 2026, later than
this export; they do not retroactively change its totals.

Bruce's Git-only EDB match remains correctly excluded. The six-company regression fixture keeps its original
real commits: four match as patch-author affiliations; the Git-only Bruce/EDB
and Tom/Snowflake cases do not. The catalog still includes all six companies.
The original seven-commit fixture gains five EDB matches through Robert's actual
patch-author identity; this does not restore the removed Git-author fallback.

The expansion ledger preserves all 33 previous queries and 177 new completed
discovery queries, including empty-string queries constrained by sender. Such requests are valid; a missing
query value or an empty query without a sender is not. These are sampled
retrievals, never an exhaustive directory.

Verification:

```sh
node --test tests/author-identities.test.mjs tests/author-filtering.test.mjs \
  tests/patch-authors.test.mjs tests/company-filtering.test.mjs
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_author_company_history.py

# Build into a dedicated disposable directory, then run optional Chromium tests.
company_test_dir=$(mktemp -d /tmp/apotelesma-company-test.XXXXXX)
SITE_DIST_DIR="$company_test_dir/site" bash scripts/build-site.sh
SITE_DIST_DIR="$company_test_dir/site" node tests/company-filtering.browser.mjs
SITE_DIST_DIR="$company_test_dir/site" node tests/author-filtering.browser.mjs
```

Browser tests accept `PLAYWRIGHT_MODULE` and `CHROMIUM_PATH` overrides for an
existing local installation, and `BROWSER_ARTIFACT_DIR` for company screenshots.
The company test covers multi-company fixtures, all six real company names and
their aliases, author combinations, native
keyboard behavior, accessibility-tree labels, zero-count company selection,
legacy/wrong-role/stale/missing/malformed/empty
exports, literal hostile text, real full-export filtering and 1440/1000/720/375/320
pixel layouts. Screen-reader output and native zoom are not asserted.
