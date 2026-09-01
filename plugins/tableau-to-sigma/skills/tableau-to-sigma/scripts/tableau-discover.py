#!/usr/bin/env python3
"""Discover a Tableau workbook through REST without requiring Ruby.

The output contract matches the existing discovery lane: workbook metadata,
thin workbook XML, view CSVs, dashboard PNGs, optional datasource metadata,
and a timings ledger.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import html
import json
import os
import re
import sys
import threading
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import tableau_rest as tableau  # noqa: E402

WRITE_LOCK = threading.Lock()


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def atomic_write(path: Path, content: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    if isinstance(content, bytes):
        temp.write_bytes(content)
    else:
        temp.write_text(content, encoding="utf-8")
    temp.replace(path)


def safe_name(value: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-")
    return name[:120] or "dashboard"


def workbook_xml(payload: bytes, out: Path) -> tuple[str, bool]:
    if payload.startswith(b"PK\x03\x04"):
        twbx = out / "workbook-content.twbx"
        atomic_write(twbx, payload)
        with zipfile.ZipFile(twbx) as archive:
            names = archive.namelist()
            inner = next((name for name in names if name.lower().endswith(".twb")), None)
            if not inner:
                raise ValueError("downloaded .twbx contains no .twb workbook")
            xml = archive.read(inner).decode("utf-8-sig", errors="replace")
            has_extract = any(name.lower().endswith(".hyper") for name in names)
    else:
        xml = payload.decode("utf-8-sig", errors="replace")
        has_extract = False
    atomic_write(out / "workbook-content.twb", xml)
    return xml, has_extract


def twb_names(xml: str) -> tuple[list[str], dict[str, list[str]]]:
    worksheets = [
        html.unescape(single or double)
        for single, double in re.findall(
            r"<worksheet\s[^>]*?name=(?:'([^']*)'|\"([^\"]*)\")", xml
        )
    ]
    dashboards: dict[str, list[str]] = {}
    block = re.search(r"<dashboards>.*?</dashboards>", xml, flags=re.DOTALL)
    if not block:
        return worksheets, dashboards
    for segment in re.split(r"(?=<dashboard[\s>])", block.group(0)):
        match = re.match(
            r"<dashboard\s[^>]*?name=(?:'([^']*)'|\"([^\"]*)\")", segment
        )
        if not match:
            continue
        name = html.unescape(match.group(1) or match.group(2))
        zone_names = [
            html.unescape(single or double)
            for single, double in re.findall(
                r"<zone\s[^>]*?name=(?:'([^']*)'|\"([^\"]*)\")", segment
            )
        ]
        dashboards[name] = [item for item in zone_names if item in worksheets]
    return worksheets, dashboards


def match_name(target: str, names: list[str]) -> str | None:
    stripped = target.strip()
    exact = next((name for name in names if name.strip() == stripped), None)
    if exact:
        return exact
    folded = next(
        (name for name in names if name.strip().casefold() == stripped.casefold()),
        None,
    )
    if folded:
        return folded
    partial = [name for name in names if stripped.casefold() in name.casefold()]
    return partial[0] if len(partial) == 1 else None


def scoped_views(
    targets: list[str], views: list[dict], membership: dict[str, list[dict]]
) -> list[dict] | None:
    if not targets or not membership:
        return None
    selected: dict[str, dict] = {}
    for target in targets:
        dashboard = match_name(target, list(membership))
        if not dashboard:
            return None
        for sheet in membership[dashboard]:
            view = next(
                (
                    item
                    for item in views
                    if sheet.get("luid") and item.get("id") == sheet.get("luid")
                ),
                None,
            )
            if view is None:
                view = next(
                    (
                        item
                        for item in views
                        if str(item.get("name", "")).strip().casefold()
                        == str(sheet.get("name", "")).strip().casefold()
                    ),
                    None,
                )
            if view and view.get("id"):
                selected[view["id"]] = view
    return list(selected.values()) or None


class Timings:
    def __init__(self):
        self.started = time.monotonic()
        self.rows: list[dict] = []
        self.lock = threading.Lock()

    def run(self, name, function):
        start = time.monotonic()
        try:
            value = function()
        except Exception as exc:
            with self.lock:
                self.rows.append(
                    {
                        "task": name,
                        "start": round(start - self.started, 3),
                        "seconds": round(time.monotonic() - start, 3),
                        "attempts": 1,
                        "ok": False,
                        "error": str(exc)[:200],
                    }
                )
            raise
        with self.lock:
            self.rows.append(
                {
                    "task": name,
                    "start": round(start - self.started, 3),
                    "seconds": round(time.monotonic() - start, 3),
                    "attempts": 1,
                    "ok": True,
                }
            )
        return value


def discover(args: argparse.Namespace) -> dict:
    out = Path(args.out).expanduser().resolve()
    (out / "views").mkdir(parents=True, exist_ok=True)
    timings = Timings()
    tableau.refresh_token()

    def resolve_workbook():
        if args.workbook_id:
            return tableau.get_workbook(args.workbook_id)
        hit = tableau.find_workbook_by_name(args.workbook_name)
        if not hit:
            raise ValueError(f"no workbook found with name={args.workbook_name!r}")
        return tableau.get_workbook(hit["id"])

    workbook = timings.run("get-workbook", resolve_workbook)
    atomic_write(
        out / "get-workbook.json",
        json.dumps(workbook, indent=2, ensure_ascii=False) + "\n",
    )
    views = as_list((workbook.get("views") or {}).get("view"))

    xml = ""
    has_extract = False
    dashboards: dict[str, list[str]] = {}
    if not args.skip_content:
        payload = timings.run(
            "twb-download",
            lambda: tableau.download_workbook_content(workbook["id"]),
        )
        xml, has_extract = workbook_xml(payload, out)
        _, dashboards = twb_names(xml)

    membership: dict[str, list[dict]] = {}
    if args.dashboard:
        try:
            rows = timings.run(
                "dashboard-membership",
                lambda: tableau.graphql_workbook_dashboards(workbook["id"]),
            )
            membership = {
                str(row.get("name", "")): as_list(row.get("sheets"))
                for row in rows or []
            }
        except tableau.TableauError:
            membership = {
                name: [{"name": sheet, "luid": None} for sheet in sheets]
                for name, sheets in dashboards.items()
            }
    csv_views = scoped_views(args.dashboard, views, membership) or views

    def fetch_csv(view):
        view_id = view["id"]
        body = timings.run(
            f"view-csv:{view_id}", lambda: tableau.view_data(view_id)
        )
        atomic_write(out / "views" / f"{view_id}.csv", body)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.pool) as pool:
        futures = [pool.submit(fetch_csv, view) for view in csv_views if view.get("id")]
        for future in futures:
            future.result()

    fetched_dashboards = 0
    if not args.skip_images:
        (out / "dashboards").mkdir(parents=True, exist_ok=True)
        dashboard_names = list(dashboards)
        if not dashboard_names:
            dashboard_names = [str(view.get("name", "")) for view in views]
        for dashboard_name in dashboard_names:
            view = next(
                (
                    item
                    for item in views
                    if str(item.get("name", "")).strip().casefold()
                    == dashboard_name.strip().casefold()
                ),
                None,
            )
            if not view or not view.get("id"):
                continue
            image = timings.run(
                f"dashboard-png:{view['id']}",
                lambda view_id=view["id"]: tableau.view_image(view_id),
            )
            atomic_write(
                out / "dashboards" / f"{safe_name(dashboard_name)}.png", image
            )
            atomic_write(out / "views" / f"{view['id']}.png", image)
            fetched_dashboards += 1

    if args.datasource_luid or args.datasource_name:
        datasource = None
        if args.datasource_luid:
            datasource = {"id": args.datasource_luid}
        elif args.datasource_name:
            datasource = tableau.find_datasource_by_name(args.datasource_name)
        if datasource and datasource.get("id"):
            luid = datasource["id"]
            try:
                metadata = timings.run(
                    "datasource-metadata", lambda: tableau.read_metadata(luid)
                )
                atomic_write(
                    out / "ds-metadata.json",
                    json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
                )
            except tableau.TableauError:
                pass
            try:
                fields = timings.run(
                    "graphql-fields",
                    lambda: tableau.graphql_datasource_fields(luid),
                )
                atomic_write(
                    out / "graphql-fields.json",
                    json.dumps(fields, indent=2, ensure_ascii=False) + "\n",
                )
            except tableau.TableauError:
                pass

    atomic_write(
        out / "timings.json",
        json.dumps(timings.rows, indent=2, ensure_ascii=False) + "\n",
    )
    result = {
        "workbook_id": workbook.get("id"),
        "workbook_name": workbook.get("name"),
        "views": len(views),
        "csv_views": len(csv_views),
        "dashboards_expected": len(dashboards),
        "dashboards_fetched": fetched_dashboards,
        "has_extract": has_extract,
        "workdir": str(out),
    }
    atomic_write(
        out / "discovery-result.json",
        json.dumps(result, indent=2, ensure_ascii=False) + "\n",
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--workbook-name")
    source.add_argument("--workbook-id")
    parser.add_argument("--dashboard", action="append", default=[])
    parser.add_argument("--datasource-name")
    parser.add_argument("--datasource-luid")
    parser.add_argument("--out", required=True)
    parser.add_argument("--pool", type=int, default=5)
    parser.add_argument("--skip-images", action="store_true")
    parser.add_argument("--skip-content", action="store_true")
    args = parser.parse_args()
    if args.pool < 1:
        parser.error("--pool must be at least 1")
    try:
        result = discover(args)
    except (OSError, ValueError, tableau.TableauError) as exc:
        print(f"FATAL: Tableau discovery failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
