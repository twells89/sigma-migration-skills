#!/usr/bin/env python3
"""Rewrite a Sigma workbook spec so it can be created in a DIFFERENT org.

Input  : a spec exactly as returned by GET /v2/workbooks/{id}/spec (YAML or JSON).
Output : a create body {name, folderId, description?, document} for
         POST /v2/workbooks/spec, plus a JSON report.

Run with no --map-* flags first (audit mode): the report lists every org-scoped
reference that needs a decision, and the tool exits non-zero if any remain
unmapped. Supply the mappings, re-run, then POST.

Stdlib only. No network. Portable (no shelling out).
"""

import argparse
import base64
import collections
import json
import mimetypes
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML required: python3 -m pip install pyyaml")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def walk(node, fn):
    """Depth-first visit of every dict in the tree, parents before children."""
    if isinstance(node, dict):
        fn(node)
        for v in list(node.values()):
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def load_spec(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def parse_pairs(items, sep="="):
    out = {}
    for raw in items:
        if sep not in raw:
            sys.exit(f"bad mapping {raw!r}: expected LEFT{sep}RIGHT")
        left, right = raw.split(sep, 1)
        out[left.strip()] = right.strip()
    return out


# --------------------------------------------------------------------------
# rewrite steps
# --------------------------------------------------------------------------
def remap_connections(doc, cmap, counts):
    """Repoint every connectionId at the target org's connection."""
    def visit(d):
        cid = d.get("connectionId")
        if isinstance(cid, str) and cid in cmap:
            d["connectionId"] = cmap[cid]
            counts["connectionId"] += 1
    walk(doc, visit)


def strip_base_grouping(doc, counts):
    """GET emits the implicit ungrouped root as groupingId: "base"; create
    rejects it ("Grouping not found: 'base'"). The schema is explicit: omit
    groupingId to read ungrouped (base) data."""
    def visit(d):
        if d.get("groupingId") == "base":
            del d["groupingId"]
            counts["groupingId_base_stripped"] += 1
    walk(doc, visit)


def inline_images(doc, imap, counts):
    """source.kind 'upload' is a reference to an image already uploaded into the
    SOURCE org. The key is org-scoped, so POSTing it cross-org hard-fails with
    'Image upload does not belong to this organization', and the spec API cannot
    create a new upload. Rehost as kind 'url' — a data URI travels in-spec."""
    def visit(d):
        if d.get("kind") == "upload" and d.get("key") in imap:
            url = imap[d["key"]]
            d.clear()
            d["kind"] = "url"
            d["url"] = url
            counts["images_inlined"] += 1
    walk(doc, visit)


def repair_write_columns(doc, repairs, counts, findings):
    """A source org can carry dangling action->column references that its own
    runtime tolerates. Create-validation rejects them:
    'sheet: <elementId>(internal), bad column: <columnId>'."""
    colmap = {e["id"]: {c["id"]: c.get("name") for c in (e.get("columns") or [])}
              for e in doc.get("elements", []) if isinstance(e, dict) and "id" in e}

    def visit(d):
        if d.get("effect") not in ("insert-rows", "update-rows"):
            return
        values = d.get("values")
        if not isinstance(values, dict):
            return
        table = d.get("table")
        known = colmap.get(table, {})
        for key in list(values.keys()):
            if key in known:
                continue
            real = repairs.get((table, key))
            if real and real in known:
                values[real] = values.pop(key)
                counts["stale_write_columns_repaired"] += 1
            else:
                findings.append({
                    "table": table,
                    "staleColumn": key,
                    "validColumns": known,
                    "fix": f"--map-column {table}:{key}=<REAL_COLUMN_ID>",
                })
    walk(doc, visit)


ROW_RE = re.compile(r'gridRow="(\d+) / (\d+)"')
CONTAINER_RE = re.compile(r"<Container\b([^>]*)>(.*?)</Container>", re.S)
PAGE_RE = re.compile(r"(<Page\b[^>]*>)(.*?)(</Page>)", re.S)
ELEMENT_RE = re.compile(r'<Element\s[^>]*gridRow="([^"]+)"[^>]*/>')


def normalize_layout(doc, counts):
    """On create, Sigma EXPANDS a <Container> whose declared gridRow end is
    smaller than its children's extent (it never shrinks an oversized one).
    A sibling <Element> that shared the container's ORIGINAL span then no longer
    matches the expanded container and renders collapsed — a full-height image
    becomes a thin strip. Pre-apply the expansion so what we POST is already
    self-consistent, and carry the siblings with it."""
    layout = doc.get("layout")
    if not layout:
        return

    def fix_page(page_match):
        body = page_match.group(2)
        for cont in list(CONTAINER_RE.finditer(body)):
            attrs, inner = cont.group(1), cont.group(2)
            declared = ROW_RE.search(attrs)
            if not declared:
                continue
            start, end = int(declared.group(1)), int(declared.group(2))
            child_ends = [int(m.group(2)) for m in ROW_RE.finditer(inner)]
            if not child_ends or max(child_ends) <= end:
                continue
            old_span = f"{start} / {end}"
            new_span = f"{start} / {max(child_ends)}"
            new_attrs = attrs.replace(f'gridRow="{old_span}"',
                                      f'gridRow="{new_span}"', 1)
            new_cont = f"<Container{new_attrs}>{inner}</Container>"
            body = body.replace(cont.group(0), new_cont, 1)
            counts["layout_containers_expanded"] += 1

            def realign(m):
                if m.group(1) != old_span:
                    return m.group(0)
                counts["layout_siblings_realigned"] += 1
                return m.group(0).replace(f'gridRow="{old_span}"',
                                          f'gridRow="{new_span}"', 1)

            head, _, tail = body.partition(new_cont)
            body = (ELEMENT_RE.sub(realign, head) + new_cont
                    + ELEMENT_RE.sub(realign, tail))
        return page_match.group(1) + body + page_match.group(3)

    doc["layout"] = PAGE_RE.sub(fix_page, layout)


# --------------------------------------------------------------------------
# audit
# --------------------------------------------------------------------------
def orphaned_interactivity(doc):
    """Interactivity the spec DECLARES but never wires up.

    `GET /v2/workbooks/{id}/spec` does not always return a workbook's full
    action surface — buttons can come back as presentation-only, with their
    conditional logic omitted entirely (no stub, no marker). A port then
    faithfully reproduces a workbook that looks right and does nothing.

    Nothing here is a port defect: it is a read-side gap you inherit. But it is
    invisible unless you look for structures with no reachable writer/opener,
    so flag the three that give it away."""
    elements = [e for e in doc.get("elements", []) if isinstance(e, dict)]
    effects = []

    def collect(d):
        if d.get("effect"):
            effects.append(d)
    walk(doc, collect)

    opened = {e.get("overlayId") for e in effects if e.get("effect") == "open-overlay"}
    written = {e.get("table") for e in effects
               if e.get("effect") in ("insert-rows", "update-rows", "delete-rows")}

    overlays = [o.get("id") for o in doc.get("overlays", []) if isinstance(o, dict)]
    return {
        "overlays_never_opened": sorted(o for o in overlays if o not in opened),
        "input_tables_never_written": sorted(
            e["id"] for e in elements
            if e.get("kind") == "input-table" and e["id"] not in written),
        "buttons_with_no_actions": sorted(
            e["id"] for e in elements
            if e.get("kind") == "button" and not e.get("actions")),
        "effect_counts": dict(sorted(collections.Counter(
            e["effect"] for e in effects).items())),
    }


def audit(doc, cmap, imap):
    """Everything org-scoped that still needs an operator decision."""
    conns, uploads, input_tables = set(), set(), []

    def visit(d):
        cid = d.get("connectionId")
        if isinstance(cid, str):
            conns.add(cid)
        if d.get("kind") == "upload" and "key" in d:
            uploads.add(d["key"])
    walk(doc, visit)

    for e in doc.get("elements", []):
        if isinstance(e, dict) and e.get("kind") == "input-table":
            input_tables.append({
                "elementId": e.get("id"),
                "name": e.get("name"),
                "columns": [c.get("name") for c in (e.get("columns") or [])],
            })

    target_conns = set(cmap.values())
    return {
        "unmapped_connectionIds": sorted(c for c in conns if c not in target_conns),
        "unmapped_image_uploads": sorted(u for u in uploads if u not in imap),
        "input_tables_needing_data": input_tables,
    }


# --------------------------------------------------------------------------
def build_image_map(path):
    imap = {}
    base = os.path.dirname(os.path.abspath(path))
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                sys.exit(f"image-map needs TAB-separated key<TAB>path: {line!r}")
            key, img = parts[0].strip(), parts[1].strip()
            img = img if os.path.isabs(img) else os.path.join(base, img)
            if not os.path.exists(img):
                sys.exit(f"image-map: file not found: {img}")
            mime = mimetypes.guess_type(img)[0] or "image/png"
            with open(img, "rb") as ifh:
                b64 = base64.b64encode(ifh.read()).decode("ascii")
            imap[key] = f"data:{mime};base64,{b64}"
    return imap


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src-spec", required=True,
                    help="spec from GET /v2/workbooks/{id}/spec (YAML or JSON)")
    ap.add_argument("--out", required=True, help="create body to write (YAML)")
    ap.add_argument("--report", required=True, help="JSON report to write")
    ap.add_argument("--folder-id", help="target folder (required unless --audit-only)")
    ap.add_argument("--name", help="workbook name (default: source name)")
    ap.add_argument("--map-connection", action="append", default=[],
                    metavar="SRC=DST", help="repeatable")
    ap.add_argument("--map-column", action="append", default=[],
                    metavar="TABLE_ELEMENT_ID:STALE=REAL", help="repeatable")
    ap.add_argument("--image-map", metavar="TSV",
                    help="lines of: upload_key<TAB>local_image_path")
    ap.add_argument("--audit-only", action="store_true",
                    help="report what needs mapping; write no create body")
    args = ap.parse_args()

    src = load_spec(args.src_spec)
    if "document" not in src:
        sys.exit("spec has no top-level 'document' — is this a workbook spec?")
    doc = src["document"]

    cmap = parse_pairs(args.map_connection)
    imap = build_image_map(args.image_map) if args.image_map else {}

    repairs = {}
    for raw in args.map_column:
        left, real = raw.split("=", 1)
        if ":" not in left:
            sys.exit(f"bad --map-column {raw!r}: expected TABLE:STALE=REAL")
        table, stale = left.split(":", 1)
        repairs[(table.strip(), stale.strip())] = real.strip()

    counts = dict(connectionId=0, groupingId_base_stripped=0, images_inlined=0,
                  stale_write_columns_repaired=0, layout_containers_expanded=0,
                  layout_siblings_realigned=0)
    stale_findings = []

    remap_connections(doc, cmap, counts)
    strip_base_grouping(doc, counts)
    inline_images(doc, imap, counts)
    repair_write_columns(doc, repairs, counts, stale_findings)
    normalize_layout(doc, counts)

    blockers = audit(doc, cmap, imap)
    blockers["unrepaired_stale_write_columns"] = stale_findings
    warnings = orphaned_interactivity(doc)

    report = {
        "source": {"workbookId": src.get("workbookId"), "name": src.get("name"),
                   "documentVersion": src.get("documentVersion")},
        "rewrites": counts,
        "connection_map": cmap,
        "blockers": blockers,
        "warnings_inherited_from_source": warnings,
        "totals": {"elements": len(doc.get("elements", [])),
                   "pages": len(doc.get("pages", []))},
    }

    hard = (blockers["unmapped_connectionIds"]
            or blockers["unmapped_image_uploads"]
            or blockers["unrepaired_stale_write_columns"])

    if not args.audit_only and not hard:
        if not args.folder_id:
            sys.exit("--folder-id is required to write a create body")
        body = {"name": args.name or src.get("name"),
                "folderId": args.folder_id, "document": doc}
        if src.get("description"):
            body["description"] = src["description"]
        with open(args.out, "w", encoding="utf-8") as fh:
            yaml.safe_dump(body, fh, sort_keys=False, width=10 ** 6,
                           default_flow_style=False, allow_unicode=True)
        report["wrote"] = args.out

    with open(args.report, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))

    if hard:
        print("\nUNRESOLVED — supply the mappings above and re-run.",
              file=sys.stderr)
        return 2
    if args.audit_only:
        print("\nAudit clean. Re-run without --audit-only to write the create body.",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
