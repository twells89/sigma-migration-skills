"""composition.py — Python twin of shared/lib/composition.rb. Byte-identical output.

kind -> role inference (used when an element has no explicit role). Chart
kinds default to "supporting"; callers wanting a "hero" must tag it explicitly.
"""
ROLES = ["control", "kpi", "insight", "hero", "supporting", "table", "master", "detail",
         "header", "kpi2", "trend", "pivot", "base"]

# Roles each pattern actually places. A role that resolves (explicitly or via
# inference) to something OUTSIDE its chosen pattern's set used to be silently
# dropped from the emitted layout; _check_pattern_roles (below) now raises
# instead -- see _compose_exec / _compose_master_detail.
EXEC_ROLES = ["control", "kpi", "insight", "hero", "supporting", "table"]
MASTER_DETAIL_ROLES = ["control", "master", "detail"]
OVERVIEW_ROLES = ["header", "control", "kpi", "kpi2", "trend", "pivot", "base"]

_KIND_ROLE = {"kpi-chart": "kpi", "table": "table", "pivot-table": "table", "input-table": "table"}

def infer_role(kind):
    return _KIND_ROLE.get(str(kind), "supporting")

def _le(eid, c0, c1, r0, r1):
    return '  <LayoutElement elementId="%s" gridColumn="%d / %d" gridRow="%d / %d"/>' % (eid, c0, c1, r0, r1)

def _band(elements, r0, r1, page_cols):
    n = len(elements)
    if n == 0:
        return []
    if page_cols % n != 0:
        raise ValueError("compose: page_cols (%d) not evenly divisible by %d element(s) in one band" % (page_cols, n))
    w = page_cols // n
    return [_le(el["id"], i * w + 1, i * w + 1 + w, r0, r1) for i, el in enumerate(elements)]

def _roleize(elements):
    out = []
    for e in elements:
        raw = e.get("role")
        role = infer_role(e.get("kind")) if (raw is None or raw == "") else str(raw)
        if role not in ROLES:
            raise ValueError("compose: unknown role %s for element %s" % (role, e["id"]))
        out.append({"id": e["id"], "role": role})
    return out

# Raise when a resolved role isn't in the pattern's consumed set -- e.g.
# "master" passed to "exec", or "kpi" passed to "master_detail". Root fix
# (I3): such a role used to fall through every band unrendered and vanish
# from the emitted layout with no signal.
def _check_pattern_roles(roleized, pattern_name, allowed_roles):
    for e in roleized:
        if e["role"] in allowed_roles:
            continue
        raise ValueError("compose: role %s (element %s) is not used by pattern %s" % (e["role"], e["id"], pattern_name))

# bands: the role -> [r0, r1) row-band computation shared by _compose_exec
# and _compose_master_detail, extracted so callers can get the layout's
# structure (which roles land in which row band, and which element ids)
# without the gridColumn/XML-emission step. Returns
# [{"role":, "ids":, "r0":, "r1":}, ...] in row order. Column splitting
# within a band still happens in _compose_* (via _band()), not here --
# bands() only decides vertical placement.
def bands(elements, pattern, page_cols=24):
    roleized = _roleize(elements)
    by = {r: [] for r in ROLES}
    for e in roleized:
        by.setdefault(e["role"], []).append(e)
    row = [1]
    out = []
    def add(role, group, h):
        if not group:
            return
        out.append({"role": role, "ids": [e["id"] for e in group], "r0": row[0], "r1": row[0] + h})
        row[0] += h
    p = str(pattern)
    if p == "exec":
        _check_pattern_roles(roleized, "exec", EXEC_ROLES)
        for role, h in [("control", 2), ("kpi", 6), ("insight", 3), ("hero", 12)]:
            add(role, by.get(role, []), h)
        add("supporting", by.get("supporting", []) + by.get("table", []), 9)
    elif p == "master_detail":
        _check_pattern_roles(roleized, "master_detail", MASTER_DETAIL_ROLES)
        add("control", by.get("control", []), 2)
        add("master_detail", by.get("master", []) + by.get("detail", []), 14)
    elif p == "overview":
        _check_pattern_roles(roleized, "overview", OVERVIEW_ROLES)
        for role, h in [("header", 3), ("control", 2), ("kpi", 8), ("kpi2", 8),
                        ("trend", 12), ("pivot", 14), ("base", 9)]:
            add(role, by.get(role, []), h)
    else:
        raise ValueError("compose: unknown pattern %r" % (pattern,))
    return out

def _render_bands(elements, pattern, page_cols):
    lines = []
    for b in bands(elements, pattern, page_cols):
        lines += _band([{"id": eid} for eid in b["ids"]], b["r0"], b["r1"], page_cols)
    return "\n".join(lines)

def _compose_exec(elements, page_cols):
    return _render_bands(elements, "exec", page_cols)

# :master_detail -- an optional thin full-width "control" row on top, then
# "master" and "detail" share one tall gridRow, split evenly across page_cols
# (12/12 of 24) via the same _band() helper _compose_exec uses. Layout only:
# the control->detail filter wiring is authored per-element-spec (see
# composition.md), not emitted here.
def _compose_master_detail(elements, page_cols):
    return _render_bands(elements, "master_detail", page_cols)

# "overview" -- an optional stack of full-width bands (each skipped if empty):
# "header" -> "control" (filter row) -> "kpi" (tall: comparative cards + Δ badges) -> "kpi2"
# (optional 2nd KPI row, e.g. rates) -> "trend" -> "pivot" -> "base". Every
# band even-splits its elements across page_cols via the same _band() helper
# _compose_exec/_compose_master_detail use; only vertical stacking differs.
def _compose_overview(elements, page_cols):
    return _render_bands(elements, "overview", page_cols)

def compose(elements, pattern="exec", page_cols=24):
    p = str(pattern)
    if p == "exec":
        return _compose_exec(elements, page_cols)
    if p == "master_detail":
        return _compose_master_detail(elements, page_cols)
    if p == "overview":
        return _compose_overview(elements, page_cols)
    raise ValueError("compose: unknown pattern %r" % (pattern,))

# _indent: prepend one indent level (2 spaces, this file's per-level unit) to
# every line of a multi-line XML fragment -- used to nest a tab's bare
# <LayoutElement> lines (already 2-space indented by _le()) one level deeper
# inside a <Tab> (-> 4 spaces total, matching the verified shape).
def _indent(text):
    return "\n".join("  " + line for line in str(text).split("\n"))

# tabbed_container: a Sigma {kind:"tabbed-container"} page element + its
# <TabbedContainer> layout XML. Per the live-verified shape: tabs[] in the
# JSON element are LABELS ONLY (no children); the <Tab> children in the
# layout map to tabs[] BY POSITION (1st <Tab> = 1st label).
#
# GOTCHA (verified): inside a <Tab>, callers pass BARE <LayoutElement>
# children only -- a nested <GridContainer> inside a <Tab> scrambles tab
# render order. The <Tab> is itself a mini-grid (gridTemplateColumns /
# gridTemplateRows), so elements position directly within it; no inner
# GridContainer is needed.
def tabbed_container(id, tabs, grid_column, grid_row, tab_bar_alignment="start"):
    if not id:
        raise ValueError("tabbed_container: id required")
    if not tabs:
        raise ValueError("tabbed_container: tabs required")
    for t in tabs:
        if not t.get("name"):
            raise ValueError("tabbed_container: every tab requires a non-empty name")
    element = {
        "id": id,
        "kind": "tabbed-container",
        "tabs": [{"name": t["name"]} for t in tabs],
        "tabBar": {"alignment": tab_bar_alignment},
    }
    tab_blocks = [
        '  <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n'
        + _indent(t["inner"]) + "\n"
        + "  </Tab>"
        for t in tabs
    ]
    layout = (
        '<TabbedContainer elementId="%s" type="tabbed-container" gridColumn="%s" gridRow="%s">\n'
        % (id, grid_column, grid_row)
        + "\n".join(tab_blocks) + "\n"
        + "</TabbedContainer>"
    )
    return {"element": element, "layout": layout}
