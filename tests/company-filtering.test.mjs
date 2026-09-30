import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { buildCompanyIndex, commitCompanies, matchesSelectedCompanies, summarizeCompanies, verifyCompanySnapshot } from "../site/src/company-affiliations.mjs";
import { dashboard } from "./helpers/dashboard.mjs";

const base = { branch: "master", author_name: "Git Owner", author_email: "owner@example.test",
  author_date: "2025-02-18T10:00:00Z", commit_date: "2025-02-18T11:00:00Z", insertions: 1, deletions: 0, changed_files: 1 };
const commits = [
  { ...base, commit_id: "one", summary: "First", trailer_author: ["Patch Person <patch@example.test>"] },
  { ...base, commit_id: "two", summary: "Second", trailer_author: ["Second Person <second@example.test>"], co_authored_by: ["Coauthor <co@example.test>"] },
  { ...base, commit_id: "both", summary: "Concurrent", trailer_author: ["Third Person <third@example.test>", "Fourth Person <fourth@example.test>"] },
  { ...base, commit_id: "one", branch: "stable", summary: "Backpatch" },
  { ...base, commit_id: "unknown", summary: "Unknown" },
];
export function fixture(rows = commits) {
  return {
    schema_version: 2, attribution_source: "trailer_author", provenance: { timestamp_basis: "committer" },
    coverage: { total_commits: rows.length, matched_commits: 3, researched_people: 3 },
    companies: [
      { company_id: "edb", name: "EnterpriseDB", aliases: ["EDB"] },
      { company_id: "other", name: "Another Company", aliases: ["Example"] },
    ],
    matches: [
      { branch: "master", commit_id: "one", companies: [{ company_id: "edb", status: "estimated" }] },
      { branch: "master", commit_id: "two", companies: [{ company_id: "other", status: "supported" }] },
      { branch: "master", commit_id: "both", companies: [{ company_id: "edb", status: "supported" }, { company_id: "other", status: "estimated" }] },
    ],
  };
}

test("company OR deduplicates commits, keys include branch, unknowns only match unrestricted", () => {
  const index = buildCompanyIndex(fixture(), commits);
  const selected = new Set(["edb", "other"]);
  assert.deepEqual(commits.filter((commit) => matchesSelectedCompanies(commit, selected, index)).map((c) => c.summary), ["First", "Second", "Concurrent"]);
  assert.equal(matchesSelectedCompanies(commits[4], new Set(), index), true);
  assert.deepEqual(commitCompanies(commits[3], index), []);
  assert.equal(summarizeCompanies(commits, index).matched, 3);
  assert.deepEqual(summarizeCompanies(commits, index).options.map((c) => c.count), [2, 2]);
  assert.equal(summarizeCompanies(commits, index, false).matched, 2);
  assert.equal(matchesSelectedCompanies(commits[0], new Set(["edb"]), index, false), false);
});

test("malformed, conflicting, duplicated and foreign-snapshot matches are rejected", () => {
  for (const mutate of [
    (s) => { s.schema_version = 1; },
    (s) => { s.schema_version = 3; },
    (s) => { delete s.attribution_source; },
    (s) => { s.attribution_source = "git_author"; },
    (s) => { s.attribution_source = "co_authored_by"; },
    (s) => { s.coverage.total_commits++; },
    (s) => { s.provenance.timestamp_basis = "fallback"; },
    (s) => { s.matches[0].companies[0].status = "conflicting"; },
    (s) => { s.matches[0].companies[0].company_id = "absent"; },
    (s) => { s.matches[0].branch = "absent"; },
    (s) => { s.matches[1] = s.matches[0]; },
    (s) => { s.companies[1] = s.companies[0]; },
    (s) => { s.matches[0].companies.push(s.matches[0].companies[0]); },
  ]) {
    const snapshot = fixture(); mutate(snapshot);
    assert.throws(() => buildCompanyIndex(snapshot, commits));
  }
});

test("snapshot hash verification detects stale commit data", async () => {
  const text = JSON.stringify(commits);
  const snapshot = fixture();
  snapshot.provenance.input_sha256 = { commit_snapshot_sha256: createHash("sha256").update(text).digest("hex") };
  await verifyCompanySnapshot(snapshot, text);
  await assert.rejects(() => verifyCompanySnapshot(snapshot, `${text}\n`), /different commit snapshot/);
});

function uiFixture() {
  const ui = dashboard(commits);
  ui.state.companyIndex = buildCompanyIndex(fixture(), commits);
  ui.renderDashboard();
  return ui;
}

test("dashboard combines company OR with author/branch/date AND and keeps Git metrics", () => {
  const ui = uiFixture();
  ui.state.filters.companies.add("edb");
  ui.state.filters.authors.add(JSON.stringify(["email", "patch@example.test"]));
  ui.updateDerivedState();
  assert.deepEqual(Array.from(ui.state.filteredCommits, (c) => c.summary), ["First"]);
  assert.equal(ui.state.filteredAuthors[0].author_name, "Git Owner");
  assert.match(ui.render()[0], /EnterpriseDB \(estimated\)/);
  assert.match(ui.element("#company-method").textContent, /only to patch authors in trailer_author/);
  assert.match(ui.element("#company-coverage").textContent, /patch-author affiliations/);
  ui.state.filters.includeEstimated = false;
  assert.match(ui.render()[0], /No commits match/);
  ui.state.filters.authors.clear();
  ui.state.filters.includeEstimated = true;
  ui.state.filters.branches = new Set(["stable"]);
  ui.renderDashboard();
  assert.equal(ui.state.filteredCommits.length, 0);
  assert.equal(ui.state.filters.companies.has("edb"), true);
  ui.state.filters.branches = new Set(["master"]);
  ui.state.filters.endDate = "2024-01-01";
  ui.updateDerivedState();
  assert.equal(ui.state.filteredCommits.length, 0);
});

test("catalog companies without patch-author evidence remain selectable with zero matches", () => {
  const ui = dashboard(commits);
  const data = fixture();
  data.companies.push({ company_id: "zero", name: "Zero Company", aliases: ["Zero"] });
  ui.state.companyIndex = buildCompanyIndex(data, commits);
  ui.renderDashboard();
  const search = ui.element("#company-search");
  search.value = "zero"; search.dispatch("input");
  const option = ui.element("#company-filter").querySelector("input");
  assert.equal(option.value, "zero");
  assert.match(ui.element("#company-filter").textContent, /0 commits/);
  option.checked = true; option.dispatch("change");
  assert.equal(ui.state.filteredCommits.length, 0);
  assert.equal(ui.state.filters.companies.has("zero"), true);
});

test("company search by alias only changes suggestions; chips and checkbox focus persist", () => {
  const ui = uiFixture();
  const search = ui.element("#company-search");
  search.value = "edb"; search.dispatch("input");
  const option = ui.element("#company-filter").querySelector("input");
  assert.equal(option.value, "edb");
  option.focus(); option.checked = true; option.dispatch("change");
  assert.equal(ui.document.activeElement, option);
  assert.equal(ui.state.filteredCommits.length, 2);
  search.value = "nothing"; search.dispatch("input");
  assert.equal(ui.element("#company-filter").querySelectorAll("input").length, 0);
  assert.match(ui.element("#company-selected").textContent, /EnterpriseDB/);
  ui.element("#company-clear-search").dispatch("click");
  assert.equal(search.value, "");
  assert.equal(ui.state.filters.companies.size, 1);
  ui.element("#company-clear-selection").dispatch("click");
  assert.equal(ui.state.filteredCommits.length, 5);
  assert.equal(ui.state.filters.companies.size, 0);
});

test("no research data disables only companies and safely renders text", () => {
  const ui = dashboard(commits);
  ui.renderDashboard();
  assert.equal(ui.element("#company-search").disabled, true);
  assert.match(ui.element("#company-coverage").textContent, /unavailable/);
  assert.equal(ui.state.filteredCommits.length, 5);
  const data = fixture();
  data.companies[0].name = '<img src=x onerror="alert(1)">';
  ui.state.companyIndex = buildCompanyIndex(data, commits);
  ui.state.companyScope = null;
  assert.match(ui.render()[0], /&lt;img/);
  assert.doesNotMatch(ui.render()[0], /<img/);
});

test("company filtering happens before recent-25 slicing", () => {
  const rows = Array.from({ length: 40 }, (_, i) => ({ ...base, commit_id: `c${i}`, summary: `c${i}`, trailer_author: ["Patch Person <patch@example.test>"], author_date: new Date(Date.UTC(2025, 0, i + 1)).toISOString() }));
  const data = fixture(rows);
  data.matches = rows.slice(0, 30).map((row) => ({ branch: row.branch, commit_id: row.commit_id, companies: [{ company_id: "edb", status: "estimated" }] }));
  data.coverage.matched_commits = data.matches.length;
  const ui = dashboard(rows);
  ui.state.companyIndex = buildCompanyIndex(data, rows);
  ui.state.filters.companies.add("edb");
  ui.updateDerivedState();
  assert.equal(ui.state.filteredCommits.length, 30);
  assert.equal(ui.state.filteredRecentCommits.length, 25);
  assert.equal(ui.state.filteredRecentCommits[0].commit_id, "c29");
  assert.equal(ui.state.filteredRecentCommits.at(-1).commit_id, "c5");
});
