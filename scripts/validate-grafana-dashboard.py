#!/usr/bin/env python3

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DASHBOARD_PATH = ROOT / "grafana" / "apotelesma-starter-dashboard.json"
DATA_PATH = ROOT / "site" / "data" / "grafana.json"
EXPECTED_TITLES = {
    "Daily Commit Count By Branch",
    "Daily Insertions By Branch",
    "Branch Summary",
    "Top Authors",
    "Recent Commits",
}


def main() -> int:
    dashboard = json.loads(DASHBOARD_PATH.read_text())
    data = json.loads(DATA_PATH.read_text())
    errors: list[str] = []

    panel_titles = {panel.get("title") for panel in dashboard.get("panels", [])}
    missing_titles = sorted(EXPECTED_TITLES - panel_titles)
    if missing_titles:
        errors.append(f"missing expected panels: {', '.join(missing_titles)}")

    for panel in dashboard.get("panels", []):
        title = panel.get("title", "<untitled>")
        datasource = panel.get("datasource", {})
        if datasource.get("type") != "yesoreyeram-infinity-datasource":
            errors.append(f"{title}: unexpected datasource type {datasource.get('type')!r}")

        targets = panel.get("targets", [])
        if len(targets) != 1:
            errors.append(f"{title}: expected exactly one target, found {len(targets)}")
            continue

        target = targets[0]
        root_selector = target.get("root_selector")
        rows = data.get(root_selector)
        if not isinstance(rows, list):
            errors.append(f"{title}: root selector {root_selector!r} does not resolve to a list")
            continue
        if not rows:
            errors.append(f"{title}: root selector {root_selector!r} is empty")
            continue

        selectors = [column.get("selector") for column in target.get("columns", [])]
        missing_columns = sorted(
            selector
            for selector in selectors
            if selector and all(selector not in row for row in rows)
        )
        if missing_columns:
            errors.append(f"{title}: missing columns in {root_selector}: {', '.join(missing_columns)}")
            continue

        empty_columns = sorted(
            selector
            for selector in selectors
            if selector
            and sum(1 for row in rows if row.get(selector) not in (None, "", [], {})) == 0
        )
        if empty_columns:
            errors.append(f"{title}: columns present but empty: {', '.join(empty_columns)}")
            continue

        print(f"{title}")
        print(f"  root_selector: {root_selector}")
        print(f"  rows: {len(rows)}")
        for selector in selectors:
            non_empty = sum(1 for row in rows if row.get(selector) not in (None, "", [], {}))
            print(f"  {selector}: non-empty rows = {non_empty}")

    if errors:
        print("\nValidation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("\nValidation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
