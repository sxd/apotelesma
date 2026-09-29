# Initial affiliation pilot research

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
