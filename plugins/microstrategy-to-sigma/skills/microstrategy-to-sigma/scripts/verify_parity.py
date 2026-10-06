#!/usr/bin/env python3
"""
verify_parity.py — export each workbook table element from Sigma via the REST
export API and compare against expected_parity.json (MicroStrategy ground truth).

Money / counts: exact. Profit Margin Pct: relative tolerance 1e-6.

Also writes the cross-plugin gate sentinels next to --report:
  parity-final.json  {status, mode, charts_total, charts_pass, fail_names}
  wb-ids.json        {workbookId}
so scripts/assert-phase6-ran.rb (gates 1-7, shared) can prove this phase ran.

Usage: python3 verify_parity.py --workbook-id <id> [--report parity_report.md]
Requires SIGMA_BASE_URL plus a valid bearer, browser-login keychain session, or
SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET fallback.
"""
import argparse
import csv
import io
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import code_rep  # workbook code-rep document-wrapper adapter (nested GET/POST shape)
import sigma_rest

# report name -> (element name, key column names, tolerance map)
TOLERANT = {"Profit Margin Pct": 1e-6}


def api(method, path, body=None, raw=False):
    """Sigma request with the legacy ``(status, payload)`` return contract.

    ``sigma_rest.request`` intentionally hides successful status codes, but the
    export poll distinguishes 200 from other 2xx responses. Use its authenticated
    transport seam so status codes and byte-for-byte raw downloads are preserved
    while still getting proactive token aging and exactly one refresh on 401.
    """
    base = sigma_rest.base_url()
    sigma_rest._validate_once(base)
    headers = {}
    if not path.endswith("/spec") or body is not None:
        headers["Accept"] = "application/json"
    data = json.dumps(body) if body is not None else None
    if body is not None:
        headers["Content-Type"] = "application/json"

    for attempt in range(2):
        headers["Authorization"] = f"Bearer {sigma_rest.auth_token()}"
        response = sigma_rest._send(
            method, f"{base}{path}", headers, data, 120
        )
        if response.status == 401 and attempt == 0:
            sigma_rest.refresh_token()
            continue
        if raw and 200 <= response.status < 300:
            return response.status, response.body
        return response.status, response.body.decode(errors="replace")


def export_element(workbook_id, element_id):
    st, out = api("POST", f"/v2/workbooks/{workbook_id}/export", {
        "elementId": element_id,
        "format": {"type": "csv"},
    })
    if st >= 300:
        raise SystemExit(f"export start failed {st}: {out[:500]}")
    query_id = json.loads(out)["queryId"]
    for _ in range(60):
        st, out = api("GET", f"/v2/query/{query_id}/download", raw=True)
        if st == 200:
            return out.decode("utf-8-sig")
        time.sleep(2)
    raise SystemExit(f"export {query_id} never became ready")


def parse_number(s):
    s = s.strip()
    pct = s.endswith("%")
    s = s.replace(",", "").replace("$", "").replace("%", "")
    if s in ("", "null", "None"):
        return None
    v = float(s)
    return v / 100.0 if pct else v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook-id", required=True)
    ap.add_argument("--expected", default="expected_parity.json")
    ap.add_argument("--keys", default="parity_keys.json",
                    help="optional report-name -> ordered key column names")
    ap.add_argument("--report", default="parity_report.md")
    ap.add_argument("--save-csv-dir", default="exports")
    args = ap.parse_args()

    expected = json.load(open(args.expected))
    # Empty-check guard: 0 expected reports means nothing to verify — the loop
    # below is skipped, all_green stays True, and an empty/placeholder workbook
    # passes vacuously. A migration with nothing to compare is not parity-clean.
    if not expected:
        raise SystemExit("⛔ NOT parity-clean — expected_parity.json has 0 reports: nothing to "
                         "verify. An empty/placeholder workbook cannot pass parity. Capture the "
                         "MicroStrategy ground-truth values and re-run.")
    key_cols_by_report = {}
    if os.path.exists(args.keys):
        key_cols_by_report = json.load(open(args.keys))

    # map report name -> element id from the workbook spec readback
    st, out = api("GET", f"/v2/workbooks/{args.workbook_id}/spec")
    if st >= 300:
        raise SystemExit(f"spec GET failed {st}: {out[:300]}")
    try:
        raw_spec = json.loads(out)
    except json.JSONDecodeError:
        import yaml
        raw_spec = yaml.safe_load(out)
    # Workbook code-rep GETs nest pages/schemaVersion under a top-level
    # `document` key (live since 2026-08); a bare spec["pages"] read here was
    # always a KeyError, so the report-name -> element-id map below never
    # even ran.
    el_by_name = {}
    for el in code_rep.workbook_elements(raw_spec):
        # skip layout containers / header text / controls (no name or
        # not a queryable element)
        if el.get("name") and el.get("kind") not in ("container", "text",
                                                     "control"):
            el_by_name[el["name"]] = el["id"]

    os.makedirs(args.save_csv_dir, exist_ok=True)
    lines = ["# MicroStrategy -> Sigma Parity Report", "",
             f"Workbook: `{args.workbook_id}`", ""]
    all_green = True
    summary = []

    for report_name, rows in expected.items():
        eid = el_by_name.get(report_name)
        if not eid:
            raise SystemExit(f"no workbook element named {report_name!r}; "
                             f"have {list(el_by_name)}")
        csv_text = export_element(args.workbook_id, eid)
        open(os.path.join(args.save_csv_dir,
                          report_name.replace(" ", "_") + ".csv"), "w").write(csv_text)

        rdr = csv.DictReader(io.StringIO(csv_text))
        n_keys = len(rows[0]["keys"])
        key_cols = key_cols_by_report.get(report_name) or rdr.fieldnames[:n_keys]
        missing_keys = [k for k in key_cols if k not in rdr.fieldnames]
        if missing_keys:
            raise SystemExit(f"{report_name}: key columns {missing_keys} not in "
                             f"export ({rdr.fieldnames})")
        metric_names = list(rows[0]["values"].keys())

        # Sigma rows keyed by the tuple of key-column values (as strings)
        sigma = {}
        for r in rdr:
            key = tuple(str(r[k]).strip() for k in key_cols)
            # normalize numeric-looking keys like "2024.0" or 2024 -> "2024"
            key = tuple(k[:-2] if k.endswith(".0") else k for k in key)
            sigma[key] = r

        matched, mismatches = 0, []
        for row in rows:
            key = tuple(str(k) for k in row["keys"])
            srow = sigma.get(key)
            if srow is None:
                mismatches.append(f"MISSING row {key}")
                continue
            ok = True
            for m, exp in row["values"].items():
                col = next((c for c in rdr.fieldnames if c == m), None)
                if col is None:
                    mismatches.append(f"{key}: metric column {m!r} not in export "
                                      f"({rdr.fieldnames})")
                    ok = False
                    continue
                got = parse_number(srow[col])
                if got is None:
                    mismatches.append(f"{key}: {m} is null (expected {exp})")
                    ok = False
                    continue
                tol = TOLERANT.get(m)
                if tol is not None:
                    if abs(got - exp) > tol * max(abs(exp), 1e-12):
                        mismatches.append(f"{key}: {m} got {got!r} expected {exp!r} "
                                          f"(rel diff {abs(got-exp)/abs(exp):.2e})")
                        ok = False
                else:
                    if abs(got - exp) > 1e-9:
                        mismatches.append(f"{key}: {m} got {got!r} expected {exp!r}")
                        ok = False
            if ok:
                matched += 1

        extra = len(sigma) - len(rows)
        status = "PASS" if (matched == len(rows) and not mismatches) else "FAIL"
        if status == "FAIL":
            all_green = False
        summary.append((report_name, matched, len(rows), extra, status))
        lines.append(f"## {report_name} — {status}")
        lines.append("")
        lines.append(f"- Rows matched: **{matched} / {len(rows)}**")
        lines.append(f"- Sigma rows: {len(sigma)}"
                     + (f" ({extra:+d} vs expected)" if extra else ""))
        lines.append(f"- Metrics compared: {', '.join(metric_names)}")
        if mismatches:
            lines.append("- Mismatches:")
            for mm in mismatches[:50]:
                lines.append(f"  - {mm}")
        lines.append("")

    lines.append("## Summary")
    lines.append("")
    lines.append("| Report | Matched / Total | Status |")
    lines.append("|---|---|---|")
    for name, m, t, _x, st_ in summary:
        lines.append(f"| {name} | {m} / {t} | {st_} |")
    lines.append("")
    lines.append("Tolerances: money and counts exact; Profit Margin Pct relative 1e-6.")

    open(args.report, "w").write("\n".join(lines) + "\n")

    # gate sentinels (contract: scripts/assert-phase6-ran.rb gate 1 reads
    # parity-final.json; gates 3/4/6/7 resolve the workbook via wb-ids.json)
    outdir = os.path.dirname(os.path.abspath(args.report))
    n_pass = sum(1 for _n, m, t, _x, st_ in summary
                 if st_ == "PASS" and m == t)
    json.dump({
        "status": "PASS" if all_green else "FAIL",
        "mode": "live",
        "charts_total": len(summary),
        "charts_pass": n_pass,
        "fail_names": [n for n, _m, _t, _x, st_ in summary if st_ != "PASS"],
        "generated_by": "verify_parity.py",
    }, open(os.path.join(outdir, "parity-final.json"), "w"), indent=1)
    json.dump({"workbookId": args.workbook_id},
              open(os.path.join(outdir, "wb-ids.json"), "w"), indent=1)

    for name, m, t, _x, st_ in summary:
        print(f"{st_}: {name} {m}/{t}")
    print(f"report -> {args.report} (+ parity-final.json, wb-ids.json)")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
