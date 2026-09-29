# Combined author filtering verification

## Automated checks

```sh
node --test tests/author-identities.test.mjs tests/author-filtering.test.mjs tests/patch-authors.test.mjs
node --check site/src/app.js
node --check site/src/author-identities.mjs
./scripts/test-commits-cache.sh
git diff --check
```

The focused suites exercise the real imported identity helpers and dashboard
functions. The shared VM harness accepts only the two known import declarations
and rejects unexpected imports. Its small DOM sink does not establish native
keyboard behavior, layout or screen-reader behavior.

The cache suite creates a disposable PostgreSQL cluster and needs permission to
start its server. No exported data, parser expectations, SQL schema, cache
migration or Grafana schema was changed.

## Optional real-browser smoke test

Use a temporary build because `build-site.sh` deletes its output directory. The
example reads the existing full export without modifying it. Use `site/data`
instead if that is where the local full export resides.

```sh
verification_dir=$(mktemp -d /tmp/apotelesma-author-verification.XXXXXX)
SITE_DATA_DIR="$PWD/site/dist/data" \
SITE_DIST_DIR="$verification_dir/site" ./scripts/build-site.sh

SITE_DIST_DIR="$verification_dir/site" \
CHROMIUM_PATH=/path/to/chrome \
SCREENSHOT_DIR="$verification_dir" \
node tests/author-filtering.browser.mjs
```

This optional script needs an installed `playwright` package and Chromium.
`PLAYWRIGHT_MODULE` may point to an existing absolute `playwright/index.mjs`
instead of installing a repository dependency. The script serves the build on
an ephemeral loopback port, uses an isolated browser context, supplies fixture
responses for interaction cases, then loads the full exported dataset. It
closes its browser and server on completion. The full-data timing check searches
for Tom Lane in the PostgreSQL export.

Coverage includes:

- Both `.mjs` modules and `app.js` served and loaded without console errors.
- The eight-result cap, suggested-author ordering, pinned removable chips,
  distinct search/selection clearing, and selection persistence across searches.
- Native Tab/Space operation; Enter selection; ArrowUp/ArrowDown navigation;
  Escape/Done closure; popup focus retention; and outside-focus closure.
- Accessible search, selected group and checkbox names, generated control IDs,
  expanded state, and concise live status without selector metadata descriptions.
- Search-hidden selections, inclusive scope changes, pruning, unrestricted
  restoration and root fallback.
- An older patch-only match, latest-25 order, unchanged Git activity attribution,
  six-column empty results (including company affiliations) and hostile strings rendered as text.
- Global patch-priority labels with Git-only scoped roles.
- Desktop (1440 px), narrow (375/320 px), and effective 200%/400% zoom reflow
  (640/320 CSS px from a 1280 px viewport), with a bounded, layered popup and no
  page or selector horizontal overflow, including a 400-character name.

## Selector implementation run (2026-09-29)

All 23 cases in the three focused Node suites and both JavaScript syntax checks
passed. The standalone Chromium smoke test passed against the fixture and the
71,200-row full export using local Chrome through Playwright. The five tested
viewport/zoom combinations had equal page client and scroll widths; the popup
remained absolutely positioned at `z-index: 20`. The final run took about 5.97
seconds to load the full dashboard and 173 ms for the automated full-data search.
Desktop and 320 px screenshots were visually inspected. These timings are local
observations, not performance guarantees.

## Previous implementation run (2026-09-28)

All 23 cases in the three focused Node suites, syntax checks and cache/export
regressions passed.
Chromium passed the smoke test above; desktop and 320 px screenshots were also
visually inspected. The connected-browser integration had no browser available,
so verification used the locally installed Chromium through Playwright.

The previous selector's full-data run used 71,200 rows, including 11,158 with patch
values. It produced 1,864 selector identities, of which 1,248 were unresolved
exact-text groups. One local Node measurement took approximately 327 ms to build
the index and 110 ms to summarize all rows; 100 cached metadata searches averaged
0.38 ms each. Its final local Chromium run took approximately 4.43 seconds to
load and render the full dashboard and 187 ms for a search including browser
automation round trips. These historical observations are not performance
guarantees. The index is built once; search reuses the cached branch/date summary.

Remaining manual checks: use an actual screen reader to assess spoken checkbox
labels and live-region announcements, and verify native browser-menu zoom.
The automated accessibility-tree and effective-viewport checks cover the
underlying semantics and reflow but do not substitute for those manual checks.
Quoted email locals, comments, address lists, domain literals, non-ASCII
mailboxes and other unsupported forms intentionally remain unresolved text.
