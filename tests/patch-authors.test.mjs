import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { patchAuthors, renderPatchAuthors } from "../site/src/patch-authors.mjs";

test("Author then Co-authored-by, stable exact deduplication, full names preserved", () => {
  const commit = {
    trailer_author: [" Second <second@example.test> ", "First", "Second <second@example.test>"],
    co_authored_by: ["First", "Co One", "first"],
  };
  assert.deepEqual(patchAuthors(commit), ["Second <second@example.test>", "First", "Co One", "first"]);
  assert.equal(renderPatchAuthors({ trailer_author: ["Name <email>"] }),
    '<ul class="patch-authors"><li>Name &lt;email&gt;</li></ul>');
});

test("missing, null, malformed and blank values show an explicit empty marker without Git fallback", () => {
  for (const values of [undefined, null, "Name", {}, 7, [], ["", " ", "\t\r\n"], [null, {}, 7]]) {
    assert.equal(renderPatchAuthors({ author_name: "Git Author", trailer_author: values, co_authored_by: values }), "—");
    assert.deepEqual(patchAuthors({ trailer_author: values, co_authored_by: values }), []);
  }
  assert.equal(renderPatchAuthors({}), "—");
  assert.deepEqual(patchAuthors({ trailer_author: null, co_authored_by: ["Co One"] }), ["Co One"]);
});

const hostile = '<script>alert("x" & \'y\')</script>';
test("hostile values are escaped before any markup is produced", () => {
  const html = renderPatchAuthors({ co_authored_by: [hostile] });
  assert.equal(html, '<ul class="patch-authors"><li>&lt;script&gt;alert(&quot;x&quot; &amp; &#39;y&#39;)&lt;/script&gt;</li></ul>');
  assert.ok(!html.includes("<script>"));
});

// A minimal DOM sink exercises the actual dashboard filter, sort, row and
// empty-state functions without a browser dependency or duplicating them.
function dashboard() {
  class Element {
    children = [];
    innerHTML = "";
    value = "";
    get firstChild() { return this.children[0]; }
    appendChild(child) { this.children.push(child); }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  }
  const elements = new Map();
  const context = vm.createContext({
    renderPatchAuthors,
    document: {
      querySelector(selector) {
        if (!elements.has(selector)) elements.set(selector, new Element());
        return elements.get(selector);
      },
      querySelectorAll: () => [],
      createElement: () => new Element(),
    },
    // Leave startup pending; tests supply data and exercise rendering below.
    fetch: () => new Promise(() => {}),
  });
  const source = readFileSync(new URL("../site/src/app.js", import.meta.url), "utf8");
  assert.match(source, /^import \{ renderPatchAuthors \} from "\.\/patch-authors\.mjs";/);
  vm.runInContext(source.replace(/^import[^\n]+\n/, "") +
    "\nglobalThis.dashboard = { state, updateDerivedState, renderRecentCommits };", context);
  const api = context.dashboard;
  api.state.data = { branches: { branches: ["master", "stable"] }, commits: [] };
  api.state.filters.branches = new Set(["master", "stable"]);
  return {
    state: api.state,
    render() {
      api.updateDerivedState();
      api.renderRecentCommits();
      return elements.get("#recent-commits-body").children.map((row) => row.innerHTML);
    },
  };
}

const commit = {
  author_date: "2026-01-01T00:00:00Z", branch: "master", author_name: "Git Author",
  author_email: "git@example.test", summary: "Summary", trailer_author: ["Patch One", "Patch Two"],
};

test("actual recent rows, desktop headers and mobile labels have five columns in order", () => {
  const ui = dashboard();
  ui.state.data.commits = [{ ...commit, co_authored_by: [hostile] }];
  const [row] = ui.render();
  const cells = [...row.matchAll(/<td data-label="([^"]+)">([\s\S]*?)<\/td>/g)];
  const labels = ["When", "Branch", "Git author", "Patch authors", "Summary"];
  assert.deepEqual(cells.map((cell) => cell[1]), labels);
  assert.equal(cells[2][2], "Git Author");
  assert.match(cells[3][2], /Patch One<\/li><li>Patch Two/);
  assert.ok(cells[3][2].includes("&lt;script&gt;"));
  assert.ok(!row.includes("<script>"));
  const html = readFileSync(new URL("../site/src/index.html", import.meta.url), "utf8");
  const table = html.slice(html.indexOf('<table class="recent-commits-table">'));
  assert.deepEqual([...table.matchAll(/<th>(.*?)<\/th>/g)].map((match) => match[1]), labels);
  assert.match(html, /latest 25 matching commits/);
  const css = readFileSync(new URL("../site/src/styles.css", import.meta.url), "utf8");
  assert.match(css, /overflow-wrap: anywhere/);
  assert.match(css, /content: attr\(data-label\)/);
  assert.match(css, /\.empty-state::before\s*\{\s*content: none/);
});

test("empty patch authors and no-results rows render correctly", () => {
  const ui = dashboard();
  for (const fields of [{ trailer_author: null }, { trailer_author: [], co_authored_by: [] }]) {
    ui.state.data.commits = [{ ...commit, ...fields }];
    assert.match(ui.render()[0], /<td data-label="Patch authors">—<\/td>/);
  }
  ui.state.filters.authors = new Set(["absent@example.test"]);
  assert.deepEqual(ui.render(), ['<td colspan="5" class="empty-state">No commits match the current filters.</td>']);
});

test("latest 25 are selected after branch, Git-author and date filtering, on every change", () => {
  const ui = dashboard();
  // Ascending input catches missing sorting. More than 25 per branch catches
  // a cap applied before filtering, including after switching the selection.
  ui.state.data.commits = Array.from({ length: 120 }, (_, i) => ({
    ...commit, commit_id: i, summary: `Commit ${i}`,
    author_date: new Date(Date.UTC(2026, 0, i + 1)).toISOString(),
    branch: i % 2 ? "master" : "stable",
    author_email: i % 3 ? "git@example.test" : "other@example.test",
  }));
  function check(expected) {
    const rows = ui.render();
    assert.equal(rows.length, expected.length);
    assert.deepEqual(rows.map((row) => Number(row.match(/data-label="Summary">Commit (\d+)/)[1])), expected);
  }
  check(Array.from({ length: 25 }, (_, i) => 119 - i));
  ui.state.filters.branches = new Set(["stable"]);
  check(Array.from({ length: 25 }, (_, i) => 118 - i * 2));
  ui.state.filters.authors = new Set(["other@example.test"]);
  ui.state.filters.startDate = "2026-01-13";
  ui.state.filters.endDate = "2026-04-13";
  check(Array.from({ length: 16 }, (_, i) => 102 - i * 6));
  ui.state.filters.branches = new Set(["master"]);
  check(Array.from({ length: 15 }, (_, i) => 99 - i * 6));
});
