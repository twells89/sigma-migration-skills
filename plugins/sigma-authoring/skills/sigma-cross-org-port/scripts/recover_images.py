#!/usr/bin/env python3
"""Recover the bytes behind a workbook's org-scoped image uploads.

`source.kind: upload` keys are opaque handles into the SOURCE org's storage —
the OpenAPI says so outright ("not a fetchable URL") and there is no public
endpoint that serves them. But a PDF export embeds the original rasters
losslessly, so exporting the workbook and pulling the images out of the PDF
recovers them.

    plan  --spec S.yaml
        Which pages (and overlay pages) hold image elements, in export order.
        Overlay/modal pages do NOT appear in a whole-workbook export — export
        each one separately with {"pageId": "<overlayPageId>"}.

    map   --spec S.yaml --pdf W.pdf --images DIR --out map.tsv
        Pair extracted files with upload keys by (page order, element order).
        Emits the TSV that port_workbook.py --image-map consumes.

    shrink --map map.tsv --out-dir DIR [--max-px 1400] [--quality 82]
        Downscale in place-ish (needs Pillow). Data URIs inflate ~4/3 in
        base64; full-resolution art can push the spec past a POSTable size.

`plan` and `map` are stdlib-only. `map` needs poppler's `pdfimages` on PATH
(macOS: brew install poppler; Debian/Ubuntu: apt install poppler-utils;
Windows: choco install poppler). `shrink` needs Pillow.

ALWAYS eyeball the images against the source render before trusting the map:
charts, point maps and region maps also embed rasters, so a page holding both a
map and an image element is inherently ambiguous — `map` flags those rows.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML required: python3 -m pip install pyyaml")

PAGE_RE = re.compile(r'<Page\b[^>]*id="([^"]+)"[^>]*>(.*?)</Page>', re.S)
ELEMENT_ID_RE = re.compile(r'elementId="([^"]+)"')
# raster-embedding element kinds that are NOT image uploads
RASTER_KINDS = {"point-map", "region-map", "geography-map"}


def load(spec_path):
    with open(spec_path, encoding="utf-8") as fh:
        spec = yaml.safe_load(fh)
    return spec["document"] if "document" in spec else spec


def page_plan(doc):
    """[{pageId, name, kind: page|overlay, visible, images:[elementId], rasters:[kind]}]
    in layout order — which is the order a whole-workbook export paginates in."""
    pages = {p["id"]: p for p in doc.get("pages", []) if isinstance(p, dict)}
    overlays = {o["id"] for o in doc.get("overlays", []) if isinstance(o, dict)}
    elements = {e["id"]: e for e in doc.get("elements", [])
                if isinstance(e, dict) and "id" in e}
    uploads = {eid: e["source"]["key"] for eid, e in elements.items()
               if isinstance(e.get("source"), dict)
               and e["source"].get("kind") == "upload"}

    out = []
    for pid, body in PAGE_RE.findall(doc.get("layout") or ""):
        ids = ELEMENT_ID_RE.findall(body)
        meta = pages.get(pid)
        out.append({
            "pageId": pid,
            "name": (meta or {}).get("name") or f"(overlay {pid})",
            "kind": "overlay" if pid in overlays else "page",
            "visible": bool(meta) and (meta.get("visibility") != "hidden"),
            "images": [i for i in ids if i in uploads],
            "keys": [uploads[i] for i in ids if i in uploads],
            "rasters": sorted({elements[i]["kind"] for i in ids
                               if i in elements
                               and elements[i].get("kind") in RASTER_KINDS}),
        })
    return out


def cmd_plan(args):
    plan = page_plan(load(args.spec))
    exported = [p for p in plan if p["kind"] == "page" and p["visible"]]
    print("Whole-workbook PDF export paginates these pages, in this order:")
    for i, p in enumerate(exported, 1):
        extra = f"  [also embeds: {', '.join(p['rasters'])}]" if p["rasters"] else ""
        print(f"  pdf page {i:>2}  {p['name']!r}  images={len(p['images'])}{extra}")
    hidden = [p for p in plan if p["kind"] == "page" and not p["visible"]]
    overlay = [p for p in plan if p["kind"] == "overlay"]
    if hidden:
        print("\nHIDDEN pages (absent from the export; export by pageId if they hold images):")
        for p in hidden:
            print(f"  {p['name']!r} pageId={p['pageId']} images={len(p['images'])}")
    if overlay:
        print("\nOVERLAY pages (absent from a whole-workbook export — export EACH "
              'separately with {"pageId": "<id>"}):')
        for p in overlay:
            print(f"  pageId={p['pageId']} images={len(p['images'])} keys={p['keys']}")
    total = sum(len(p["images"]) for p in plan)
    print(f"\n{total} image upload(s) to recover.")
    return 0


def pdfimages_list(pdf):
    exe = shutil.which("pdfimages")
    if not exe:
        sys.exit("pdfimages not found on PATH — install poppler "
                 "(macOS: brew install poppler; Debian: apt install poppler-utils)")
    txt = subprocess.run([exe, "-list", pdf], capture_output=True, text=True,
                         check=True).stdout
    rows = []
    for line in txt.splitlines()[2:]:
        f = line.split()
        if len(f) < 4 or not f[0].isdigit():
            continue
        rows.append({"page": int(f[0]), "num": int(f[1]), "type": f[2],
                     "width": int(f[3]), "height": int(f[4])})
    return rows


def cmd_map(args):
    doc = load(args.spec)
    plan = page_plan(doc)
    exported = [p for p in plan if p["kind"] == "page" and p["visible"]]

    os.makedirs(args.images, exist_ok=True)
    exe = shutil.which("pdfimages")
    if not exe:
        sys.exit("pdfimages not found on PATH — install poppler")
    subprocess.run([exe, "-all", "-p", args.pdf, os.path.join(args.images, "img")],
                   check=True)

    # only real content rasters: drop soft masks and tiny UI chrome
    rows = [r for r in pdfimages_list(args.pdf)
            if r["type"] == "image" and r["width"] >= args.min_px
            and r["height"] >= args.min_px]

    by_page = {}
    for r in rows:
        by_page.setdefault(r["page"], []).append(r)

    extracted = {}
    for name in os.listdir(args.images):
        m = re.match(r"img-(\d+)-(\d+)\.(\w+)$", name)
        if m:
            extracted[(int(m.group(1)), int(m.group(2)))] = name

    lines, notes, unmatched = [], [], []
    for idx, page in enumerate(exported, 1):
        if not page["images"]:
            continue
        cands = by_page.get(idx, [])
        if page["rasters"]:
            notes.append(f"page {idx} {page['name']!r} also has {page['rasters']} — "
                         "verify visually, the pairing may be off by one")
        if len(cands) != len(page["images"]):
            unmatched.append(f"page {idx} {page['name']!r}: {len(page['images'])} "
                             f"image element(s) but {len(cands)} raster(s) found")
        for key, cand in zip(page["keys"], cands):
            fname = extracted.get((cand["page"], cand["num"]))
            if not fname:
                unmatched.append(f"page {idx}: no extracted file for raster "
                                 f"{cand['num']}")
                continue
            lines.append(f"{key}\t{fname}\t{page['name']} "
                         f"({cand['width']}x{cand['height']})")

    covered = {l.split("\t")[0] for l in lines}
    for page in plan:
        for key in page["keys"]:
            if key not in covered:
                unmatched.append(f"NOT MAPPED: {key} (page {page['name']!r}, "
                                 f"kind={page['kind']}) — export this page by pageId")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("# upload_key\tlocal_file\tprovenance\n")
        for l in lines:
            fh.write(l + "\n")

    print(f"wrote {args.out} with {len(lines)} mapping(s)")
    for n in notes:
        print("  NOTE:", n)
    for u in unmatched:
        print("  GAP :", u)
    print("\nVERIFY each file against the source render before porting.")
    return 1 if unmatched else 0


def cmd_shrink(args):
    try:
        from PIL import Image
    except ImportError:
        sys.exit("Pillow required for shrink: python3 -m pip install pillow")
    os.makedirs(args.out_dir, exist_ok=True)
    base = os.path.dirname(os.path.abspath(args.map))
    total = 0
    out_lines = []
    with open(args.map, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            key, fname = parts[0], parts[1]
            src = fname if os.path.isabs(fname) else os.path.join(base, fname)
            im = Image.open(src)
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            im.thumbnail((args.max_px, args.max_px))
            dest = os.path.join(args.out_dir,
                                os.path.splitext(os.path.basename(src))[0] + ".jpg")
            im.save(dest, "JPEG", quality=args.quality, optimize=True)
            size = os.path.getsize(dest)
            total += size
            rel = os.path.relpath(dest, base)
            out_lines.append("\t".join([key, rel] + parts[2:]))
            print(f"  {os.path.basename(src)} -> {rel}  {size} bytes")
    with open(args.map, "w", encoding="utf-8") as fh:
        fh.write("# upload_key\tlocal_file\tprovenance\n")
        for l in out_lines:
            fh.write(l + "\n")
    print(f"total {total} bytes (~{total * 4 // 3} as base64 in the spec)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan"); p.add_argument("--spec", required=True)
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("map")
    p.add_argument("--spec", required=True)
    p.add_argument("--pdf", required=True)
    p.add_argument("--images", required=True, help="dir for extracted files")
    p.add_argument("--out", required=True, help="TSV to write")
    p.add_argument("--min-px", type=int, default=64,
                   help="ignore rasters smaller than this (UI chrome)")
    p.set_defaults(fn=cmd_map)

    p = sub.add_parser("shrink")
    p.add_argument("--map", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--max-px", type=int, default=1400)
    p.add_argument("--quality", type=int, default=82)
    p.set_defaults(fn=cmd_shrink)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
