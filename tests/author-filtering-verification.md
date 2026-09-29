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
- Native Tab/Space checkbox operation, checkbox focus retention and filter
  scroll restoration.
- Accessible group/checkbox names and Chromium accessibility-tree descriptions
  for unresolved entries.
- Search-hidden and capped selections, inclusive scope changes, pruning,
  unrestricted restoration, root fallback, All visible and Clear.
- An older patch-only match, latest-25 order, unchanged Git activity attribution,
  five-column empty results and hostile strings rendered as text.
- Global patch-priority labels with Git-only scoped roles.
- Desktop (1440 px), narrow (375/320 px), and effective 200%/400% zoom reflow
  (640/320 CSS px from a 1280 px viewport), with no page or selector horizontal
  overflow, including a 400-character name.

## Implementation run (2026-09-28)

All 23 cases in the three focused Node suites, syntax checks and cache/export
regressions passed.
Chromium passed the smoke test above; desktop and 320 px screenshots were also
visually inspected. The connected-browser integration had no browser available,
so verification used the locally installed Chromium through Playwright.

The existing full dataset contained 71,200 rows, including 11,158 with patch
values. It produced 1,864 selector identities, of which 1,248 were unresolved
exact-text groups. One local Node measurement took approximately 327 ms to build
the index and 110 ms to summarize all rows; 100 cached metadata searches averaged
0.38 ms each. The final local Chromium run took approximately 4.43 seconds to load and
render the full dashboard and 187 ms for a search including browser automation
round trips. These are observations on this machine, not performance guarantees.
The index is built once; search reuses the cached branch/date summary.

Remaining manual checks: use an actual screen reader to assess spoken checkbox
descriptions and live-region announcements, and verify native browser-menu zoom.
The automated accessibility-tree and effective-viewport checks cover the
underlying semantics and reflow but do not substitute for those manual checks.
Quoted email locals, comments, address lists, domain literals, non-ASCII
mailboxes and other unsupported forms intentionally remain unresolved text.
