#!/usr/bin/env python3

import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SITE_DIST_DIR = ROOT / "site" / "dist"
GRAFANA_JSON_PATH = SITE_DIST_DIR / "data" / "grafana.json"
DASHBOARD_PATH = ROOT / "grafana" / "apotelesma-starter-dashboard.json"
INFINITY_PLUGIN_ID = "yesoreyeram-infinity-datasource"


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got {value!r}") from exc


def basic_auth_headers(user: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {
        "Authorization": f"Basic {token}",
        "Content-Type": "application/json",
    }


def request_json(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    payload: object | None = None,
    ok_statuses: tuple[int, ...] = (200,),
    timeout: int = 10,
) -> object:
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()

    request = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status not in ok_statuses:
                raise SystemExit(f"{method} {url} returned unexpected status {response.status}")
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise SystemExit(f"{method} {url} failed with HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"{method} {url} failed: {exc.reason}") from exc
    except OSError as exc:
        raise SystemExit(f"{method} {url} failed: {exc}") from exc


def wait_for_json(
    description: str,
    method: str,
    url: str,
    headers: dict[str, str] | None,
    payload: object | None,
    predicate,
    timeout_seconds: int,
) -> object:
    deadline = time.time() + timeout_seconds
    last_error: str | None = None

    while time.time() < deadline:
        try:
            response = request_json(method, url, headers=headers, payload=payload)
            if predicate(response):
                return response
            last_error = f"{description} returned an unexpected payload"
        except SystemExit as exc:
            last_error = str(exc)
        time.sleep(2)

    if last_error:
        raise SystemExit(f"Timed out waiting for {description}: {last_error}")
    raise SystemExit(f"Timed out waiting for {description}")


def require_command(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"Required command not found: {name}")
    return path


def run_command(command: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True)
    if check and result.returncode != 0:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        details = stderr or stdout or f"exit code {result.returncode}"
        raise SystemExit(f"{' '.join(command)} failed: {details}")
    return result


def start_site_server(site_port: int) -> subprocess.Popen[str]:
    if not GRAFANA_JSON_PATH.is_file():
        raise SystemExit(
            f"Missing {GRAFANA_JSON_PATH}. Run scripts/build-site.sh first so site/dist/data/grafana.json exists."
        )

    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "http.server",
            str(site_port),
            "--bind",
            "0.0.0.0",
            "--directory",
            str(SITE_DIST_DIR),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    try:
        wait_for_json(
            description="local static site server",
            method="GET",
            url=f"http://127.0.0.1:{site_port}/data/grafana.json",
            headers=None,
            payload=None,
            predicate=lambda body: isinstance(body, dict) and "recent_commits" in body,
            timeout_seconds=20,
        )
    except BaseException:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        raise

    return process


def start_grafana_container(
    docker: str,
    container_name: str,
    grafana_port: int,
    grafana_image: str,
    admin_user: str,
    admin_password: str,
) -> str:
    run_command([docker, "rm", "-f", container_name], check=False)

    result = run_command(
        [
            docker,
            "run",
            "-d",
            "--name",
            container_name,
            "-p",
            f"{grafana_port}:3000",
            "--add-host",
            "host.docker.internal:host-gateway",
            "-e",
            f"GF_SECURITY_ADMIN_USER={admin_user}",
            "-e",
            f"GF_SECURITY_ADMIN_PASSWORD={admin_password}",
            "-e",
            f"GF_PLUGINS_PREINSTALL_SYNC={INFINITY_PLUGIN_ID}",
            grafana_image,
        ]
    )
    return result.stdout.strip()


def stop_grafana_container(docker: str, container_name: str) -> None:
    run_command([docker, "rm", "-f", container_name], check=False)


def grafana_logs(docker: str, container_name: str) -> str:
    result = run_command([docker, "logs", "--tail", "80", container_name], check=False)
    output = result.stdout.strip()
    if result.stderr.strip():
        output = f"{output}\n{result.stderr.strip()}".strip()
    return output


def create_infinity_datasource(base_url: str, headers: dict[str, str]) -> str:
    response = request_json(
        "POST",
        f"{base_url}/api/datasources",
        headers=headers,
        payload={
            "name": "Apotelesma Infinity",
            "type": INFINITY_PLUGIN_ID,
            "access": "proxy",
            "basicAuth": False,
            "isDefault": False,
        },
    )
    datasource = response.get("datasource", {}) if isinstance(response, dict) else {}
    uid = datasource.get("uid")
    if not uid:
        raise SystemExit(f"Grafana did not return a datasource UID: {response}")
    return uid


def patch_dashboard(datasource_uid: str, grafana_json_url: str) -> dict:
    dashboard = json.loads(DASHBOARD_PATH.read_text())
    dashboard.pop("__inputs", None)

    for panel in dashboard.get("panels", []):
        panel["datasource"] = {
            "type": INFINITY_PLUGIN_ID,
            "uid": datasource_uid,
        }

    for variable in dashboard.get("templating", {}).get("list", []):
        if variable.get("name") != "grafana_json_url":
            continue
        variable["query"] = grafana_json_url
        variable["current"] = {
            "selected": False,
            "text": grafana_json_url,
            "value": grafana_json_url,
        }

    return dashboard


def import_dashboard(base_url: str, headers: dict[str, str], dashboard: dict) -> None:
    request_json(
        "POST",
        f"{base_url}/api/dashboards/db",
        headers=headers,
        payload={
            "dashboard": dashboard,
            "folderId": 0,
            "overwrite": True,
        },
    )


def frame_rows(frame: dict) -> list[dict[str, object]]:
    schema_fields = frame.get("schema", {}).get("fields", [])
    values = frame.get("data", {}).get("values", [])
    if not isinstance(schema_fields, list) or not isinstance(values, list) or not values:
        return []

    field_names = [field.get("name", f"field_{index}") for index, field in enumerate(schema_fields)]
    row_count = 0
    for column in values:
        if isinstance(column, list):
            row_count = max(row_count, len(column))

    rows: list[dict[str, object]] = []
    for row_index in range(row_count):
        row: dict[str, object] = {}
        for field_name, column in zip(field_names, values):
            if isinstance(column, list) and row_index < len(column):
                row[field_name] = column[row_index]
        rows.append(row)
    return rows


def query_panel(
    base_url: str,
    headers: dict[str, str],
    datasource_uid: str,
    panel: dict,
) -> tuple[int, str]:
    target = dict(panel.get("targets", [])[0])
    ref_id = target.get("refId", "A")
    target["datasource"] = {
        "type": INFINITY_PLUGIN_ID,
        "uid": datasource_uid,
    }
    target["intervalMs"] = 60000
    target["maxDataPoints"] = 1000

    now_ms = int(time.time() * 1000)
    ninety_days_ms = 90 * 24 * 60 * 60 * 1000
    response = request_json(
        "POST",
        f"{base_url}/api/ds/query",
        headers=headers,
        payload={
            "from": str(now_ms - ninety_days_ms),
            "to": str(now_ms),
            "queries": [target],
        },
        ok_statuses=(200,),
        timeout=20,
    )

    if not isinstance(response, dict):
        raise SystemExit(f"{panel.get('title', '<untitled>')}: unexpected query response {response!r}")

    results = response.get("results", {})
    result = results.get(ref_id)
    if not isinstance(result, dict):
        raise SystemExit(f"{panel.get('title', '<untitled>')}: missing query result for refId {ref_id}")
    if result.get("error"):
        raise SystemExit(f"{panel.get('title', '<untitled>')}: {result['error']}")

    rows: list[dict[str, object]] = []
    for frame in result.get("frames", []):
        if isinstance(frame, dict):
            rows.extend(frame_rows(frame))

    preview = ""
    if rows:
        first_row = rows[0]
        preview_items = []
        for key in list(first_row.keys())[:3]:
            preview_items.append(f"{key}={first_row[key]}")
        preview = ", ".join(preview_items)

    return len(rows), preview


def main() -> int:
    docker = require_command("docker")

    site_port = env_int("SITE_PORT", 18000)
    grafana_port = env_int("GRAFANA_PORT", 3300)
    grafana_image = os.environ.get("GRAFANA_IMAGE", "grafana/grafana")
    container_name = os.environ.get("GRAFANA_CONTAINER_NAME", "apotelesma-grafana-smoke")
    admin_user = os.environ.get("GRAFANA_ADMIN_USER", "admin")
    admin_password = os.environ.get("GRAFANA_ADMIN_PASSWORD", "admin")
    keep_running = os.environ.get("KEEP_GRAFANA", "").lower() in {"1", "true", "yes"}
    grafana_json_url = os.environ.get(
        "GRAFANA_JSON_URL",
        f"http://host.docker.internal:{site_port}/data/grafana.json",
    )

    site_server: subprocess.Popen[str] | None = None
    container_started = False

    try:
        print(f"Serving {SITE_DIST_DIR} on http://127.0.0.1:{site_port}/")
        site_server = start_site_server(site_port)

        print(f"Starting Grafana on http://127.0.0.1:{grafana_port}/")
        start_grafana_container(
            docker=docker,
            container_name=container_name,
            grafana_port=grafana_port,
            grafana_image=grafana_image,
            admin_user=admin_user,
            admin_password=admin_password,
        )
        container_started = True

        base_url = f"http://127.0.0.1:{grafana_port}"
        headers = basic_auth_headers(admin_user, admin_password)

        try:
            wait_for_json(
                description="Grafana health",
                method="GET",
                url=f"{base_url}/api/health",
                headers=headers,
                payload=None,
                predicate=lambda body: isinstance(body, dict) and body.get("database") == "ok",
                timeout_seconds=120,
            )
        except SystemExit as exc:
            logs = grafana_logs(docker, container_name)
            raise SystemExit(f"{exc}\n\nGrafana logs:\n{logs}") from exc
        print("Grafana API is ready.")

        try:
            wait_for_json(
                description="Infinity plugin",
                method="GET",
                url=f"{base_url}/api/plugins/{INFINITY_PLUGIN_ID}/settings",
                headers=headers,
                payload=None,
                predicate=lambda body: isinstance(body, dict) and body.get("id") == INFINITY_PLUGIN_ID,
                timeout_seconds=180,
            )
        except SystemExit as exc:
            logs = grafana_logs(docker, container_name)
            raise SystemExit(f"{exc}\n\nGrafana logs:\n{logs}") from exc
        print("Infinity plugin is available.")

        datasource_uid = create_infinity_datasource(base_url, headers)
        print(f"Created datasource Apotelesma Infinity with uid={datasource_uid}")

        dashboard = patch_dashboard(datasource_uid, grafana_json_url)
        import_dashboard(base_url, headers, dashboard)
        print("Imported Apotelesma starter dashboard.")

        print("Live panel queries:")
        for panel in dashboard.get("panels", []):
            title = panel.get("title", "<untitled>")
            row_count, preview = query_panel(base_url, headers, datasource_uid, panel)
            if row_count <= 0:
                raise SystemExit(f"{title}: query returned no rows")
            if preview:
                print(f"- {title}: rows={row_count}; sample={preview}")
            else:
                print(f"- {title}: rows={row_count}")

        print("\nGrafana smoke test passed.")
        print(f"Data URL used: {grafana_json_url}")
        if keep_running:
            print(f"Grafana left running for review at {base_url}/")
            print(f"Login: {admin_user} / {admin_password}")
        return 0
    finally:
        if container_started and not keep_running:
            stop_grafana_container(docker, container_name)
        if site_server is not None and not keep_running:
            site_server.terminate()
            try:
                site_server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                site_server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
