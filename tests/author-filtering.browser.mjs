// Optional real Chromium smoke test. See tests/author-filtering-verification.md.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname, sep } from "node:path";
import { performance } from "node:perf_hooks";

assert.ok(process.env.SITE_DIST_DIR, "Set SITE_DIST_DIR to a dedicated temporary build");
const root = resolve(process.env.SITE_DIST_DIR);
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };
const server = createServer(async (request, response) => {
  const path = resolve(root, `.${new URL(request.url, "http://localhost").pathname.replace(/\/$/, "/index.html")}`);
  if (!path.startsWith(`${root}${sep}`)) { response.writeHead(403).end(); return; }
  try {
    response.writeHead(200, { "Content-Type": types[extname(path)] || "application/octet-stream" });
    response.end(await readFile(path));
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
  page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  const base = { branch: "master", author_date: "2026-01-01T00:00:00Z", author_name: "Git Owner", author_email: "owner@example.test", insertions: 3, deletions: 2, changed_files: 1 };
  const commits = Array.from({ length: 85 }, (_, i) => ({ ...base, summary: `Commit ${i}`, commit_id: i,
    author_date: new Date(Date.UTC(2025, 0, i + 1)).toISOString(),
    trailer_author: [`Person ${String(i).padStart(2, "0")} <person${String(i).padStart(2, "0")}@example.test>`],
  }));
  commits.push(...Array.from({ length: 35 }, (_, i) => ({ ...base, summary: `Older ${i}`, commit_id: `old${i}`,
    author_date: new Date(Date.UTC(2024, 0, i + 1)).toISOString(),
    co_authored_by: ["Older Patch <older@example.test>"],
  })), { ...base, summary: "Hostile", trailer_author: ['<img src=x onerror="alert(1)">', "Opaque Name", `${"Long".repeat(100)} <long@example.test>`, "Patch Owner <owner@example.test>"] },
  { ...base, branch: "stable", summary: "Stable Git" });
  await page.route("**/data/branches.json", (route) => route.fulfill({ json: { branches: ["master", "stable"], root_branch: "master" } }));
  await page.route("**/data/commits.json", (route) => route.fulfill({ json: commits }));
  // Avoid an unrelated missing favicon error in console checks.
  await page.route("**/favicon.ico", (route) => route.fulfill({ status: 204 }));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const modules = new Set();
  page.on("response", (response) => {
    if (/\/(app\.js|author-identities\.mjs|patch-authors\.mjs)$/.test(response.url()) && response.ok()) modules.add(response.url().split("/").pop());
  });
  await page.goto(url);
  const search = page.getByRole("searchbox", { name: "Search authors by name or email" });
  const popup = page.locator("#author-popup");
  await page.locator("#author-status").waitFor();
  await search.click();
  await popup.waitFor();
  assert.equal(await page.locator('#author-filter input').count(), 8);
  assert.equal(await page.locator("#author-suggestion-title").textContent(), "Suggested authors");
  assert.match(await page.locator("#author-suggestion-count").textContent(), /^8 of /);
  assert.equal(await page.locator("#author-selected").textContent(), "All authors");
  assert.deepEqual([...modules].sort(), ["app.js", "author-identities.mjs", "patch-authors.mjs"]);

  await search.fill("person00@");
  const selected = page.getByRole("checkbox", { name: "Person 00 <person00@example.test>", exact: true });
  await search.press("ArrowDown");
  assert.equal(await selected.evaluate((element) => element === document.activeElement), true);
  await selected.press("Space");
  assert.equal(await selected.isChecked(), true);
  assert.equal(await selected.evaluate((element) => element === document.activeElement), true);
  assert.equal(await popup.isVisible(), true);
  assert.equal(await page.getByRole("button", { name: "Remove Person 00 <person00@example.test>" }).count(), 1);
  await search.fill("person01@");
  assert.equal(await page.getByRole("button", { name: "Remove Person 00 <person00@example.test>" }).count(), 1);
  assert.equal(await selected.isVisible(), false);
  await search.fill("person00@");
  await search.press("ArrowDown");
  await selected.press("Tab");
  assert.equal(await page.getByRole("button", { name: "Done" }).evaluate((element) => element === document.activeElement), true);
  await page.getByRole("button", { name: "Done" }).press("Escape");
  assert.equal(await popup.isHidden(), true);
  assert.equal(await search.evaluate((element) => element === document.activeElement), true);
  await search.fill("");
  assert.equal(await popup.isVisible(), true);
  await search.press("Tab");
  assert.equal(await page.locator('#author-filter input').first().evaluate((element) => element === document.activeElement), true);
  assert.equal(await popup.isVisible(), true);
  assert.match(await page.locator("#author-status").textContent(), /1 author selected.*1 matching commit/);
  await page.locator("#start-date").fill("2025-01-01");
  await page.locator("#start-date").press("Tab");
  assert.match(await page.locator("#selection-summary").textContent(), /^1 commits/);
  await search.fill("person00@");
  assert.equal(await selected.isChecked(), true);

  await page.getByRole("button", { name: "Clear selection" }).click();
  assert.equal(await page.locator("#author-selected").textContent(), "All authors");
  await page.locator("#start-date").fill("");
  await page.locator("#start-date").press("Tab");
  await search.fill("older patch");
  await page.getByRole("checkbox", { name: "Older Patch <older@example.test>", exact: true }).check();
  assert.equal(await page.locator("#recent-commits-body tr").count(), 25);
  assert.deepEqual(await page.locator('#recent-commits-body td[data-label="Summary"]').allTextContents(), Array.from({ length: 25 }, (_, i) => `Older ${34 - i}`));
  assert.match(await page.locator("#author-activity-body").textContent(), /Git Owner/);
  assert.doesNotMatch(await page.locator("#author-activity-body").textContent(), /Older Patch/);

  await page.getByRole("button", { name: "Clear selection" }).click();
  await search.fill("opaque");
  const opaque = page.getByRole("checkbox", { name: "Opaque Name", exact: true });
  const cdp = await page.context().newCDPSession(page);
  const ax = await cdp.send("Accessibility.getFullAXTree");
  const accessibleOpaque = ax.nodes.find((node) => node.role?.value === "checkbox" && node.name?.value === "Opaque Name");
  assert.ok(accessibleOpaque);
  assert.equal(accessibleOpaque.description, undefined);
  assert.equal(await page.getByText("Unresolved identity", { exact: true }).count(), 0);
  assert.equal(await page.getByText("Recorded aliases and evidence", { exact: true }).count(), 0);
  assert.equal(await page.getByText("Grouped by exact recorded text", { exact: false }).count(), 0);
  assert.equal(await page.locator("#author-filter details").count(), 0);
  await opaque.check();
  await page.getByRole("checkbox", { name: "master", exact: true }).uncheck();
  assert.match(await page.locator("#author-status").textContent(), /Author selection is now unrestricted/);
  assert.equal(await page.locator("#author-filter").textContent(), "No authors match this search.");
  await search.fill("owner");
  assert.equal(await page.getByRole("checkbox", { name: "Patch Owner <owner@example.test>", exact: true }).count(), 1);
  assert.equal(await page.locator(".author-description").count(), 0);
  await page.getByRole("checkbox", { name: "stable", exact: true }).uncheck();
  assert.equal(await page.getByRole("checkbox", { name: "master", exact: true }).isChecked(), true);

  await search.fill("img src");
  assert.equal(await page.locator("#author-filter img").count(), 0);
  assert.match(await page.locator("#author-filter").textContent(), /<img src=x/);
  await search.fill("long@example");
  await page.locator('#author-filter input').check();
  assert.equal(await page.locator("#author-selected .author-chip").count(), 1);
  const layouts = [];
  for (const [width, zoom] of [[1440, 1], [375, 1], [320, 1], [1280, 2], [1280, 4]]) {
    // Browser zoom reduces the CSS viewport and triggers media queries. Emulate
    // that reflow, rather than CSS zoom (which leaves viewport units unchanged).
    await page.setViewportSize({ width: width / zoom, height: 1000 / zoom });
    await page.locator("#author-filter").scrollIntoViewIfNeeded();
    const dimensions = await page.evaluate(() => ({
      width: document.documentElement.clientWidth, scroll: document.documentElement.scrollWidth,
      authorWidth: document.querySelector("#author-filter").clientWidth,
      authorScroll: document.querySelector("#author-filter").scrollWidth,
      popupPosition: getComputedStyle(document.querySelector("#author-popup")).position,
      popupZ: Number(getComputedStyle(document.querySelector("#author-popup")).zIndex),
    }));
    assert.ok(dimensions.scroll <= dimensions.width + 1, JSON.stringify({ width, zoom, ...dimensions }));
    assert.ok(dimensions.authorScroll <= dimensions.authorWidth + 1, JSON.stringify(dimensions));
    assert.equal(dimensions.popupPosition, "absolute");
    assert.ok(dimensions.popupZ > 0);
    layouts.push({ width, zoom, ...dimensions });
    if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: `${process.env.SCREENSHOT_DIR}/authors-${width}-${zoom}.png` });
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByRole("button", { name: "Clear author search" }).click();
  assert.equal(await search.inputValue(), "");
  assert.equal(await page.locator("#author-selected .author-chip").count(), 1);
  await page.getByRole("button", { name: "Clear selection" }).click();
  assert.equal(await page.locator("#author-selected").textContent(), "All authors");
  assert.equal(await page.locator('#author-filter input').count(), 8);
  await search.fill("person");
  assert.equal(await page.locator('#author-filter input').count(), 8);
  await search.press("Enter");
  assert.equal(await page.locator("#author-selected .author-chip").count(), 1);
  assert.equal(await popup.isVisible(), true);
  await search.press("ArrowDown");
  const firstChoice = page.locator('#author-filter input').first();
  const secondChoice = page.locator('#author-filter input').nth(1);
  assert.equal(await firstChoice.evaluate((element) => element === document.activeElement), true);
  await firstChoice.press("ArrowDown");
  assert.equal(await secondChoice.evaluate((element) => element === document.activeElement), true);
  await secondChoice.press("ArrowUp");
  assert.equal(await firstChoice.evaluate((element) => element === document.activeElement), true);
  await firstChoice.press("Space");
  assert.equal(await firstChoice.evaluate((element) => element === document.activeElement), true);
  assert.equal(await popup.isVisible(), true);
  await firstChoice.press("ArrowDown");
  await secondChoice.press("Space");
  assert.equal(await secondChoice.evaluate((element) => element === document.activeElement), true);
  assert.equal(await page.locator("#author-selected .author-chip").count(), 1);
  await secondChoice.press("Escape");
  assert.equal(await popup.isHidden(), true);
  assert.equal(await search.evaluate((element) => element === document.activeElement), true);
  await search.click();
  await page.getByRole("button", { name: "Done" }).click();
  assert.equal(await popup.isHidden(), true);
  assert.equal(await search.evaluate((element) => element === document.activeElement), true);
  await search.click();
  await page.locator("#end-date").click();
  assert.equal(await popup.isHidden(), true);
  await page.getByRole("button", { name: "Clear selection" }).click();
  await search.fill("");
  await page.locator("#end-date").fill("2023-01-01");
  await page.locator("#end-date").press("Tab");
  assert.equal(await page.locator("#author-filter").textContent(), "No authors in this branch/date scope.");
  assert.equal(await page.locator('#recent-commits-body td[colspan="5"]').count(), 1);

  // Use the real full export for startup and search timings, without fixture routing.
  await page.unroute("**/data/branches.json");
  await page.unroute("**/data/commits.json");
  const start = performance.now();
  await page.goto(url);
  await page.locator("#author-status").waitFor({ timeout: 60000 });
  const loadMs = performance.now() - start;
  const searchStart = performance.now();
  await search.fill("tom lane");
  await page.locator('#author-filter input').first().waitFor();
  const searchMs = performance.now() - searchStart;
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ result: "passed", modules: [...modules], layouts, fullDatasetLoadMs: loadMs, fullDatasetSearchMs: searchMs }, null, 2));
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
}
