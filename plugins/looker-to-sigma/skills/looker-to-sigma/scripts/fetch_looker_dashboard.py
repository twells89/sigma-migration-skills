#!/usr/bin/env python3
"""Live discovery: Looker `GET /dashboards/{id}` -> the normalized dashboard
contract (refs/dashboard-contract.md). Works for user-defined AND LookML
dashboards (the API returns both as the same shape).

Auth from ~/.looker/looker.ini (client_credentials, API 4.0).

Usage:
  python3 fetch_looker_dashboard.py <dashboard_id> [out.json]
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from configparser import ConfigParser

INI = os.path.expanduser("~/.looker/looker.ini")


def _client():
    c = ConfigParser(); c.read(INI); s = c["Looker"]
    base = s["base_url"].rstrip("/")
    if not base.endswith("/api/4.0"):
        base += "/api/4.0"
    data = urllib.parse.urlencode({"client_id": s["client_id"],
                                   "client_secret": s["client_secret"]}).encode()
    tok = json.load(urllib.request.urlopen(
        urllib.request.Request(base + "/login", data=data, method="POST"), timeout=30))["access_token"]
    return base, tok


def get(path):
    base, tok = get._cache if hasattr(get, "_cache") else (None, None)
    if base is None:
        base, tok = _client(); get._cache = (base, tok)
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def _query_of(el):
    """Return the query dict backing an element (direct query or via result_maker)."""
    if el.get("query"):
        return el["query"]
    rm = el.get("result_maker") or {}
    return rm.get("query") or {}


def _vis_config(el, q):
    """The active vis_config dict (query > result_maker > element)."""
    for src in (q.get("vis_config"), (el.get("result_maker") or {}).get("vis_config"), el.get("vis_config")):
        if isinstance(src, dict):
            return src
    return {}


def _vis_type(el, q):
    for src in (q.get("vis_config"), (el.get("result_maker") or {}).get("vis_config"), el.get("vis_config")):
        if isinstance(src, dict) and src.get("type"):
            return src["type"]
    return el.get("type")  # fallback ("vis"/"text")


def _reflines(vc):
    """vis_config.reference_lines[] -> normalized list (see parse_lookml_dashboard
    .norm_reflines). Looker keys: reference_type, line_value|value, range_start/
    range_end, label, color, line_width."""
    out = []
    for r in (vc.get("reference_lines") or []):
        if not isinstance(r, dict):
            continue
        out.append({
            "referenceType": (r.get("reference_type") or "line").lower(),
            "value": r.get("line_value") if r.get("line_value") is not None else r.get("value"),
            "rangeStart": r.get("range_start"), "rangeEnd": r.get("range_end"),
            "label": r.get("label"), "color": r.get("color"),
            "lineWidth": r.get("line_width"),
        })
    return out


def _color(vc):
    """vis_config color knobs -> normalized dict (series_colors / colors /
    color_application). Mirrors parse_lookml_dashboard.norm_color."""
    ca = vc.get("color_application") if isinstance(vc.get("color_application"), dict) else {}
    opts = ca.get("options") if isinstance(ca.get("options"), dict) else {}
    return {
        "seriesColors": vc.get("series_colors") if isinstance(vc.get("series_colors"), dict) else {},
        "palette": [c for c in (vc.get("colors") or []) if isinstance(c, str)],
        "colorApplication": {
            "collectionId": ca.get("collection_id"), "paletteId": ca.get("palette_id"),
            "custom": ca.get("custom") if isinstance(ca.get("custom"), dict) else None,
            "reverse": bool(opts.get("reverse")), "steps": opts.get("steps"),
        } if ca else None,
    }


def _dyn(df):
    """Looker returns dashboard_element.query.dynamic_fields as a JSON string."""
    if isinstance(df, str):
        try:
            return json.loads(df)
        except Exception:
            return []
    return df or []


def _listen(el):
    """filterName -> field, from result_maker.filterables[].listen."""
    out = {}
    rm = el.get("result_maker") or {}
    for f in rm.get("filterables") or []:
        for l in f.get("listen") or []:
            if l.get("dashboard_filter_name"):
                out[l["dashboard_filter_name"]] = l.get("field")
    return out


def normalize(d):
    # active layout -> element_id -> {row,col,width,height}
    layout_mode, comp_by_el = "newspaper", {}
    for lay in d.get("dashboard_layouts", []):
        if lay.get("active"):
            layout_mode = lay.get("type", "newspaper")
            for c in lay.get("dashboard_layout_components", []):
                comp_by_el[c.get("dashboard_element_id")] = {
                    "row": c.get("row"), "col": c.get("column"),
                    "width": c.get("width"), "height": c.get("height")}

    filters = []
    for f in d.get("dashboard_filters", []):
        filters.append({
            "name": f.get("name"), "title": f.get("title"), "type": f.get("type"),
            "model": f.get("model"), "explore": f.get("explore"),
            "dimension": f.get("dimension"),
            "defaultValue": f.get("default_value"),
            "allowMultiple": f.get("allow_multiple_values"),
        })

    elements = []
    for el in d.get("dashboard_elements", []):
        q = _query_of(el)
        # Text/markdown tiles (headers, notes) have no query/fields — capture them
        # as text elements so the builder can emit a Sigma text element.
        if el.get("type") == "text" or (not q and (el.get("title_text") or el.get("body_text"))):
            elements.append({
                "name": el.get("title") or el.get("title_text") or f"element_{el.get('id')}",
                "tileType": "text",
                "titleText": el.get("title_text"),
                "bodyText": el.get("body_text"),
                "subtitleText": el.get("subtitle_text"),
                "layout": comp_by_el.get(el.get("id"), {}),
            })
            continue
        if not q and el.get("type") in (None, "text") and not el.get("title"):
            continue
        vc = _vis_config(el, q)
        elements.append({
            "name": el.get("title") or el.get("title_text") or f"element_{el.get('id')}",
            "tileType": _vis_type(el, q),
            "model": q.get("model"), "explore": q.get("view"),
            "fields": q.get("fields") or [],
            "pivots": q.get("pivots") or [],
            "filters": q.get("filters") or {},
            "sorts": q.get("sorts") or [],
            "limit": int(q["limit"]) if str(q.get("limit") or "").isdigit() else q.get("limit"),
            "listen": _listen(el),
            "dynamicFields": _dyn(q.get("dynamic_fields")),
            "noteText": el.get("note_text"), "subtitleText": el.get("subtitle_text"),
            "bodyText": el.get("body_text"),
            # chart reference lines + color encoding (vis_config) → Sigma refMarks/color
            "referenceLines": _reflines(vc),
            "color": _color(vc),
            "layout": comp_by_el.get(el.get("id"), {}),
        })

    return {
        "id": str(d.get("id")),
        "title": d.get("title"),
        "layoutMode": layout_mode,
        "source": "api",
        "lookmlLinkId": d.get("lookml_link_id"),
        "filters": filters,
        "elements": elements,
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    did = sys.argv[1]
    d = get(f"/dashboards/{urllib.parse.quote(did, safe='')}")
    contract = normalize(d)
    out = sys.argv[2] if len(sys.argv) > 2 else None
    txt = json.dumps(contract, indent=2)
    if out:
        with open(out, "w") as f:
            f.write(txt)
        print(f"wrote {out}: {len(contract['elements'])} elements, {len(contract['filters'])} filters")
    else:
        print(txt)


if __name__ == "__main__":
    main()
