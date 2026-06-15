#!/usr/bin/env python3
"""Offline path: parse a Looker `.dashboard.lookml` file into the normalized
Dashboard contract (refs/dashboard-contract.md). Dashboard LookML is YAML.

Live path (later): a fetch-looker-dashboard script hits the Looker REST API
(`GET /dashboards/{id}` + `dashboard_layouts`) and emits the SAME contract, so
the workbook builder stays source-agnostic.

Usage:
    python3 parse_lookml_dashboard.py <file.dashboard.lookml> [--out contract.json]
"""
import argparse, json, sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


def norm_reflines(viz):
    """Looker `reference_lines:` (chart viz config) -> normalized list. Each
    Looker entry is {reference_type, line_value|value|range_start/range_end,
    label, color, line_width}. We only port single-value lines (reference_type
    'line'/'min'/'max'/'average'/'median' with a numeric/expr value or a field
    `value_format`-style anchor); ranges/bands are flagged with show:False so
    the builder can warn rather than emit a wrong mark. Value can be a literal
    number, a field ref, or a Looker formula string — kept raw for the builder
    to wrap as a Sigma formula."""
    out = []
    for r in (viz.get("reference_lines") or []):
        if not isinstance(r, dict):
            continue
        rtype = (r.get("reference_type") or "line").lower()
        val = r.get("line_value")
        if val is None:
            val = r.get("value")
        out.append({
            "referenceType": rtype,
            "value": val,                       # number | field ref | expr | None
            "rangeStart": r.get("range_start"),
            "rangeEnd": r.get("range_end"),
            "label": r.get("label"),
            "color": r.get("color"),
            "lineWidth": r.get("line_width"),
        })
    return out


def norm_color(viz):
    """Looker color encoding (chart viz config) -> normalized dict for the
    builder. Captures the three Looker color knobs:
      * series_colors  {seriesName: "#hex"} — explicit per-series colors
      * colors         ["#hex", ...]        — categorical palette
      * color_application {collection_id, palette_id, options:{steps,reverse}}
                                            — continuous / by-value scheme
    The builder decides by-measure vs by-category from the tile shape; this just
    surfaces what Looker declared so the palette/scheme can be reproduced."""
    ca = viz.get("color_application") if isinstance(viz.get("color_application"), dict) else {}
    opts = ca.get("options") if isinstance(ca.get("options"), dict) else {}
    return {
        "seriesColors": viz.get("series_colors") if isinstance(viz.get("series_colors"), dict) else {},
        "palette": [c for c in (viz.get("colors") or []) if isinstance(c, str)],
        "colorApplication": {
            "collectionId": ca.get("collection_id"),
            "paletteId": ca.get("palette_id"),
            "custom": ca.get("custom") if isinstance(ca.get("custom"), dict) else None,
            "reverse": bool(opts.get("reverse")),
            "steps": opts.get("steps"),
        } if ca else None,
    }


def norm_element(el):
    return {
        "name": el.get("name") or el.get("title"),
        "title": el.get("title"),
        "tileType": el.get("type"),
        "model": el.get("model"),
        "explore": el.get("explore"),
        "fields": el.get("fields") or [],
        "pivots": el.get("pivots") or [],
        # tile-level hard filters {field: expr}
        "filters": el.get("filters") or {},
        "sorts": el.get("sorts") or [],
        "limit": el.get("limit"),
        # which dashboard filters this tile obeys: {FilterName: field}
        "listen": el.get("listen") or {},
        # client-side table calcs / custom measures → workbook formulas
        "dynamicFields": el.get("dynamic_fields") or [],
        "noteText": el.get("note_text"),
        "subtitleText": el.get("subtitle_text"),
        # single_value comparison (Sigma KPI spec has no comparison slot → warn)
        "showComparison": bool(el.get("show_comparison")),
        "comparisonType": el.get("comparison_type"),
        # chart reference lines (vis config) → Sigma refMarks
        "referenceLines": norm_reflines(el),
        # color encoding (series_colors / colors / color_application) → Sigma color channel
        "color": norm_color(el),
        # newspaper grid units (LookML uses `col`; API uses `column` — normalize to col)
        "layout": {
            "row": el.get("row", 0), "col": el.get("col", 0),
            "width": el.get("width", 8), "height": el.get("height", 6),
        },
    }


def norm_filter(f):
    return {
        "name": f.get("name"),
        "title": f.get("title") or f.get("name"),
        "type": f.get("type"),                # date_filter | field_filter | ...
        "model": f.get("model"),
        "explore": f.get("explore"),
        "field": f.get("field"),              # view.field this filter binds to
        "defaultValue": f.get("default_value"),
        "allowMultiple": bool(f.get("allow_multiple_values")),
        "listensToFilters": f.get("listens_to_filters") or [],
    }


def parse(path):
    with open(path) as fh:
        docs = yaml.safe_load(fh)
    # A .dashboard.lookml is a YAML list of dashboards (usually one).
    if isinstance(docs, dict):
        docs = [docs]
    out = []
    for d in docs:
        out.append({
            "id": d.get("dashboard"),
            "title": d.get("title"),
            "layoutMode": d.get("layout", "newspaper"),
            "source": "lookml",
            "lookmlLinkId": None,
            "filters": [norm_filter(f) for f in (d.get("filters") or [])],
            "elements": [norm_element(e) for e in (d.get("elements") or [])],
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--out")
    a = ap.parse_args()
    dashboards = parse(a.file)
    js = json.dumps(dashboards if len(dashboards) > 1 else dashboards[0], indent=2)
    if a.out:
        open(a.out, "w").write(js)
        d0 = dashboards[0]
        print(f"wrote {a.out}: {d0['title']} — {len(d0['elements'])} elements, "
              f"{len(d0['filters'])} filters, layout={d0['layoutMode']}")
    else:
        print(js)


if __name__ == "__main__":
    main()
