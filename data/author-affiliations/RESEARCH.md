# Author/company research

## Expanded coverage (2026-09-30)

This revision expands the seven-person sample to **58 people**, **62 exact email
mappings**, **337 evidence records** and **560 reviewed history hypotheses**.
The six company identities and the trailer-author-only website contract are
unchanged. Old evidence, rejected observations and both commit fixtures are
preserved. This is agent-reviewed research, not human-approved employment data.

The full commit export has SHA-256
`09108f7ab144fbe75277921b01abd915a8240eb945b7d880b29462c449279114`.
The read-only `research-coverage` command inventories every trailer credit:
1,787 candidate keys, including 548 exact parsed email keys and 1,239 name-only
or opaque keys. Of the email keys, 61 resolve to 57 researched people. Bruce's
identity is researched but has no resolved patch-author occurrence in this
export. These denominators cover all companies, not only the six requested ones.
They are not unique-person counts and do not imply exhaustive employer research.

### Collection and evidence review

Amauta `pgsql-hackers` searches covered company names/aliases and exact sender
addresses discovered in the complete patch-credit inventory. The ledger adds
177 completed requests to the previous 33, preserving exact query/filter/offset
arguments and 4,589 distinct returned Message-IDs in this pass. There were 597
distinct message records fetched for inspection; 275 new sender-owned company
signatures were accepted. First-person job statements, identity-only messages
and dated primary company announcements are recorded separately.

Searches and selected messages span multiple years, but this is **sampled
retrieval**, not a full mailbox sweep. Broad company queries used selected
offsets, not every page. Sender searches sometimes returned no hits despite
known public messages, and a nonsense keyword with a sender filter still
returned mail. Query semantics, boundary inclusivity and completeness remain
unverified. Seven requests with an invalid limit of 1,000 failed before search;
a slow yearly date-window sweep was stopped without usable results. Neither
is included among the 177 completed requests or treated as negative evidence.

Company names in product discussions, build logs, someone else's quoted
signature, or an address domain alone were not accepted as affiliation evidence.
Malformed archive records with synthetic `generated.invalid` Message-IDs were
excluded. Exact public sender addresses support identity mappings; no fuzzy
name, plus-address or local-part case folding was introduced. The Amauta miss
for Tomas Vondra's personal address was supplemented by a public PostgreSQL
archive sender header, explicitly identified as such in its evidence record.

### Dates and estimates

Each company signature remains an observation of association on its message
date, not proof of employment or patch sponsorship. An isolated observation
still supports only its own UTC day. In addition, 239 curated intervals apply
`bounded-observation-gap/1`: estimate continuity only between consecutive
reviewed observations of the same person's same company no more than 366 days
apart. Each interval cites both endpoints, retains day-level uncertainty, and
is marked `estimated`. A different company at either endpoint or in between
prevents bridging. There is no extrapolation before/after the observed dates,
and larger gaps remain unknown. The offline builder consumes these explicit
histories; it does not infer new intervals automatically.

[Microsoft's retrospective team article](https://techcommunity.microsoft.com/blog/adforpostgresql/microsoft-postgresql-oss-engine-team-reflecting-on-2024/4388700)
names eleven contributors, including four who joined during 2024. The latter
retain year-level start uncertainty; existing members' 2024 association is also
an estimate, not a hire date. The source was published March 7, 2025 and updated
May 3; the update is the observation horizon, not an employment-change date.
The [2025 team update](https://techcommunity.microsoft.com/blog/adforpostgresql/whats-new-with-postgres-at-microsoft-2025-edition/4410710/)
provides additional observations for explicitly identified teammates, not
podcast guests or every acknowledged reviewer. Its publication and update
dates are recorded separately. Overlapping prior EDB observations remain
competing evidence, not two automatically supported employers.

[EDB's April 2025 announcement](https://www.enterprisedb.com/blog/jacob-champion-becomes-postgresql-committer?lang=en),
[September release article](https://www.enterprisedb.com/blog/celebrating-postgresql-18-release)
and [June 2026 team report](https://www.enterprisedb.com/blog/pgconfdev-2026-our-teams-sessions-working-groups-and-key-takeaways)
support named team members without inferring affiliation from all conference
participants. [Snowflake's July 2026 roster](https://www.snowflake.com/en/developers/postgres/about-snowflake-postgres-team/)
adds David Christensen and Greg Sabino Mullane on the roster's update date
only. Their histories are not backdated to the acquisition. Existing Tom Lane
parent/team and Zsolt Parragi retrospective histories are unchanged.

Robert Haas has an EDB signature on August 31, 2026 and a sender-owned
[Databricks signature on September 29](https://www.postgresql.org/message-id/CA%2BTgmobUaa0OAkUBOy0E-BxkG1k%2B0FZacFzp93_sPJPDQgx3Tw%40mail.gmail.com).
This supersedes the initial pilot's lack of accepted Databricks evidence, not
its rejected mutable-blog observation. The exact transition remains undated.
Tristan Partin likewise has Databricks observations through January 2026 and
an AWS signature on September 28, with the intervening gap left unknown.
Andres Freund's September 2017 first-person EDB announcement explicitly mentions
a simultaneous Citus advisory role; it is not evidence of Microsoft employment
in 2017. Peter Geoghegan's first-person Amazon statement is a dated observation,
not a guessed start date.

### Result and remaining gaps

On the same 71,200-commit export, the website now matches 936 distinct
branch/commit rows through dated patch authors (previously 356). There are 41
people with usable date overlaps. Company match counts are Microsoft 249,
Amazon/AWS 78, Databricks 9, Snowflake 334, EDB 248 and Percona 26. They overlap,
are all estimates, and are not a ranking of company contributions.

Some known people still have no dated match in this export, including Richard
Guo, Vignesh C, David Christensen and Greg Sabino Mullane. Additional research
is needed between their known observations and their patch dates. Corporate
address leads remain unresolved for Sait Nisanci, Craig Ringer, Davinder Singh,
Florin Irion, Jakub Wartak, Jeevan Ladhe, Jelte Fennema-Nio, Markus Wanner,
Maxime Schoemans and Mikhail Kot; further corporate aliases of already reviewed
people also remain unmapped. Their domains are leads, not evidence. Name-only
credits, unsupported aliases and older history gaps remain in the inventory.
No absence of employment is inferred. Re-run `research-coverage` against each
new export to prioritize these gaps without reintroducing a hand-picked list.

## Initial affiliation pilot research (historical snapshot)

Collected on 2026-09-29 through Amauta's `pgsql-hackers` inbox. This is a
bounded, agent-inspected sample, not a human-approved employment directory or
an exhaustive history. Names and addresses below are public contribution
identities. A signature establishes an observed association, not necessarily
employment, a start/end date, or sponsorship of a patch.

## Robert Haas

- Sender `robertmhaas@gmail.com`, Message-ID
  `BANLkTikApk8XwmfVdca7ufDhzBh17q3Emw@mail.gmail.com`,
  source timestamp `2011-04-21T19:39:18+00:00`.
  [Archive](https://www.postgresql.org/message-id/BANLkTikApk8XwmfVdca7ufDhzBh17q3Emw%40mail.gmail.com).
  Full message inspected: first-person discussion explicitly describes working
  at EnterpriseDB. Relevant short excerpt: “for so long as I am working here”.
  Signature identifies Robert Haas and EnterpriseDB. Do not extrapolate this
  observation through the subsequent fifteen years.
- Same sender, Message-ID
  `CA+TgmobD+yMc_jkmk=Vr0UWm9y8AyRFdH+CLZaCukFUoXpCG2A@mail.gmail.com`,
  source timestamp `2025-02-28T20:37:49+00:00`.
  [Archive](https://www.postgresql.org/message-id/CA%2BTgmobD%2ByMc_jkmk%3DVr0UWm9y8AyRFdH%2BCLZaCukFUoXpCG2A%40mail.gmail.com).
  Full message inspected. Sender's own signature: “Robert Haas / EDB:
  http://www.enterprisedb.com” (slash represents a line break).
- Same sender, Message-ID
  `CA+TgmobXc2+F1-n7FQqYEfMUzztHtJ7DJpGrODv9CVUnc0AoaA@mail.gmail.com`,
  source timestamp `2026-08-31T04:55:28+00:00`.
  [Archive](https://www.postgresql.org/message-id/CA%2BTgmobXc2%2BF1-n7FQqYEfMUzztHtJ7DJpGrODv9CVUnc0AoaA%40mail.gmail.com).
  Full message inspected. Sender's own signature again identifies Robert Haas
  and EDB. A long continuous affiliation between the two signatures would be
  an explicitly low-confidence estimate, not confirmed employment.
- Same sender, Message-ID
  `CA+TgmoY2feo+4pbB6C84WPWOgv1Cfk8Y5sWfb=pi3jm4dm2COA@mail.gmail.com`,
  source timestamp `2026-09-28T17:36:47+00:00`.
  [Archive](https://www.postgresql.org/message-id/CA%2BTgmoY2feo%2B4pbB6C84WPWOgv1Cfk8Y5sWfb%3Dpi3jm4dm2COA%40mail.gmail.com).
  Full message inspected. Signature contains only “Robert Haas”. The body
  names another sender's EnterpriseDB address: that is not Robert's evidence.
  Missing company text does not establish departure or a new employer.

The reported Databricks transition is unresolved in this pilot. On 2026-09-29,
web search returned a Databricks biography for
[this July blog post](https://rhaas.blogspot.com/2026/07/hacking-workshop-for-september-2026.html),
but opening that same URL returned a cached EnterpriseDB biography. Neither
mutable header nor the post's publication date establishes a transition date.
Retain this discrepancy as a research lead; do not turn it into a dated
affiliation. Do not treat the search snippet as an accepted source observation.

The commits use both `rhaas@postgresql.org` and `robertmhaas@gmail.com` in
different roles. This sample verifies the latter against mail. The former
remains an unresolved mapping unless separately evidenced; identical names
alone are not sufficient to merge them.

## Bruce Momjian

- Sender `bruce@momjian.us`, Message-ID `Z7T4X2C6OAxrEf9Y@momjian.us`,
  source timestamp `2025-02-18T21:15:11+00:00`.
  [Archive](https://www.postgresql.org/message-id/Z7T4X2C6OAxrEf9Y%40momjian.us).
- Same sender, Message-ID `Z7Uk46y32EuP4cX_@momjian.us`,
  source timestamp `2025-02-19T00:25:07+00:00`.
  [Archive](https://www.postgresql.org/message-id/Z7Uk46y32EuP4cX_%40momjian.us).

Both full messages were inspected. Both sender-owned signatures identify
“Bruce Momjian <bruce@momjian.us>” and “EDB https://enterprisedb.com”. Quoted
correspondence is not used as affiliation evidence. These nearby observations
are useful for a bounded approximation, not for claiming a long stable tenure.

The actual master commit `06dc1ffd24096f7c71d1abeaa9e96fec4db9313d` uses
`bruce@momjian.us`; author and committer timestamps are both
`2025-02-18T20:51:31+00:00`. It is about 24 minutes before the first observation.
An observation-day attribution must therefore be estimated, not an exact
timestamp match. Its name-only patch author `Laurenz Albe` must be retained as
unresolved rather than merged or dropped.

## Tom Lane

Sender `tgl@sss.pgh.pa.us`, Message-ID `4069260.1741032043@sss.pgh.pa.us`,
source timestamp `2025-03-03T20:00:43+00:00`.
[Archive](https://www.postgresql.org/message-id/4069260.1741032043%40sss.pgh.pa.us).
The full message was inspected; its closing is “regards, tom lane” and contains
no company statement. This supports matching the recorded sender identity,
not a company attribution. Leave the affiliation unknown for this sample;
do not infer unemployment or the absence of affiliations elsewhere.

The actual master commit `95f650674d2ceea1ba6440a9b0ae89ed3867fd7e` records
`tgl@sss.pgh.pa.us` as both Git author and an Author-trailer participant. It
also credits `jian he <jian.universality@gmail.com>`. Preserve both roles and
all original credit occurrences; the second person's identity remains
unresolved in the three-person pilot. Four stable-branch versions have their
own commit IDs and slightly different timestamps.

## Retrieval coverage and limitations

Mail searches used sender/date filters with a required query. Queries included
`EDB`, `Robert Haas EnterpriseDB`, and `Tom Lane Crunchy`. Sample sizes were
two to five results per request. These are discovery samples, not an exhaustive
mailbox scan. Requests for Peter Eisentraut and Amit Kapila were exploratory
only; they do not add either person to the accepted pilot.

A control query `zzamautaaffiliationnomatch73921` with sender
`robertmhaas@gmail.com`, after `2026-08-01`, before `2026-09-29`, limit 3,
offset 0 still returned three sender/date matches with score zero. Therefore,
do not assume a returned message contains the query term. Read the full
message. No conclusion about the implementation's precise query semantics or
exhaustiveness follows from this single probe.

Two Amit Kapila probes with query `EDB`, sender `amit.kapila16@gmail.com`,
after `2025-01-01`, before `2025-03-01`, limit 3, and offsets 0 and 3 returned
different pages. Pagination exists; completeness, ordering stability, boundary
inclusivity, and late-import behavior remain unverified. Record individual
requests/results in the retrieval ledger and allow overlapping rescan windows.

Deduplicate accepted messages by Message-ID, retaining later revisions rather
than silently replacing evidence. No source assertions were derived from
quoted text, absent signatures, or unrelated people with matching names.

## Pilot acceptance

All research is agent-inspected and provisional; no human review is implied.
Reproducibility and explicit uncertainty are the milestone. Broader collection
for approximately twenty contributors and any company UI totals follow only
after reviewing coverage and uncertain results. No precise Robert Haas
transition date has been established here.

## Six-company expansion (2026-09-29)

The user requested Microsoft, Amazon/AWS, Databricks, Snowflake, EnterpriseDB/EDB
and Percona. The catalog now contains these six distinct company identities.
Amazon/AWS and EnterpriseDB/EDB are search aliases, not separate company totals.
“Snowflakes” is a search spelling only. Crunchy Data is **not** a Snowflake alias.
The original seven-commit fixture remains unchanged; `company-coverage-commits.json`
adds six real branch-qualified projections from the same full export, one
matching each company. No commit rows or company claims were invented to fill
the selector. All added histories remain estimated, with explicit bounds.

### Microsoft — Nazir Bilal Yavuz

Full mail inspected via Amauta: sender `byavuz81@gmail.com`, Message-ID
`CAN55FZ1VDwJ-ZD092ChYf++huP+-S3Cg45tJ8jNH5wx2c4BHAg@mail.gmail.com`,
dated `2026-03-18T15:50:20Z`.
[Archive](https://www.postgresql.org/message-id/CAN55FZ1VDwJ-ZD092ChYf%2B%2BhuP%2B-S3Cg45tJ8jNH5wx2c4BHAg%40mail.gmail.com).
His own signature names Microsoft. Only that UTC observation day is used;
master commit `720c9b504ec6934e93d7304e789c445dc1c09f31` has his exact
Gmail patch credit earlier that day. No Microsoft-domain guessing is used.

### Amazon/AWS — Masahiko Sawada

Full mail inspected via Amauta: sender `sawada.mshk@gmail.com`, Message-ID
`CAD21AoAS0rGxyM=o1-=+vznK-aP4vJ91tUqtJSZ2dbvoXevtmg@mail.gmail.com`,
dated `2025-10-15T00:41:52Z`.
[Archive](https://www.postgresql.org/message-id/CAD21AoAS0rGxyM%3Do1-%3D%2BvznK-aP4vJ91tUqtJSZ2dbvoXevtmg%40mail.gmail.com).
His own signature names Amazon Web Services. The same-day estimate matches the
exact Gmail patch credit in `12609fbacb007698ec91101b6464436506518346`.
`msawada@postgresql.org` is not merged into this identity.

### Databricks — Matthias van de Meent

Full mail inspected via Amauta: sender `boekewurm+postgres@gmail.com`, Message-ID
`CAEze2WhJThcajjanXoQGC3BuAGqkcSeLZMZL6z+6OZp+oHDbng@mail.gmail.com`,
dated `2026-03-02T13:08:59Z`.
[Archive](https://www.postgresql.org/message-id/CAEze2WhJThcajjanXoQGC3BuAGqkcSeLZMZL6z%2B6OZp%2BoHDbng%40mail.gmail.com).
His own signature names Databricks after thanking the committer. The same-day
estimate matches `f68d7e7483d240d8c92b8fc245a3a10199d426dd`. The non-plus
Gmail address is not merged. Robert Haas's transition remains unresolved;
the earlier rejected blog observation has not been rehabilitated.

### Percona — Zsolt Parragi

[Percona's contributor profile](https://percona.community/contributors/zsolt_parragi/),
read on 2026-09-29, explicitly describes a 2017 joining year and continued
work since then. This retrospective claim permits a bounded historical
estimate: uncertain start within 2017, exclusive review horizon 2026-09-29.
It is not an inferred date from a mutable current title.

Identity is independently tied to sender `zsolt.parragi@percona.com` via full
mail `CAN4CZFNka+2q3=-Dithr4w65RJfwPaV92T62spEzLn+T4MgcMg@mail.gmail.com`,
dated `2025-02-18T20:02:13Z`.
[Archive](https://www.postgresql.org/message-id/CAN4CZFNka%2B2q3%3D-Dithr4w65RJfwPaV92T62spEzLn%2BT4MgcMg%40mail.gmail.com).
That mail discusses his pgindent patch but has no employer statement. It is
identity evidence only; the company claim comes from Percona's explicit history.
Commit `8e4d72573cc8b8bdc081661c0a3a76d6573eaa38` carries the exact patch credit.

### Snowflake — Tom Lane

[Snowflake's own team history](https://www.snowflake.com/en/developers/postgres/about-snowflake-postgres-team/),
updated 2026-07-14 and read 2026-09-29, describes Tom's continuing team role
from Crunchy Data and the June 2025 acquisition. This supports an **inferred,
estimated parent/team association**, not a verified legal employer-transfer
date. The transition window is June 1–July 1, 2025; the exclusive observation
horizon is July 15, 2026. Earlier Crunchy Data work is not renamed. Tom's exact
mail identity was already verified. The fixture uses his July 1, 2025 commit
`1fd772d192909a4f0e1ce88ebc72c8c43b81b025`.

### Discovery provenance and limitations

The ledger adds all 25 actual Amauta searches from this expansion, including
zero-result queries, exact sender/date filters and all 65 returned hits (some
repeated). Two sender-filtered queries deliberately used an empty string;
the ledger retains that exact string rather than inventing search terms.
Query semantics and completeness are still unverified. Only the four new
messages explicitly cited above become evidence, plus the two primary company
pages; other inspected/discovered mail was not sufficient or not needed.
EDB retains its original Bruce Momjian estimate. Seven people are researched,
not every contributor to any of these companies. None of these results is a
complete company contribution or employment-history report.
