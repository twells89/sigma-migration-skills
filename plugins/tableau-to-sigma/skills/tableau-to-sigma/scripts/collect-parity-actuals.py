#!/usr/bin/env python3
"""Collect complete Sigma parity actuals through documented REST exports.

For each planned element this script starts an asynchronous workbook export,
polls the query download endpoint, and paginates with rowLimit/offset until the
element is exhausted. CSV is used for ordinary charts and JSON for pivot grids.
Every request is bounded by one process-wide deadline and refreshes an expired
Sigma bearer token once on HTTP 401.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import io
import json
import os
import random
import re
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import code_rep  # noqa: E402
import sigma_rest  # noqa: E402


DEFAULT_PAGE_SIZE = 100_000
MAX_PAGE_SIZE = 1_000_000
RETRYABLE_STATUSES = {408, 429, 502, 503, 504}
_REFRESH_LOCK = threading.Lock()
_OUTPUT_LOCK = threading.Lock()


class CollectionError(RuntimeError):
    """A complete current actual could not be collected."""


class CollectionTimeout(CollectionError):
    """The total collection deadline expired."""


class RestError(CollectionError):
    def __init__(self, method: str, path: str, status: int, body: bytes):
        self.method = method
        self.path = path
        self.status = status
        self.body = body
        text = body.decode(errors="replace").replace("\n", " ")[:240]
        super().__init__(f"{method.upper()} {path} -> {status}: {text}")


class Deadline:
    def __init__(self, seconds: float):
        if seconds <= 0:
            raise ValueError("--timeout must be positive")
        self.started = time.monotonic()
        self.budget = float(seconds)

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self.started

    @property
    def remaining(self) -> float:
        return self.budget - self.elapsed

    def check(self, context: str = "operation") -> None:
        if self.remaining <= 0:
            raise CollectionTimeout(
                f"total --timeout ({self.budget:g}s) reached during {context}"
            )


def _request_raw(
    method: str,
    path: str,
    *,
    deadline: Deadline,
    body: str | None = None,
    accept: str = "application/json",
    content_type: str = "application/json",
):
    """Deadline-aware sigma_rest request using its token lifecycle.

    sigma_rest.request has a fixed 120-second socket timeout. Export collection
    needs the shorter remaining whole-run budget, so this local transport uses
    sigma_rest's authenticated low-level seam while preserving its proactive
    token aging and one-refresh-on-401 behavior.
    """
    attempts = 0
    while True:
        deadline.check(path)
        attempts += 1
        token = sigma_rest.auth_token()
        headers = {"Authorization": f"Bearer {token}", "Accept": accept}
        if body is not None:
            headers["Content-Type"] = content_type
        response = sigma_rest._send(  # pylint: disable=protected-access
            method,
            f"{sigma_rest.base_url()}{path}",
            headers,
            body,
            max(0.05, min(120.0, deadline.remaining)),
        )
        if (
            response.status == 401
            and attempts == 1
            and os.environ.get("SIGMA_CLIENT_ID")
        ):
            with _REFRESH_LOCK:
                current = sigma_rest.auth_token()
                if current == token:
                    sigma_rest.refresh_token()
            continue
        return response


def _request_with_retry(
    method: str,
    path: str,
    *,
    deadline: Deadline,
    body: str | None = None,
    accept: str = "application/json",
):
    attempts = 0
    while True:
        attempts += 1
        response = _request_raw(
            method, path, deadline=deadline, body=body, accept=accept
        )
        if 200 <= response.status < 300:
            return response
        if response.status not in RETRYABLE_STATUSES or attempts >= 4:
            raise RestError(method, path, response.status, response.body)
        delay = (1.5 * (2 ** (attempts - 1))) + random.random() * 0.5
        deadline.check(f"retry backoff for {path}")
        time.sleep(min(delay, max(0.0, deadline.remaining)))


def _json_response(response, context: str) -> dict:
    try:
        parsed = json.loads(response.body or b"{}")
    except (TypeError, ValueError) as exc:
        raise CollectionError(f"{context} returned invalid JSON") from exc
    if not isinstance(parsed, dict):
        raise CollectionError(f"{context} returned {type(parsed).__name__}, expected object")
    return parsed


def start_export(
    workbook_id: str,
    element_id: str,
    fmt: str,
    page_size: int,
    offset: int,
    deadline: Deadline,
) -> str:
    deadline.check("export start")
    payload = {
        "elementId": element_id,
        "format": {"type": fmt},
        "rowLimit": page_size,
        "offset": offset,
        "runAsynchronously": True,
        "timeout": max(1, int(min(300, deadline.remaining))),
    }
    path = f"/v2/workbooks/{workbook_id}/export"
    response = _request_with_retry(
        "post",
        path,
        deadline=deadline,
        body=json.dumps(payload, separators=(",", ":")),
    )
    result = _json_response(response, "workbook export")
    query_id = result.get("queryId")
    if not isinstance(query_id, str) or not query_id:
        raise CollectionError("workbook export returned no queryId")
    return query_id


def poll_download(
    query_id: str,
    *,
    accept: str,
    deadline: Deadline,
    poll_interval: float = 1.0,
) -> bytes:
    path = f"/v2/query/{query_id}/download"
    while True:
        deadline.check(f"query {query_id} download")
        response = _request_raw("get", path, deadline=deadline, accept=accept)
        if response.status == 200:
            body = bytes(response.body)
            if not body:
                time.sleep(min(poll_interval, max(0.0, deadline.remaining)))
                continue
            if body.lstrip().startswith(b"<"):
                raise CollectionError("export download returned HTML instead of data")
            return body
        if response.status in {204, 404}:
            time.sleep(min(poll_interval, max(0.0, deadline.remaining)))
            continue
        if response.status in RETRYABLE_STATUSES:
            time.sleep(min(poll_interval, max(0.0, deadline.remaining)))
            continue
        raise RestError("get", path, response.status, response.body)


def parse_json_rows(body: bytes) -> list[dict]:
    text = body.decode("utf-8-sig", errors="replace").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
    except ValueError:
        rows = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except ValueError as exc:
                raise CollectionError("JSON export returned malformed JSON/NDJSON") from exc
            if isinstance(item, dict):
                rows.append(item)
        return rows
    if isinstance(parsed, list):
        return [item for item in parsed if isinstance(item, dict)]
    if isinstance(parsed, dict):
        wrapped = parsed.get("rows", parsed.get("data"))
        if isinstance(wrapped, list):
            return [item for item in wrapped if isinstance(item, dict)]
        return [parsed]
    raise CollectionError("JSON export did not contain row objects")


def export_all_pages(
    workbook_id: str,
    element_id: str,
    *,
    fmt: str,
    page_size: int,
    deadline: Deadline,
    max_rows: int | None,
    poll_interval: float = 1.0,
) -> tuple[list[str], list[list]]:
    headers = None
    all_rows = []
    offset = 0
    while True:
        query_id = start_export(
            workbook_id, element_id, fmt, page_size, offset, deadline
        )
        body = poll_download(
            query_id,
            accept="application/json" if fmt == "json" else "text/csv",
            deadline=deadline,
            poll_interval=poll_interval,
        )
        if fmt == "json":
            objects = parse_json_rows(body)
            page_headers = list(objects[0].keys()) if objects else (headers or [])
            page_rows = [
                [item.get(header) for header in page_headers] for item in objects
            ]
        else:
            try:
                parsed = list(csv.reader(io.StringIO(body.decode("utf-8-sig"))))
            except (UnicodeError, csv.Error) as exc:
                raise CollectionError("CSV export could not be parsed") from exc
            page_headers = parsed[0] if parsed else []
            page_rows = parsed[1:] if parsed else []

        if headers is None:
            if not page_headers:
                raise CollectionError("export returned no header")
            headers = [str(header).strip() for header in page_headers]
        elif [str(header).strip() for header in page_headers] != headers:
            raise CollectionError("export headers changed between pagination chunks")
        if any(len(row) != len(headers) for row in page_rows):
            raise CollectionError("export returned ragged rows")

        all_rows.extend(page_rows)
        if max_rows is not None and len(all_rows) > max_rows:
            raise CollectionError(
                f"element exceeds --max-rows {max_rows}; refusing partial actuals"
            )
        if len(page_rows) < page_size:
            return headers, all_rows
        # Sigma documents the next 1-based row after a full chunk (for example,
        # rowLimit=2500 -> offset=2501). The first chunk is the special offset 0.
        offset = len(all_rows) + 1


def parse_cell(value):
    if value is None or str(value).strip() == "":
        return None
    text = str(value).strip()
    percent = text.endswith("%")
    try:
        number = float(re.sub(r"[,$%]", "", text))
    except ValueError:
        return value
    return number / 100.0 if percent else number


def map_columns(
    headers: list[str], rows: list[list], wanted_names: list[str]
) -> list[list]:
    used = set()
    indexes = []
    for wanted in wanted_names:
        match = next(
            (
                index
                for index, header in enumerate(headers)
                if index not in used and header.casefold() == wanted.casefold()
            ),
            None,
        )
        if match is None:
            raise CollectionError(
                f"export headers {headers!r} are missing planned column {wanted!r}"
            )
        used.add(match)
        indexes.append(match)
    return [[parse_cell(row[index]) for index in indexes] for row in rows]


def collect_chart(
    chart: dict,
    elements_by_id: dict[str, dict],
    workbook_id: str,
    page_size: int,
    deadline: Deadline,
    max_rows: int | None,
    poll_interval: float = 1.0,
) -> list[list]:
    element_id = str(chart.get("sigma_element_id") or "")
    element = elements_by_id.get(element_id)
    if not element:
        raise CollectionError(f"element {element_id!r} is not in workbook readback")
    names_by_id = {
        str(column.get("id")): str(column.get("name") or "").strip()
        for column in (element.get("columns") or [])
        if isinstance(column, dict)
    }
    planned_columns = chart.get("sigma_columns") or []
    wanted = [names_by_id.get(str(column_id)) for column_id in planned_columns]
    if not wanted or any(name is None or name == "" for name in wanted):
        raise CollectionError(
            f"planned column id(s) do not resolve on element {element_id!r}"
        )

    has_totals = "totals" in element and element.get("totals") not in (None, {}, [])
    fmt = "json" if chart.get("sigma_kind") == "pivot-table" or has_totals else "csv"
    try:
        headers, rows = export_all_pages(
            workbook_id,
            element_id,
            fmt=fmt,
            page_size=page_size,
            deadline=deadline,
            max_rows=max_rows,
            poll_interval=poll_interval,
        )
    except RestError as exc:
        if fmt == "csv" and 500 <= exc.status < 600:
            headers, rows = export_all_pages(
                workbook_id,
                element_id,
                fmt="json",
                page_size=page_size,
                deadline=deadline,
                max_rows=max_rows,
                poll_interval=poll_interval,
            )
        else:
            raise
    actual = map_columns(headers, rows, wanted)
    if not actual:
        raise CollectionError(
            f"displayed tile {chart.get('chart')!r} exports zero data rows"
        )
    return actual


def load_json(path: Path):
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def source_capture_epoch(plan: dict, plan_path: Path) -> int | None:
    stamped = plan.get("source_csv_max_mtime")
    if stamped is not None:
        return int(stamped)
    csv_files = list((plan_path.parent / "views").glob("*.csv"))
    return max((int(path.stat().st_mtime) for path in csv_files), default=None)


def document_version(spec: dict) -> str | None:
    if not isinstance(spec, dict):
        return None
    value = spec.get("latestDocumentVersion") or spec.get("latestVersion")
    return str(value) if value is not None and str(value) else None


def validate_live_document_version(
    spec: dict, workbook_id: str, deadline: Deadline
) -> str:
    """Prove the element readback still describes the live workbook."""
    readback_id = spec.get("workbookId") if isinstance(spec, dict) else None
    if readback_id is not None and str(readback_id) != str(workbook_id):
        raise CollectionError(
            f"workbook readback belongs to {readback_id!r}, not {workbook_id!r}"
        )
    readback_version = document_version(spec)
    if readback_version is None:
        raise CollectionError(
            "workbook readback has no latestDocumentVersion/latestVersion; "
            "freshness cannot be proven"
        )
    path = f"/v2/workbooks/{workbook_id}/spec"
    response = _request_with_retry("get", path, deadline=deadline)
    live = _json_response(response, "live workbook spec")
    live_version = document_version(live)
    if live_version is None:
        raise CollectionError(
            "live workbook spec has no latestDocumentVersion/latestVersion"
        )
    if live_version != readback_version:
        raise CollectionError(
            f"stale workbook readback: artifact is document version "
            f"{readback_version}, live workbook is {live_version}"
        )
    return live_version


def collect(
    plan: dict,
    spec: dict,
    *,
    workbook_id: str,
    page_size: int,
    timeout: float,
    pool: int,
    max_rows: int | None = None,
    poll_interval: float = 1.0,
) -> tuple[dict, dict]:
    charts = plan.get("charts") if isinstance(plan, dict) else plan
    if not isinstance(charts, list) or not charts:
        raise CollectionError("parity plan contains no charts")
    if any(not isinstance(chart, dict) for chart in charts):
        raise CollectionError("parity plan charts must be objects")
    names = [str(chart.get("chart") or chart.get("name") or "") for chart in charts]
    if any(not name for name in names):
        raise CollectionError("every parity chart must have a name")
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise CollectionError(
            "duplicate chart names cannot fit the existing actuals contract: "
            + ", ".join(repr(name) for name in duplicates)
        )

    elements = code_rep.workbook_elements(spec)
    elements_by_id = {
        str(element.get("id")): element
        for element in elements
        if str(element.get("id") or "")
    }
    deadline = Deadline(timeout)
    validate_live_document_version(spec, workbook_id, deadline)
    actuals = {}
    failures = {}

    def worker(chart):
        name = str(chart.get("chart") or chart.get("name"))
        with _OUTPUT_LOCK:
            print(
                f"  [pool +{deadline.elapsed:6.1f}s] START   {name!r} "
                f"({chart.get('sigma_element_id')})",
                file=sys.stderr,
            )
        try:
            rows = collect_chart(
                chart,
                elements_by_id,
                workbook_id,
                page_size,
                deadline,
                max_rows,
                poll_interval,
            )
            result = ("ok", rows)
        except CollectionTimeout as exc:
            result = ("timeout", str(exc))
        except (CollectionError, sigma_rest.SigmaError, OSError, ValueError) as exc:
            status = (
                "empty-displayed-tile"
                if "zero data rows" in str(exc)
                else "collection-error"
            )
            result = (status, str(exc))
        with _OUTPUT_LOCK:
            detail = f"{len(result[1])} row(s)" if result[0] == "ok" else result[0]
            print(
                f"  [pool +{deadline.elapsed:6.1f}s] DONE    {name!r} — {detail}",
                file=sys.stderr,
            )
        return name, result

    workers = min(max(1, pool), len(charts), 16)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(worker, chart) for chart in charts]
        for future in concurrent.futures.as_completed(futures):
            name, (status, payload) = future.result()
            if status == "ok":
                actuals[name] = payload
            else:
                failures[name] = {"status": status, "reason": payload}
    return actuals, failures


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--workbook-id", required=True)
    parser.add_argument("--workbook-spec", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pool", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument(
        "--row-limit",
        "--page-size",
        dest="page_size",
        type=int,
        default=DEFAULT_PAGE_SIZE,
        help="rows per documented export page (default 100000; max 1000000)",
    )
    parser.add_argument(
        "--max-rows",
        type=int,
        help="optional fail-closed whole-element cap; pagination is otherwise deadline-bounded",
    )
    parser.add_argument(
        "--drift-warn-minutes",
        type=float,
        default=float(os.environ.get("PARITY_DRIFT_WARN_MINUTES", "30")),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.page_size <= 0 or args.page_size > MAX_PAGE_SIZE:
        print(
            f"FATAL: --row-limit/--page-size must be 1..{MAX_PAGE_SIZE}",
            file=sys.stderr,
        )
        return 1
    if args.pool <= 0 or args.max_rows is not None and args.max_rows <= 0:
        print("FATAL: --pool and --max-rows must be positive", file=sys.stderr)
        return 1

    plan_path = Path(args.plan)
    out_path = Path(args.out)
    try:
        plan = load_json(plan_path)
        spec = load_json(Path(args.workbook_spec))
        if args.drift_warn_minutes > 0:
            captured = source_capture_epoch(plan, plan_path)
            if captured is not None:
                age_minutes = (time.time() - captured) / 60.0
                if age_minutes > args.drift_warn_minutes:
                    print(
                        f"WARNING: source CSVs were captured {age_minutes:.0f} min ago; "
                        "a live warehouse may have changed before actuals collection",
                        file=sys.stderr,
                    )
        actuals, failures = collect(
            plan,
            spec,
            workbook_id=args.workbook_id,
            page_size=args.page_size,
            timeout=args.timeout,
            pool=args.pool,
            max_rows=args.max_rows,
        )
        existing = load_json(out_path) if out_path.is_file() else {}
        if not isinstance(existing, dict):
            raise CollectionError("existing actuals artifact must be an object")
        existing.update(actuals)
        # Current failures overwrite stale rows: live emptiness/errors must not
        # be hidden by a successful artifact from an older workbook state.
        existing.update(failures)
        atomic_write_json(out_path, existing)
    except (
        CollectionError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        sigma_rest.SigmaError,
    ) as exc:
        print(f"FATAL: actuals collection failed: {exc}", file=sys.stderr)
        return 1

    print(
        f"collect-parity-actuals: {len(actuals)}/{len(plan['charts'])} chart(s) "
        f"collected through Sigma REST export -> {out_path}"
    )
    for name, marker in failures.items():
        print(f"  NOT COLLECTED {name}: {marker['reason']}")
    if any(marker["status"] == "timeout" for marker in failures.values()):
        return 3
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
