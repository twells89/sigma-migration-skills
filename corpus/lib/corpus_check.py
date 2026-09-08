#!/usr/bin/env python3
"""Corpus helper: normalize converter output, summarize structure, check cases.

Subcommands
  normalize <in.json> [<out.json>]   Rewrite generated ids to stable positional
                                     tokens so reconverted output byte-diffs
                                     cleanly against the stored golden.
  summarize <golden.json>            Print the structure summary (counts/names).
  check <case-dir>                   Validate one corpus case:
                                       - every artifact in MANIFEST expectations
                                         exists and parses (json/xml/yaml/text)
                                       - every golden/*.json matches the
                                         expectation counts + element names
  diff <golden.json> <converted.json>  Normalize the fresh converter output and
                                     byte-diff it against the stored golden.

No credentials, no network. Pure-stdlib (yaml artifacts get a structural
fallback check when PyYAML is missing).
"""
import json
import os
import re
import sys

# ---------------------------------------------------------------- normalize

ID_KEYS = {"id", "elementId", "targetElementId", "sourceColumnId",
           "targetColumnId", "columnId", "dataModelId", "folderId"}
INODE_RE = re.compile(r"^inode-[A-Za-z0-9]{10,30}(/.+)?$")
NORMALIZED_RE = re.compile(r"^(id\d{4}|inode-NORM\d{4}(/.+)?)$")


def _collect_ids(node, found):
    """First pass: every string value under an id-ish key registers a token."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ID_KEYS and isinstance(v, str) and v not in found:
                found[v] = None
            _collect_ids(v, found)
    elif isinstance(node, list):
        for v in node:
            _collect_ids(v, found)


def _build_mapping(found):
    mapping = {}
    n = 0
    for old in found:  # dict preserves first-seen order -> deterministic
        if NORMALIZED_RE.match(old):  # idempotent: already-normalized golden
            mapping[old] = old
            n += 1
            continue
        n += 1
        m = INODE_RE.match(old)
        if m and m.group(1):
            mapping[old] = "inode-NORM%04d%s" % (n, m.group(1))
        elif m:
            mapping[old] = "inode-NORM%04d" % n
        else:
            mapping[old] = "id%04d" % n
    return mapping


def _apply_mapping(node, mapping):
    if isinstance(node, dict):
        return {k: _apply_mapping(v, mapping) for k, v in node.items()}
    if isinstance(node, list):
        return [_apply_mapping(v, mapping) for v in node]
    if isinstance(node, str) and node in mapping:
        return mapping[node]
    return node


def normalize(doc):
    """Replace generated ids (random per converter run) with positional tokens."""
    found = {}
    _collect_ids(doc, found)
    return _apply_mapping(doc, _build_mapping(found))


# ---------------------------------------------------------------- summarize

def _spec_root(doc):
    """Converter results wrap the spec: {sigmaDataModel|model|workbook, stats, warnings}."""
    for key in ("sigmaDataModel", "dataModel", "model", "workbook", "spec"):
        if isinstance(doc, dict) and isinstance(doc.get(key), dict):
            return doc[key]
    return doc


def summarize(doc):
    """Counts + names for a Sigma data-model or workbook spec (pages/elements)."""
    spec = _spec_root(doc)
    document = spec.get("document") if isinstance(spec, dict) else None
    workbook = document if isinstance(document, dict) else spec
    out = {"elements": 0, "columns": 0, "metrics": 0, "relationships": 0,
           "pages": 0, "element_names": [], "element_kinds": {},
           "metric_names": [], "relationship_names": [], "warnings": 0}
    if isinstance(doc, dict) and isinstance(doc.get("warnings"), list):
        out["warnings"] = len(doc["warnings"])
    pages = workbook.get("pages") or []
    out["pages"] = len(pages)
    elements = workbook.get("elements")
    if not isinstance(elements, list):
        # Legacy data-models and pre-release workbooks keep elements per page.
        elements = [
            el
            for page in pages if isinstance(page, dict)
            for el in (page.get("elements") or [])
        ]
    for el in elements:
        out["elements"] += 1
        name = el.get("name")
        if not name and isinstance(el.get("source"), dict):
            path = el["source"].get("path")
            if isinstance(path, list) and path:
                name = path[-1]
        out["element_names"].append(name or el.get("id", "?"))
        kind = el.get("kind", "?")
        out["element_kinds"][kind] = out["element_kinds"].get(kind, 0) + 1
        out["columns"] += len(el.get("columns") or [])
        for m in el.get("metrics") or []:
            out["metrics"] += 1
            out["metric_names"].append(m.get("name"))
        for r in el.get("relationships") or []:
            out["relationships"] += 1
            out["relationship_names"].append(r.get("name"))
    # top-level metrics/relationships (some spec shapes)
    for m in workbook.get("metrics") or []:
        out["metrics"] += 1
        out["metric_names"].append(m.get("name"))
    for r in workbook.get("relationships") or []:
        out["relationships"] += 1
        out["relationship_names"].append(r.get("name"))
    return out


def rejected_layout_tags(doc):
    """Return legacy workbook layout tags that the live API rejects."""
    spec = _spec_root(doc)
    document = spec.get("document") if isinstance(spec, dict) else None
    workbook = document if isinstance(document, dict) else spec
    layout = workbook.get("layout") if isinstance(workbook, dict) else None
    if not isinstance(layout, str):
        return []
    return sorted(set(re.findall(r"</?(LayoutElement|GridContainer)\b", layout)))


# -------------------------------------------------------------------- check

def _read_manifest_expectations(case_dir):
    path = os.path.join(case_dir, "MANIFEST.md")
    if not os.path.exists(path):
        return None, "MANIFEST.md missing"
    text = open(path, encoding="utf-8").read()
    m = re.search(r"```json\s*\n(.*?)```", text, re.S)
    if not m:
        return None, "MANIFEST.md has no ```json expectations block"
    try:
        return json.loads(m.group(1)), None
    except ValueError as e:
        return None, "expectations block is not valid JSON: %s" % e


def _check_artifact(case_dir, spec):
    if isinstance(spec, str):
        spec = {"path": spec}
    rel = spec["path"]
    fmt = spec.get("format", "")
    path = os.path.normpath(os.path.join(case_dir, rel))
    if not os.path.exists(path):
        return False, "%s: MISSING" % rel
    if not fmt:
        ext = os.path.splitext(path)[1].lower()
        fmt = {".json": "json", ".bim": "json", ".twb": "xml", ".xml": "xml",
               ".tml": "yaml", ".pbir": "json"}.get(ext, "text")
    try:
        if fmt == "json":
            json.load(open(path, encoding="utf-8"))
        elif fmt == "xml":
            import xml.etree.ElementTree as ET
            ET.parse(path)
        elif fmt == "yaml":
            try:
                import yaml
                yaml.safe_load(open(path, encoding="utf-8"))
            except ImportError:
                # structural fallback: non-empty, first non-comment line has a key
                lines = [l for l in open(path, encoding="utf-8")
                         if l.strip() and not l.lstrip().startswith("#")]
                if not lines or ":" not in lines[0]:
                    return False, "%s: does not look like YAML" % rel
        else:  # text / lookml — just non-empty
            if not open(path, encoding="utf-8").read().strip():
                return False, "%s: empty" % rel
    except Exception as e:  # noqa: BLE001 - report any parse failure
        return False, "%s: parse failed (%s)" % (rel, e)
    return True, "%s: ok (%s)" % (rel, fmt)


def _check_golden(case_dir, fname, expect):
    path = os.path.join(case_dir, "golden", fname)
    if not os.path.exists(path):
        return False, ["golden/%s: MISSING" % fname]
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except ValueError as e:
        return False, ["golden/%s: invalid JSON (%s)" % (fname, e)]
    got = summarize(doc)
    msgs, ok = [], True
    legacy_tags = rejected_layout_tags(doc)
    if legacy_tags:
        ok = False
        msgs.append(
            "golden/%s: rejected legacy layout tag(s): %s; emit Element/Container"
            % (fname, ", ".join(legacy_tags))
        )
    for key in ("pages", "elements", "columns", "metrics", "relationships", "warnings"):
        if key in expect and expect[key] != got[key]:
            ok = False
            msgs.append("golden/%s: %s expected %s, got %s"
                        % (fname, key, expect[key], got[key]))
    for key in ("element_names", "metric_names", "relationship_names"):
        if key in expect and sorted(filter(None, expect[key])) != sorted(filter(None, got[key])):
            ok = False
            msgs.append("golden/%s: %s mismatch\n    expected: %s\n    got:      %s"
                        % (fname, key, sorted(filter(None, expect[key])),
                           sorted(filter(None, got[key]))))
    if ok:
        msgs.append("golden/%s: structure matches (%d elements, %d columns, "
                    "%d metrics, %d relationships, %d warnings)"
                    % (fname, got["elements"], got["columns"], got["metrics"],
                       got["relationships"], got["warnings"]))
    return ok, msgs


def check_case(case_dir):
    """Returns (ok, lines)."""
    lines, ok = [], True
    expect, err = _read_manifest_expectations(case_dir)
    if err:
        return False, ["  FAIL %s" % err]
    art_paths = [a if isinstance(a, str) else a.get("path")
                 for a in expect.get("artifacts", [])]
    for art in expect.get("artifacts", []):
        a_ok, msg = _check_artifact(case_dir, art)
        ok = ok and a_ok
        lines.append(("  ok   " if a_ok else "  FAIL ") + msg)
    # Executable expectations (run by run-corpus.sh, not here — no ruby dep in
    # this stdlib checker): a case that ships checks.sh must LIST it in the
    # expectations artifacts, so the manifest stays the single inventory.
    if os.path.exists(os.path.join(case_dir, "checks.sh")) and "checks.sh" not in art_paths:
        ok = False
        lines.append("  FAIL checks.sh exists but is not listed in the expectations artifacts")
    for fname, gexp in (expect.get("goldens") or {}).items():
        g_ok, msgs = _check_golden(case_dir, fname, gexp)
        ok = ok and g_ok
        for m in msgs:
            lines.append(("  ok   " if g_ok else "  FAIL ") + m)
    if not expect.get("artifacts") and not expect.get("goldens"):
        ok = False
        lines.append("  FAIL expectations block lists no artifacts or goldens")
    return ok, lines


# --------------------------------------------------------------------- main

def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "normalize":
        doc = json.load(open(argv[2], encoding="utf-8"))
        out = json.dumps(normalize(doc), indent=2, ensure_ascii=False) + "\n"
        if len(argv) > 3:
            # newline="\n": text mode would CRLF-translate on Windows, and both
            # the goldens (.gitattributes eol=lf) and cmp-based checks.sh
            # consumers are byte-exact LF.
            open(argv[3], "w", encoding="utf-8", newline="\n").write(out)
        else:
            sys.stdout.write(out)
        return 0
    if cmd == "summarize":
        doc = json.load(open(argv[2], encoding="utf-8"))
        print(json.dumps(summarize(doc), indent=2))
        return 0
    if cmd == "check":
        ok, lines = check_case(argv[2])
        print("\n".join(lines))
        return 0 if ok else 1
    if cmd == "diff":
        golden = json.dumps(normalize(json.load(open(argv[2], encoding="utf-8"))),
                            indent=2, ensure_ascii=False) + "\n"
        fresh = json.dumps(normalize(json.load(open(argv[3], encoding="utf-8"))),
                           indent=2, ensure_ascii=False) + "\n"
        if golden == fresh:
            print("IDENTICAL after id-normalization (byte-stable)")
            return 0
        import difflib
        sys.stdout.writelines(difflib.unified_diff(
            golden.splitlines(True), fresh.splitlines(True),
            fromfile=argv[2], tofile=argv[3]))
        return 1
    print("unknown subcommand: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
