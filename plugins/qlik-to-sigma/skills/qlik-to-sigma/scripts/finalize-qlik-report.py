#!/usr/bin/env python3
"""Finalize Qlik accounting, image health, similarity, ledger, and report.

This command is intentionally safe on RED paths: every producer is attempted,
all diagnostics are persisted, and the final exit is non-zero if any contract
fails. It performs no Sigma writes.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import degradation_ledger  # noqa: E402


def fold(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def read_json(path):
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    try:
        temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def run(command, cwd=None):
    result = subprocess.run(
        [str(part) for part in command],
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.splitlines():
        print("   " + line)
    return result.returncode


def workbook_pages(workdir):
    doc = read_json(workdir / "wb-readback.json") or read_json(workdir / "wb-spec.json") or {}
    root = doc.get("document") if isinstance(doc.get("document"), dict) else doc
    pages = []
    for row in root.get("pages") or []:
        if not isinstance(row, dict):
            continue
        page_id = str(row.get("id") or row.get("pageId") or "")
        name = str(row.get("name") or row.get("title") or page_id)
        if row.get("visibility") == "hidden" or page_id.strip().casefold() in {
            "data", "page-data", "pg-data",
        }:
            continue
        pages.append({"id": page_id, "name": name})
    return pages


def manifest_pngs(workdir):
    result = set()
    for manifest in workdir.rglob("_manifest.json"):
        if "visual-qa" in manifest.parts:
            continue
        doc = read_json(manifest)
        rows = doc.values() if isinstance(doc, dict) else doc if isinstance(doc, list) else []
        for row in rows:
            if not isinstance(row, dict):
                continue
            value = row.get("png") or row.get("path") or row.get("image")
            if not value:
                continue
            path = Path(value)
            if not path.is_absolute():
                path = manifest.parent / path
                if not path.is_file():
                    path = workdir / value
            if path.is_file() and path.suffix.lower() == ".png":
                result.add(path.resolve())
    return result


def source_pngs(workdir, explicit):
    # Explicit inputs are retained even when missing so the health pass emits a
    # deterministic ERROR artifact instead of silently dropping the request.
    result = {
        (Path(value).expanduser() if Path(value).expanduser().is_absolute()
         else workdir / Path(value).expanduser()).resolve()
        for value in explicit
    }
    result |= manifest_pngs(workdir)
    source_dirs = (
        "dashboards", "views", "shots", "source", "source-pages",
        "source-captures", "qlik-captures", "qlik-screenshots", "user-screenshots",
    )
    for directory in source_dirs:
        base = workdir / directory
        if base.is_dir():
            result |= {path.resolve() for path in base.rglob("*.png") if path.is_file()}
            result |= {path.resolve() for path in base.rglob("*.PNG") if path.is_file()}
    # A user-provided capture can have any filename. Treat every PNG outside
    # generated Sigma/health output directories as source evidence. This is
    # deliberately inclusive: missing a bad source capture is worse than
    # checking an extra customer screenshot.
    generated = {
        "visual-qa", "png-health", "visual-similarity-pages",
    }
    for path in workdir.rglob("*.png"):
        try:
            relative = path.relative_to(workdir)
        except ValueError:
            relative = path
        if not any(part in generated for part in relative.parts):
            result.add(path.resolve())
    targets = {
        path.resolve() for path in (workdir / "visual-qa").rglob("*.png")
    } if (workdir / "visual-qa").is_dir() else set()
    result -= targets
    return sorted(path for path in result if path.suffix.lower() == ".png")


def page_source_pngs(workdir, pages, sources, explicit):
    """Return source PNGs eligible for full-page pairing.

    Object-level reporting API captures still receive PNG health checks, but
    they must not be compared to an entire Sigma page merely because there is
    one object and one page.
    """
    explicit_paths = {
        (Path(value).expanduser() if Path(value).expanduser().is_absolute()
         else workdir / Path(value).expanduser()).resolve()
        for value in explicit
    }
    page_keys = {fold(page["id"]) for page in pages} | {fold(page["name"]) for page in pages}
    page_dirs = {"dashboards", "source-pages", "user-screenshots"}
    selected = []
    for path in sources:
        try:
            relative = path.relative_to(workdir)
        except ValueError:
            relative = path
        if (
            path in explicit_paths
            or any(part in page_dirs for part in relative.parts)
            or fold(path.stem) in page_keys
        ):
            selected.append(path)
    return selected


def target_for_page(workdir, page):
    base = workdir / "visual-qa"
    candidates = [
        base / (page["id"] + ".png"),
        base / (page["id"] + ".sigma.png"),
        base / (fold(page["name"]) + ".png"),
        base / (fold(page["name"]) + ".sigma.png"),
    ]
    for path in candidates:
        if path.is_file():
            return path.resolve()
    if base.is_dir():
        matches = [
            path.resolve() for path in base.rglob("*.png")
            if fold(path.stem.replace(".sigma", "")) in (fold(page["id"]), fold(page["name"]))
        ]
        if matches:
            return sorted(matches)[0]
    return candidates[0].resolve()


def safe_health_name(path):
    digest = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:12]
    return "%s-%s.json" % (fold(path.stem) or "image", digest)


def health_one(path, output):
    if not path.is_file():
        result = {
            "path": str(path), "status": "ERROR",
            "reasons": ["expected PNG is missing"],
        }
        write_json(output, result)
        return result, 2
    rc = run([sys.executable, HERE / "png_health.py", "--image", path, "--json-out", output])
    result = read_json(output)
    if not isinstance(result, dict):
        result = {
            "path": str(path), "status": "ERROR",
            "reasons": ["png_health.py exited %d without readable JSON" % rc],
        }
        write_json(output, result)
    return result, rc


def pair_pages(pages, sources, targets):
    unused = set(sources)
    pairs = []
    for page, target in zip(pages, targets):
        keys = {fold(page["id"]), fold(page["name"])}
        hit = next((source for source in sorted(unused) if fold(source.stem) in keys), None)
        if hit:
            pairs.append((page, hit, target))
            unused.remove(hit)
    # A single source page and a single target page is unambiguous even when a
    # customer screenshot has a descriptive filename unrelated to the source id.
    if not pairs and len(pages) == len(sources) == 1:
        pairs.append((pages[0], sources[0], targets[0]))
    return pairs


def page_tiles(workdir, page, index, output):
    rows = read_json(workdir / "qlik-tile-layout.json")
    if not isinstance(rows, list):
        return None
    layout = read_json(workdir / "layout.json")
    source_page_ids = {fold(page["id"]), fold(page["name"])}
    if isinstance(layout, list) and index < len(layout) and isinstance(layout[index], dict):
        source_page_ids |= {
            fold(layout[index].get("sheetId")), fold(layout[index].get("title")),
        }
    selected = [row for row in rows if isinstance(row, dict) and fold(row.get("page")) in source_page_ids]
    if not selected and len({fold(row.get("page")) for row in rows if isinstance(row, dict)}) <= 1:
        selected = rows
    if not selected:
        return None
    write_json(output, selected)
    return output


def refresh_ledger(workdir):
    try:
        entries = degradation_ledger.derive(workdir)
        return 0 if degradation_ledger.write(workdir, entries) else 1
    except (OSError, ValueError, TypeError) as exc:
        print("   degradation ledger: %s" % exc, file=sys.stderr)
        return 1


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--source-png", action="append", default=[])
    parser.add_argument(
        "--skip-source-pages",
        help="explicit reason source page screenshots are unavailable; source PNG health "
             "still runs for every object capture that exists",
    )
    parser.add_argument("--skip-visual-similarity")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    if not workdir.is_dir():
        print("finalize-qlik-report: --workdir is not a directory: %s" % workdir, file=sys.stderr)
        return 2

    failures = []
    health_failures = []
    print("-- Qlik completion finalizer --")
    accounting_rc = run([sys.executable, HERE / "build-qlik-accounting.py", "--workdir", workdir])
    if accounting_rc:
        failures.append("accounting exited %d" % accounting_rc)

    pages = workbook_pages(workdir)
    expected_targets = [target_for_page(workdir, page) for page in pages]
    extra_targets = sorted({
        path.resolve() for path in (workdir / "visual-qa").rglob("*.png")
    } - set(expected_targets)) if (workdir / "visual-qa").is_dir() else []
    targets = expected_targets + extra_targets
    sources = source_pngs(workdir, args.source_png)
    health_dir = workdir / "png-health"
    source_results = []
    target_results = []
    for path in sources:
        result, rc = health_one(path, health_dir / "source" / safe_health_name(path))
        source_results.append(result)
        if rc != 0 or result.get("status") != "PASS":
            message = "missing/unhealthy Qlik source PNG: %s" % path
            failures.append(message)
            health_failures.append(message)
    for page, path in zip(pages, expected_targets):
        result, rc = health_one(path, health_dir / "sigma" / safe_health_name(path))
        result["page_id"] = page["id"]
        result["page_name"] = page["name"]
        write_json(health_dir / "sigma" / safe_health_name(path), result)
        target_results.append(result)
        if rc != 0 or result.get("status") != "PASS":
            message = "missing/unhealthy Sigma page render: %s" % page["name"]
            failures.append(message)
            health_failures.append(message)
    for path in extra_targets:
        result, rc = health_one(path, health_dir / "sigma" / safe_health_name(path))
        result["page_id"] = None
        result["page_name"] = path.stem
        write_json(health_dir / "sigma" / safe_health_name(path), result)
        target_results.append(result)
        if rc != 0 or result.get("status") != "PASS":
            message = "unhealthy additional Sigma page render: %s" % path
            failures.append(message)
            health_failures.append(message)
    if not pages:
        message = "workbook spec/readback has no content pages"
        failures.append(message)
        health_failures.append(message)
    if not sources and not args.skip_source_pages:
        message = "no Qlik source capture/user screenshot found (explicit skip reason required)"
        failures.append(message)
        health_failures.append(message)

    render_status = "PASS" if not any(
        row.get("status") != "PASS" for row in source_results + target_results
    ) and target_results and (source_results or args.skip_source_pages) else "FAIL"
    render_health = {
        "schema_version": 1,
        "status": render_status,
        "expected_sigma_pages": len(pages),
        "sigma_pages_checked": len(target_results),
        "source_pngs_checked": len(source_results),
        "source_page_waiver": args.skip_source_pages,
        "sources": source_results,
        "sigma_pages": target_results,
        "failures": sorted(set(health_failures)),
    }
    write_json(workdir / "render-health.json", render_health)
    write_json(workdir / "blank-risk.json", {
        "schema_version": 1,
        "status": render_status,
        "blank_count": sum(row.get("status") == "FAIL" for row in source_results + target_results),
        "failures": [
            {"path": row.get("path"), "reasons": row.get("reasons")}
            for row in source_results + target_results if row.get("status") != "PASS"
        ],
    })

    page_sources = page_source_pngs(workdir, pages, sources, args.source_png)
    pairs = pair_pages(pages, page_sources, expected_targets)
    similarity_pages = []
    similarity_dir = workdir / "visual-similarity-pages"
    similarity_pairs = [] if args.skip_visual_similarity else pairs
    for index, (page, source, target) in enumerate(similarity_pairs):
        out = similarity_dir / ("%02d-%s.json" % (index + 1, fold(page["id"]) or "page"))
        tiles_path = page_tiles(
            workdir, page, pages.index(page), similarity_dir / ("%02d-%s-tiles.json" %
                                                                 (index + 1, fold(page["id"]) or "page")),
        )
        command = [
            sys.executable, HERE / "visual-similarity.py",
            "--source", source, "--render", target, "--json-out", out,
        ]
        if tiles_path:
            command += ["--tiles", tiles_path]
        rc = run(command)
        result = read_json(out) or {
            "pass": False, "notes": ["visual-similarity.py exited %d without readable JSON" % rc],
        }
        result = {
            "page_id": page["id"], "page_name": page["name"],
            "source": str(source), "render": str(target), **result,
        }
        similarity_pages.append(result)
        if rc != 0 or result.get("pass") is not True:
            failures.append("visual similarity failed: %s" % page["name"])

    if similarity_pairs:
        similarity_pass = len(similarity_pairs) == len(pages) and all(
            row.get("pass") is True for row in similarity_pages
        )
        if len(similarity_pairs) != len(pages):
            failures.append("source/target page pairs cover %d/%d Sigma pages" %
                            (len(similarity_pairs), len(pages)))
        similarity = {
            "schema_version": 1,
            "status": "PASS" if similarity_pass else "FAIL",
            "pass": similarity_pass,
            "pages_total": len(pages),
            "pages_compared": len(similarity_pairs),
            "pages": similarity_pages,
            "tiles_measured": sum(int(row.get("tiles_measured") or 0) for row in similarity_pages),
            "tiles_blank": [
                "%s:%s" % (row["page_name"], tile)
                for row in similarity_pages for tile in row.get("tiles_blank") or []
            ],
        }
    else:
        waived = bool(args.skip_source_pages or args.skip_visual_similarity)
        similarity = {
            "schema_version": 1,
            "status": "WAIVED" if waived else "FAIL",
            "pass": waived,
            "pages_total": len(pages),
            "pages_compared": 0,
            "reason": args.skip_visual_similarity or args.skip_source_pages or
                      "no page-level source/target pairs found",
            "pages": [],
        }
        if not waived:
            failures.append("no page-level source/target visual-similarity pairs")
    write_json(workdir / "visual-similarity.json", similarity)

    ledger_rc = refresh_ledger(workdir)
    if ledger_rc:
        failures.append("degradation ledger refresh exited %d" % ledger_rc)
    report_command = [
        sys.executable, HERE / "build-migration-report.py", "--workdir", workdir,
        "--inventory", workdir / "source-object-census.json",
    ]
    report_rc = run(report_command)
    if report_rc:
        failures.append("migration report exited %d" % report_rc)
    report_check_rc = run(report_command + ["--check"])
    if report_check_rc:
        failures.append("migration report --check exited %d" % report_check_rc)

    report = read_json(workdir / "migration-result.json") or {}
    result = {
        "schema_version": 1,
        "status": "PASS" if not failures else "FAIL",
        "accounting_exit": accounting_rc,
        "render_health": render_status,
        "visual_similarity": similarity.get("status"),
        "ledger_exit": ledger_rc,
        "report_exit": report_rc,
        "report_check_exit": report_check_rc,
        "report_verdict": report.get("verdict"),
        "failures": sorted(set(failures)),
    }
    write_json(workdir / "qlik-finalization.json", result)
    print("   qlik finalization: %s | report=%s | %d issue(s)" % (
        result["status"], result["report_verdict"] or "MISSING", len(result["failures"]),
    ))
    for failure in result["failures"]:
        print("   FAIL: " + failure, file=sys.stderr)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
