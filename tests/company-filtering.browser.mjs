// Optional Chromium integration test; see docs/author-company-affiliations.md.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname, sep } from "node:path";

assert.ok(process.env.SITE_DIST_DIR, "Set SITE_DIST_DIR to a dedicated temporary build");
const root = resolve(process.env.SITE_DIST_DIR);
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };
const server = createServer(async (request, response) => {
  const path = resolve(root, `.${new URL(request.url, "http://localhost").pathname.replace(/\/$/, "/index.html")}`);
  if (!path.startsWith(`${root}${sep}`)) { response.writeHead(403).end(); return; }
  try {
    const content = await readFile(path);
    response.writeHead(200, { "Content-Type": types[extname(path)] || "application/octet-stream" }).end(content);
  } catch { response.writeHead(404).end(); }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
let browser;
try {
  browser = await chromium.launch({ headless: true,
    ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}),
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const base = { branch: "master", author_date: "2025-02-18T10:00:00Z", commit_date: "2025-02-18T11:00:00Z", author_name: "Git Owner", author_email: "owner@example.test", insertions: 1, deletions: 0, changed_files: 1 };
  const commits = [
    { ...base, commit_id: "one", summary: "First", trailer_author: ["Patch Person <patch@example.test>"] },
    { ...base, commit_id: "two", summary: "Second", trailer_author: ["Second Person <second@example.test>"], co_authored_by: ["Coauthor <co@example.test>"] },
    { ...base, commit_id: "both", summary: "Concurrent", trailer_author: ["Third Person <third@example.test>", "Fourth Person <fourth@example.test>"] },
    { ...base, commit_id: "one", branch: "stable", summary: "Backpatch without evidence" },
    { ...base, commit_id: "unknown", summary: "Unknown" },
  ];
  const commitText = JSON.stringify(commits);
  const snapshot = {
    schema_version: 3, attribution_source: "trailer_author_or_git_author",
    provenance: { timestamp_basis: "committer", input_sha256: { commit_snapshot_sha256: createHash("sha256").update(commitText).digest("hex") } },
    coverage: { total_commits: 5, matched_commits: 3, researched_people: 3 },
    companies: [
      { company_id: "edb", name: "EnterpriseDB", aliases: ["EDB"] },
      { company_id: "other", name: "Another Company", aliases: ["Example"] },
      ...Array.from({ length: 10 }, (_, i) => ({ company_id: `extra${i}`, name: `Fixture Company ${i}`, aliases: [] })),
      { company_id: "hostile", name: '<img src=x onerror="alert(1)">', aliases: ["hostile"] },
    ],
    matches: [
      { branch: "master", commit_id: "one", author_source: "trailer_author", companies: [{ company_id: "edb", status: "estimated" }] },
      { branch: "master", commit_id: "two", author_source: "trailer_author", companies: [{ company_id: "other", status: "supported" }] },
      { branch: "master", commit_id: "both", author_source: "trailer_author", companies: [{ company_id: "edb", status: "supported" }, { company_id: "other", status: "estimated" }] },
    ],
  };
  let mode = "valid";
  await page.route("**/data/branches.json", (route) => route.fulfill({ json: { branches: ["master", "stable"], root_branch: "master" } }));
  await page.route("**/data/commits.json", (route) => route.fulfill({ body: commitText, contentType: "application/json" }));
  await page.route("**/data/company_affiliations.json", (route) => {
    if (mode === "missing") return route.fulfill({ status: 404 });
    if (mode === "invalid") return route.fulfill({ body: "invalid", contentType: "application/json" });
    const value = structuredClone(snapshot);
    if (mode === "stale") value.provenance.input_sha256.commit_snapshot_sha256 = "wrong";
    if (mode === "legacy") { value.schema_version = 1; delete value.attribution_source; }
    if (mode === "wrong-role") value.attribution_source = "git_author";
    if (mode === "empty") { value.matches = []; value.companies = []; value.coverage.matched_commits = 0; }
    return route.fulfill({ json: value });
  });
  await page.route("**/favicon.ico", (route) => route.fulfill({ status: 204 }));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const search = page.getByRole("searchbox", { name: "Search companies by name or alias" });
  const popup = page.locator("#company-popup");
  const choice = (id) => page.locator(`#company-filter input[value="${id}"]`);
  const expectCount = async (n) => assert.match(await page.locator("#selection-summary").textContent(), new RegExp(`^${n} commits`));
  const ready = async () => { await page.waitForFunction(() => document.querySelector("#selection-summary")?.textContent.includes("commits")); };
  const downloadRows = async (expectedCount) => {
    const pending = page.waitForEvent("download");
    await page.getByRole("button", { name: /^Download JSON/ }).click();
    const download = await pending;
    assert.equal(download.suggestedFilename(), "matching-commits.json");
    const stream = await download.createReadStream();
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    const rows = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    assert.equal(rows.length, expectedCount);
    const columns = await page.locator(".recent-commits-table th").allTextContents();
    for (const row of rows) assert.deepEqual(Object.keys(row), columns);
    const visible = await page.locator("#recent-commits-body tr").evaluateAll((rows) => rows.map((row) =>
      Array.from(row.querySelectorAll("td"), (cell) => cell.innerText.trim())));
    assert.deepEqual(rows.slice(0, 25).map((row) => columns.map((key) => row[key].trim())), visible);
    return rows;
  };
  await page.goto(url); await ready();
  await downloadRows(5);
  if (process.env.BROWSER_ARTIFACT_DIR) {
    await page.locator("section").filter({ has: page.getByRole("heading", { name: "Latest matching commits", exact: true }) })
      .screenshot({ path: `${process.env.BROWSER_ARTIFACT_DIR}/download-1440.png` });
  }
  assert.equal(await search.isEnabled(), true);
  assert.match(await page.locator("#company-help").textContent(), /Git author when that tag is absent/);
  assert.match(await page.locator("#company-method").textContent(), /Git author is the fallback/);
  assert.equal(await page.getByRole("columnheader", { name: "Patch author companies", exact: true }).count(), 1);
  await search.click();
  assert.equal(await page.locator("#company-filter input").count(), 8);
  await search.fill("edb");
  await search.press("ArrowDown");
  assert.equal(await choice("edb").evaluate((e) => e === document.activeElement), true);
  await choice("edb").press("Space");
  assert.equal(await choice("edb").evaluate((e) => e === document.activeElement), true);
  assert.equal(await choice("edb").isChecked(), true);
  await expectCount(2);
  await choice("edb").press("Tab");
  assert.equal(await page.locator("#company-done").evaluate((e) => e === document.activeElement), true);
  await page.locator("#company-done").press("Escape");
  assert.equal(await popup.isHidden(), true);
  assert.equal(await search.evaluate((e) => e === document.activeElement), true);
  await search.fill("example"); await choice("other").check(); await expectCount(3);
  assert.equal(await page.locator("#company-selected .author-chip").count(), 2);
  await search.fill("nothing matches");
  assert.equal(await page.locator("#company-filter input").count(), 0);
  await expectCount(3);
  await page.getByRole("button", { name: "Clear company search" }).click();
  assert.equal(await search.inputValue(), "");
  assert.equal(await page.locator("#company-selected .author-chip").count(), 2);
  await page.locator("#company-done").click();
  assert.equal(await popup.isHidden(), true);
  await page.locator("#company-estimates").uncheck(); await expectCount(2);
  assert.doesNotMatch(await page.locator("#recent-commits-body").textContent(), /estimated/);
  assert.ok((await downloadRows(2)).every((row) => !row["Patch author companies"].includes("estimated")));
  await page.locator("#company-estimates").check();
  const authorSearch = page.locator("#author-search");
  await authorSearch.fill("patch person");
  await page.getByRole("checkbox", { name: "Patch Person <patch@example.test>", exact: true }).check();
  await expectCount(1);
  assert.match(await page.locator("#recent-commits-body").textContent(), /EnterpriseDB \(estimated\)/);
  await page.locator("#author-done").click();
  assert.equal((await downloadRows(1))[0].Summary, "First");
  await page.locator("#author-clear-selection").click();
  await page.getByRole("button", { name: "Stable only", exact: true }).click(); await expectCount(0);
  assert.equal(await page.locator("#company-selected .author-chip").count(), 2);
  await page.getByRole("button", { name: "All branches", exact: true }).click(); await expectCount(3);
  await page.getByRole("button", { name: "Remove company EnterpriseDB", exact: true }).click(); await expectCount(2);
  await page.locator("#company-clear-selection").click(); await expectCount(5);
  await search.fill("hostile");
  assert.equal(await page.locator("#company-filter img").count(), 0);
  assert.match(await page.locator("#company-filter").textContent(), /<img/);
  await search.fill("edb"); await search.press("Enter"); await expectCount(2);
  await search.press("Escape"); assert.equal(await popup.isHidden(), true);
  await search.click(); await page.locator("#end-date").click(); assert.equal(await popup.isHidden(), true);
  await search.click();
  const a11y = await page.locator("#company-picker").ariaSnapshot();
  assert.match(a11y, /Search companies by name or alias/);
  assert.match(a11y, /checkbox "EnterpriseDB" \[checked\]/);
  const layouts = [];
  for (const width of [1440, 1000, 720, 375, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    await search.click();
    const geometry = await page.evaluate(() => ({
      width: window.innerWidth, scroll: document.documentElement.scrollWidth,
      popup: { left: document.querySelector("#company-popup").getBoundingClientRect().left,
        right: document.querySelector("#company-popup").getBoundingClientRect().right },
    }));
    assert.ok(geometry.scroll <= geometry.width + 1, JSON.stringify(geometry));
    assert.ok(geometry.popup.left >= 0 && geometry.popup.right <= geometry.width, JSON.stringify(geometry));
    layouts.push(geometry);
    if (process.env.BROWSER_ARTIFACT_DIR && [1440, 320].includes(width)) {
      await page.locator(".filter-grid").screenshot({ path: `${process.env.BROWSER_ARTIFACT_DIR}/companies-${width}.png` });
      if (width === 320) await page.locator("section").filter({ has: page.getByRole("heading", { name: "Latest matching commits", exact: true }) })
        .screenshot({ path: `${process.env.BROWSER_ARTIFACT_DIR}/download-320.png` });
    }
  }
  for (const failure of ["missing", "stale", "legacy", "wrong-role", "invalid", "empty"]) {
    mode = failure; await page.goto(url); await ready(); await expectCount(5);
    assert.equal(await search.isEnabled(), failure === "empty");
    if (failure === "empty") {
      await search.click(); assert.match(await page.locator("#company-filter").textContent(), /No usable company affiliations/);
    } else assert.match(await page.locator("#company-coverage").textContent(), /unavailable/);
    if (failure === "missing") assert.ok((await downloadRows(5)).every((row) => row["Patch author companies"] === "Unavailable"));
  }
  await page.unroute("**/data/branches.json");
  await page.unroute("**/data/commits.json");
  await page.unroute("**/data/company_affiliations.json");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(url); await ready();
  assert.equal(await search.isEnabled(), true);
  const real = JSON.parse(await readFile(resolve(root, "data/company_affiliations.json"), "utf8"));
  assert.equal(real.schema_version, 3);
  assert.equal(real.attribution_source, "trailer_author_or_git_author");
  await expectCount(real.coverage.total_commits.toLocaleString("en-US"));
  const allDownloaded = await downloadRows(real.coverage.total_commits);
  assert.ok(allDownloaded.length > 25);
  await search.fill("edb");
  const edb = page.getByRole("checkbox", { name: "EnterpriseDB", exact: true });
  await edb.check();
  const matches = real.matches.filter((r) => r.companies.some((c) => c.company_id === "company:enterprisedb"));
  await expectCount(matches.length.toLocaleString("en-US"));
  const filteredDownloaded = await downloadRows(matches.length);
  assert.ok(filteredDownloaded.every((row) => row["Patch author companies"].includes("EnterpriseDB")));
  // Exercise the requested real companies and their aliases, not just fixtures.
  assert.equal(real.companies.length, 6);
  for (const [query, id] of [
    ["Microsoft", "microsoft"], ["Amazon", "amazon"], ["AWS", "amazon"],
    ["Databricks", "databricks"], ["Snowflake", "snowflake"], ["Snowflakes", "snowflake"],
    ["EnterpriseDB", "enterprisedb"], ["EDB", "enterprisedb"], ["Percona", "percona"],
  ]) {
    await page.locator("#company-clear-selection").click();
    await search.fill(query);
    const idValue = `company:${id}`;
    const option = page.locator("#company-filter input");
    assert.equal(await option.count(), 1);
    assert.equal(await option.inputValue(), idValue);
    await option.check();
    const expected = real.matches.filter((r) => r.companies.some((c) => c.company_id === idValue)).length;
    // A catalog option can legitimately have no eligible trailer-author evidence.
    assert.match(await option.locator("..").textContent(), new RegExp(`${expected.toLocaleString("en-US")} commits?`));
    await expectCount(expected.toLocaleString("en-US"));
  }
  await page.locator("#company-done").click();
  await page.locator("#company-estimates").uncheck();
  await expectCount(0);
  assert.equal(await page.getByRole("button", { name: /^Download JSON/ }).isDisabled(), true);
  assert.equal(await page.locator("#company-selected .author-chip").count(), 1);
  await page.locator("#company-clear-selection").click();
  await expectCount(real.coverage.total_commits.toLocaleString("en-US"));
  assert.match(await page.locator("#company-method").textContent(), /Git committer timestamp/);
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ result: "passed", layouts, fullExportCoverage: real.coverage, companyCount: real.companies.length,
    downloadedRows: allDownloaded.length, filteredDownloadedRows: filteredDownloaded.length }, null, 2));
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
}
