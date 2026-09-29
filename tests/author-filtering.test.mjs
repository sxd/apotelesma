import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { dashboard } from "./helpers/dashboard.mjs";

const key = (email) => JSON.stringify(["email", email]);
const base = { branch: "master", author_date: "2026-01-01T00:00:00Z", author_name: "Git Owner", author_email: "owner@x", insertions: 3, deletions: 2, changed_files: 1, summary: "Commit" };
const inputs = (ui, group = "author") => ui.element(`#${group}-filter`).querySelectorAll("input");
const selected = (ui) => [...ui.state.filters.authors].sort();
const ids = (ui) => Array.from(ui.state.filteredCommits, (commit) => commit.commit_id);
function choose(ui, value, checked = true, group = "author") {
  const input = inputs(ui, group).find((item) => item.value === value);
  assert.ok(input, `Rendered ${group}: ${value}`);
  input.focus(); input.checked = checked; input.dispatch("change");
}
function search(ui, value) {
  const input = ui.element("#author-search");
  input.focus(); input.value = value; input.dispatch("input");
}
function date(ui, id, value) {
  const input = ui.element(id); input.focus(); input.value = value; input.dispatch("change");
}
function clearSelection(ui) {
  ui.element("#author-clear-selection").dispatch("click");
}

test("real dashboard filters Git, Author and Co-authored-by with OR and branch/date AND", () => {
  const ui = dashboard([
    { ...base, commit_id: "git", author_email: "selected@x" },
    { ...base, commit_id: "author", trailer_author: ["Selected <selected@x>"] },
    { ...base, commit_id: "coauthor", co_authored_by: ["Selected <selected@x>"] },
    { ...base, commit_id: "other", trailer_author: ["other@x"] },
    { ...base, commit_id: "branch", branch: "stable", trailer_author: ["selected@x"] },
    { ...base, commit_id: "date", author_date: "2026-01-02T00:00:00Z", trailer_author: ["selected@x"] },
  ]);
  ui.renderDashboard();
  choose(ui, key("selected@x"));
  assert.deepEqual(ids(ui), ["git", "author", "coauthor", "branch", "date"]);
  choose(ui, key("other@x"));
  assert.equal(ids(ui).length, 6);
  choose(ui, "stable", false, "branch");
  date(ui, "#start-date", "2026-01-01");
  date(ui, "#end-date", "2026-01-01");
  assert.deepEqual(ids(ui), ["git", "author", "coauthor", "other"]);
  clearSelection(ui);
  assert.deepEqual(selected(ui), []);
  assert.equal(ids(ui).length, 4);
});

test("eight-choice search affects suggestions only; chips persist and clear independently", () => {
  const commits = Array.from({ length: 85 }, (_, i) => ({ ...base, commit_id: i,
    trailer_author: [`Person ${String(i).padStart(2, "0")} <person${String(i).padStart(2, "0")}@x>`] }));
  const ui = dashboard(commits);
  ui.renderDashboard();
  assert.equal(inputs(ui).length, 8);
  assert.equal(ui.element("#author-suggestion-title").textContent, "Suggested authors");
  assert.equal(ui.element("#author-suggestion-count").textContent, "8 of 86");
  assert.equal(ui.element("#author-selected").textContent, "All authors");
  search(ui, "person84@x"); choose(ui, key("person84@x"));
  search(ui, "person83@x"); choose(ui, key("person83@x"));
  assert.deepEqual(ids(ui), [83, 84]);
  assert.match(ui.element("#author-selected").textContent, /Person 84 <person84@x>/);
  assert.match(ui.element("#author-selected").textContent, /Person 83 <person83@x>/);
  assert.equal(ui.element("#author-selected").querySelectorAll("button").length, 2);
  search(ui, "");
  assert.ok(!inputs(ui).some((input) => input.value === key("person84@x")));
  assert.match(ui.element("#author-status").textContent, /2 authors selected.*2 matching commits/);
  search(ui, "person00@x");
  date(ui, "#start-date", "2026-01-01");
  choose(ui, "stable", false, "branch");
  assert.deepEqual(selected(ui), [key("person83@x"), key("person84@x")].sort());
  assert.deepEqual(ids(ui), [83, 84]);
  search(ui, "no-such-alias");
  assert.equal(inputs(ui).length, 0);
  assert.equal(ui.element("#author-filter").textContent, "No authors match this search.");
  assert.deepEqual(ids(ui), [83, 84]);
  search(ui, "person");
  assert.equal(inputs(ui).length, 8);
  ui.element("#author-clear-search").dispatch("click");
  assert.equal(ui.element("#author-search").value, "");
  assert.deepEqual(selected(ui), [key("person83@x"), key("person84@x")].sort());
  const [removeFirst] = ui.element("#author-selected").querySelectorAll("button");
  removeFirst.dispatch("click");
  assert.equal(selected(ui).length, 1);
  clearSelection(ui);
  assert.deepEqual(selected(ui), []);
  assert.equal(ui.element("#author-selected").textContent, "All authors");
  assert.equal(ui.element("#author-clear-selection").disabled, true);
  assert.equal(ids(ui).length, 85);
});

test("pruning announces unrestricted restoration, including empty scope and branch fallback", () => {
  const ui = dashboard([{ ...base, trailer_author: ["Patch <patch@x>"] },
    { ...base, branch: "stable", author_date: "2026-02-01T00:00:00Z" }]);
  ui.renderDashboard(); choose(ui, key("patch@x"));
  choose(ui, "master", false, "branch");
  assert.deepEqual(selected(ui), []);
  assert.match(ui.element("#author-status").textContent, /1 selected author entries removed.*now unrestricted/);
  assert.equal(ui.state.filteredCommits.length, 1);
  choose(ui, "stable", false, "branch");
  assert.deepEqual([...ui.state.filters.branches], ["master"]);
  date(ui, "#start-date", "2026-03-01");
  assert.equal(ui.element("#author-filter").textContent, "No authors in this branch/date scope.");
  assert.match(ui.element("#recent-commits-body").children[0].innerHTML, /colspan="5"/);
});

test("alias search is case-insensitive, cached, and does not change global labels or selections", () => {
  const ui = dashboard([{ ...base, trailer_author: ["Zed <same@EXAMPLE.test>", "Beta <same@example.test>", "Name Only"] },
    { ...base, branch: "stable", author_name: "Git Alias", author_email: "same@example.test" }]);
  ui.renderDashboard();
  const index = ui.state.authorIndex;
  const scope = ui.getFilterScopeAuthors();
  search(ui, "ZED");
  assert.equal(inputs(ui).length, 1);
  assert.match(inputs(ui)[0].parentElement.textContent, /Beta <same@example.test>/);
  choose(ui, key("same@example.test"));
  search(ui, "name only"); choose(ui, JSON.stringify(["unresolved", "Name Only"]));
  search(ui, "GIT ALIAS");
  assert.equal(inputs(ui).length, 1);
  assert.equal(ui.state.authorIndex, index);
  assert.equal(ui.getFilterScopeAuthors(), scope);
  choose(ui, "master", false, "branch");
  assert.deepEqual(selected(ui), [key("same@example.test")]);
  assert.match(ui.element("#author-status").textContent, /1 selected author entries removed/);
  assert.doesNotMatch(ui.element("#author-status").textContent, /now unrestricted/);
  assert.match(inputs(ui)[0].parentElement.textContent, /Beta <same@example.test>/);
});

test("inclusive sliced dates and inverted endpoints retain existing behavior", () => {
  const ui = dashboard([{ ...base, author_date: "2026-01-01T23:00:00-08:00" },
    { ...base, author_date: "2026-01-02T00:00:00Z" }]);
  ui.initializeDateInputs(); ui.renderDashboard();
  date(ui, "#end-date", "2026-01-01");
  assert.equal(ui.state.filteredCommits.length, 1);
  date(ui, "#start-date", "2026-01-02");
  assert.equal(ui.state.filters.endDate, "2026-01-02");
  assert.equal(ui.element("#end-date").value, "2026-01-02");
  assert.equal(ui.state.filteredCommits.length, 1);
  date(ui, "#end-date", "2026-01-01");
  assert.equal(ui.state.filters.startDate, "2026-01-01");
  assert.equal(ui.element("#start-date").value, "2026-01-01");
  assert.equal(ui.state.filteredCommits.length, 1);
});

test("full dataset is filtered before stable descending recent-25 sort; patch metrics stay with Git", () => {
  const matches = Array.from({ length: 35 }, (_, i) => ({ ...base, commit_id: i,
    author_date: new Date(Date.UTC(2025, 0, i + 1)).toISOString(), trailer_author: ["Older Patch <patch@x>"] }));
  const ui = dashboard([...matches, ...Array.from({ length: 70 }, () => ({ ...base }))]);
  ui.renderDashboard(); search(ui, "older patch"); choose(ui, key("patch@x"));
  assert.equal(ui.state.filteredCommits.length, 35);
  assert.deepEqual(Array.from(ui.state.filteredRecentCommits, (commit) => commit.commit_id), Array.from({ length: 25 }, (_, i) => 34 - i));
  assert.equal(ui.state.filteredAuthors.length, 1);
  assert.equal(ui.state.filteredAuthors[0].author_name, "Git Owner");
  assert.equal(ui.state.filteredAuthors[0].total_insertions, 105);
  assert.equal(ui.state.filteredAuthors[0].total_deletions, 70);
  assert.equal(ui.state.filteredAuthors[0].total_changed_files, 35);
  const ties = dashboard([3, 1, 2].map((commit_id) => ({ ...base, commit_id })));
  ties.updateDerivedState();
  assert.deepEqual(Array.from(ties.state.filteredRecentCommits, (commit) => commit.commit_id), [3, 1, 2]);
});

test("safe plain labels, stable IDs, focused checkbox retention and scope restoration", () => {
  const hostile = '<img src=x onerror="alert(1)">';
  const ui = dashboard([{ ...base, trailer_author: [hostile, "Opaque Name", "Patch Name <owner@x>"] },
    { ...base, branch: "stable", co_authored_by: ["Other Alias <owner@x>"] }]);
  ui.renderDashboard();
  const checkbox = inputs(ui).find((input) => input.value === key("owner@x"));
  const initialId = checkbox.id;
  assert.match(initialId, /^filter-control-\d+$/);
  assert.match(checkbox.parentElement.textContent, /Other Alias <owner@x>/);
  assert.equal(checkbox.parentElement.parentElement, ui.element("#author-filter"));
  assert.equal(checkbox.getAttribute("aria-describedby"), undefined);
  assert.doesNotMatch(checkbox.parentElement.textContent, /Recorded aliases and evidence|Email identity|Unresolved identity/);
  assert.doesNotMatch(ui.element("#author-filter").textContent, /Unresolved identity/);
  const hostileInput = inputs(ui).find((input) => input.value === JSON.stringify(["unresolved", hostile]));
  const unresolvedOption = hostileInput.parentElement;
  assert.equal(hostileInput.getAttribute("aria-describedby"), undefined);
  assert.doesNotMatch(unresolvedOption.textContent, /Grouped by exact recorded text/);
  assert.equal(unresolvedOption.querySelector("summary"), null);
  assert.equal(hostileInput.parentElement.children[1].textContent, hostile);
  assert.equal(hostileInput.parentElement.innerHTML, "");
  assert.equal(ui.element("#author-filter").querySelectorAll("img").length, 0);
  ui.element("#author-filter").scrollTop = 90;
  ui.element("#branch-filter").scrollTop = 12;
  choose(ui, key("owner@x"));
  assert.equal(ui.document.activeElement, checkbox);
  assert.equal(ui.document.activeElement.id, initialId);
  assert.equal(ui.element("#author-filter").scrollTop, 90);
  assert.equal(ui.element("#branch-filter").scrollTop, 12);
  search(ui, "opaque");
  assert.equal(ui.document.activeElement, ui.element("#author-search"));
  choose(ui, JSON.stringify(["unresolved", "Opaque Name"]));
  ui.state.filters.branches = new Set(["stable"]);
  ui.syncAuthorSelection(); ui.renderDashboard();
  assert.equal(ui.document.activeElement, ui.element("#author-search"));
  for (const selector of ["#start-date", "#end-date", "#metric-select"]) {
    const control = ui.element(selector); control.focus(); ui.renderDashboard();
    assert.equal(ui.document.activeElement, control);
  }
  const html = readFileSync(new URL("../site/src/index.html", import.meta.url), "utf8");
  assert.match(html, /id="author-filter" role="group" aria-label="Matching authors"/);
  assert.match(html, /id="author-selected" role="group" aria-label="Selected authors"/);
  assert.match(html, /id="author-search"[^>]+aria-controls="author-popup"[^>]+aria-expanded="false"/);
  assert.match(html, /id="author-status" role="status" aria-live="polite"/);
  assert.match(html, /Activity and change totals remain attributed to Git authors/);
  assert.doesNotMatch(html, /All visible authors|Recorded aliases and evidence|Grouped by exact recorded text/);
  assert.match(html, /Git author activity chart/);
  assert.match(html, /Git-author activity export \(not a person directory\)/);
});
