import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { dashboard } from "./helpers/dashboard.mjs";
import { buildCompanyIndex } from "../site/src/company-affiliations.mjs";
import { primaryAuthorSource } from "../site/src/patch-authors.mjs";

const columns = ["When", "Branch", "Git author", "Patch authors", "Patch author companies", "Summary"];
const base = { branch: "master", author_name: "Git Owner", author_email: "git@example.test",
  author_date: "2026-01-01T12:30:00Z", commit_date: "2026-01-02T10:00:00Z", message: "A correction",
  insertions: 1, deletions: 0, changed_files: 1 };
const commits = Array.from({ length: 60 }, (_, i) => ({ ...base,
  branch: i < 30 ? "master" : "stable", commit_id: `sha-${i % 30}`, summary: `Commit ${i}`,
  author_date: new Date(Date.UTC(2026, 0, i % 30 + 1, 12, 30)).toISOString(),
  co_authored_by: ["Co Person <co@example.test>"],
  ...(i % 2 ? { trailer_author: ["Patch Person <patch@example.test>"] } : {}),
}));
const plain = (value) => JSON.parse(JSON.stringify(value));

function withCompanies(rows = commits) {
  const ui = dashboard(rows);
  const matches = rows.map((row, i) => ({ branch: row.branch, commit_id: row.commit_id,
    author_source: primaryAuthorSource(row), companies: [{ company_id: i % 2 ? "edb" : "other",
      status: i % 2 ? "estimated" : "supported" }] }));
  ui.state.companyIndex = buildCompanyIndex({ schema_version: 3, attribution_source: "trailer_author_or_git_author",
    provenance: { timestamp_basis: "committer" }, coverage: { total_commits: rows.length, matched_commits: rows.length, researched_people: 2 },
    companies: [{ company_id: "edb", name: "EnterpriseDB", aliases: ["EDB"] },
      { company_id: "other", name: "Other Company", aliases: [] }], matches }, rows);
  ui.renderDashboard();
  return ui;
}

test("download has exactly the visible columns and ALL matching rows in table order", () => {
  const ui = withCompanies();
  const before = JSON.stringify(commits);
  const rows = plain(ui.matchingCommitRows());
  assert.equal(rows.length, 60);
  assert.equal(ui.state.filteredRecentCommits.length, 25);
  assert.equal(ui.element("#download-matching-commits").textContent, "Download JSON (60)");
  assert.equal(ui.element("#download-matching-commits").disabled, false);
  const html = readFileSync(new URL("../site/src/index.html", import.meta.url), "utf8");
  const table = html.slice(html.indexOf('<table class="recent-commits-table">'));
  assert.deepEqual([...table.matchAll(/<th>(.*?)<\/th>/g)].map((m) => m[1]), columns);
  for (const row of rows) {
    assert.deepEqual(Object.keys(row), columns);
    assert.ok(Object.values(row).every((value) => typeof value === "string"));
  }
  assert.deepEqual(rows.slice(0, 25).map((row) => row.Summary), Array.from(ui.state.filteredRecentCommits, (c) => c.summary));
  assert.deepEqual(rows.slice(0, 2).map((row) => row.Branch), ["master", "stable"]);
  assert.equal(rows[0].When, "Jan 30, 2026, 12:30 PM"); // Git author date, UTC, not commit_date.
  assert.equal(JSON.stringify(commits), before);
  ui.state.filters.metric = "insertions";
  ui.renderDashboard();
  assert.deepEqual(plain(ui.matchingCommitRows()), rows);
});

test("download obeys branch, contributor, inclusive dates, company and estimate filters", () => {
  const ui = withCompanies();
  ui.state.filters.branches = new Set(["master"]);
  ui.state.filters.authors = new Set([JSON.stringify(["email", "co@example.test"])]);
  ui.state.filters.startDate = "2026-01-05";
  ui.state.filters.endDate = "2026-01-12";
  ui.state.filters.companies = new Set(["edb"]);
  ui.renderDashboard();
  assert.deepEqual(plain(ui.matchingCommitRows()).map((r) => r.Summary), ["Commit 11", "Commit 9", "Commit 7", "Commit 5"]);
  assert.equal(ui.element("#download-matching-commits").textContent, "Download JSON (4)");
  ui.state.filters.includeEstimated = false;
  ui.renderDashboard();
  assert.deepEqual(plain(ui.matchingCommitRows()), []);
  assert.equal(ui.element("#download-matching-commits").disabled, true);
  ui.state.filters.companies.clear();
  ui.renderDashboard();
  const rows = plain(ui.matchingCommitRows());
  assert.equal(rows.length, 8);
  assert.equal(rows[0]["Patch author companies"], "No usable evidence");
  ui.state.filters.authors = new Set([JSON.stringify(["email", "patch@example.test"])]);
  ui.renderDashboard();
  assert.equal(ui.matchingCommitRows().length, 4);
});

test("export preserves Unicode, raw text, all patch authors and visible fallback/empty labels", () => {
  const ui = dashboard([{ ...base, commit_id: "raw", summary: 'Fix "quotes", \\slashes\\ and <script> & café\nSecond line',
    author_name: "Zoë <script>", co_authored_by: ["José <co@example.test>", "José <co@example.test>"] }]);
  ui.renderDashboard();
  const [row] = plain(ui.matchingCommitRows());
  assert.equal(row["Git author"], "Zoë <script>");
  assert.equal(row["Patch authors"], "Zoë <script> <git@example.test> (commit-author fallback)\nJosé <co@example.test>");
  assert.equal(row["Patch author companies"], "Unavailable");
  assert.equal(row.Summary, ui.state.data.commits[0].summary);
  assert.doesNotMatch(ui.render()[0], /<script>/);
  ui.state.data.commits = [{ ...base, commit_id: "unextracted", message: "Author: Someone\n\nBackpatch-through: 19" }];
  ui.render();
  assert.equal(ui.matchingCommitRows()[0]["Patch authors"], "—");
});

test("button creates a JSON download of current filters and releases temporary resources", async () => {
  const ui = withCompanies();
  const button = ui.element("#download-matching-commits");
  button.dispatch("click");
  assert.equal(ui.downloads.length, 1);
  assert.equal(ui.downloads[0].filename, "matching-commits.json");
  assert.equal(ui.downloads[0].blob.type, "application/json;charset=utf-8");
  const first = JSON.parse(await ui.downloads[0].blob.text());
  assert.deepEqual(first, plain(ui.matchingCommitRows()));
  assert.equal(first.length, 60);
  assert.equal(ui.document.body.children.length, 0);
  ui.state.filters.branches = new Set(["stable"]);
  ui.renderDashboard();
  button.dispatch("click");
  const second = JSON.parse(await ui.downloads[1].blob.text());
  assert.equal(second.length, 30);
  assert.ok(second.every((row) => row.Branch === "stable"));
  assert.equal(first.length, 60); // First file is an immutable click-time snapshot.
  ui.state.filters.authors = new Set(["absent"]);
  ui.renderDashboard();
  button.dispatch("click");
  assert.equal(ui.downloads.length, 2);
  ui.state.data = null;
  ui.downloadMatchingCommits();
  assert.equal(ui.downloads.length, 2);
  await new Promise((resolve) => setTimeout(resolve, 1100));
  assert.equal(ui.objectUrls.size, 0);
  assert.deepEqual(ui.revokedUrls, ui.downloads.map((d) => d.url));
});
