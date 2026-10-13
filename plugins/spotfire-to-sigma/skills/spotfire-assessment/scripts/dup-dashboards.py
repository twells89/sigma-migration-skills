#!/usr/bin/env python3
"""dup-dashboards.py — detect DUPLICATE / consolidatable dashboards in a BI estate.

Shared across the *-assessment skills (ThoughtSpot, Power BI, QuickSight, Qlik,
Looker, Cognos, MicroStrategy). Tableau already has its own deeper
`consolidation-candidates.rb`; this is the lighter, tool-neutral detector the
other assessments call so EVERY readout flags "these N dashboards look like the
same report rebuilt — migrate once, not N times."

Input: a normalized dashboard list (the adapter in each scan script maps that
tool's inventory into this shape — only `id` + `name` are required; the rest are
used when present):

    [{ "id": "...", "name": "Q1 Sales (copy)",
       "sources": ["DB.SALES.ORDERS", ...],   # datasets / models / warehouse tables
       "fields":  ["Region", "Net Revenue", ...],
       "viz":     ["bar", "line", "kpi", ...], # chart-kind tokens
       "usage":   1234 }, ... ]               # optional view count (a tiebreaker)

Output (JSON): groups of likely-duplicate dashboards, each with a recommendation
(`consolidate` | `review`), the similarity drivers, and the conversions a merge
would avoid. Pure — no network. Also renders an HTML fragment + a Markdown block
for the assessment readout.

    python3 dup-dashboards.py --in dashboards.json --out dup-groups.json \
        [--html dup.html] [--md]            # --md prints a Markdown block to stdout

The grouping is intentionally CONSERVATIVE (it pools only dashboards that share a
data source or a near-identical name, then needs real field/structure overlap to
emit) so the readout flags genuine rebuilds, not coincidental name collisions.
"""
import argparse, json, re, sys
from itertools import combinations

# Tokens that mark a NAME VARIANT rather than a different report — stripped before
# comparing names so "Sales", "Sales (copy)", "Sales v2", "Sales 2023 FINAL" pool.
_VARIANT = set("""copy copies clone dup duplicate v1 v2 v3 v4 v5 v6 version final
draft wip test temp old new prod dev uat backup bak archive archived
q1 q2 q3 q4 h1 h2 fy ytd mtd qtd jan feb mar apr may jun jul aug sep oct nov dec
january february march april june july august september october november december
2018 2019 2020 2021 2022 2023 2024 2025 2026 monthly weekly daily quarterly annual
""".split())

# Emit a group only when at least one pair scores >= this. Below it the dashboards
# are too different to call a duplicate.
EMIT_FLOOR = 0.45
# A group is "consolidate" (vs the softer "review") when its WEAKEST internal pair
# still shares most fields AND a data source — i.e. genuinely the same report.
CONSOLIDATE_FIELD = 0.70
CONSOLIDATE_SOURCE = 0.50
REVIEW_SCORE = 0.55


def _norm_name_tokens(name):
    toks = re.split(r"[^a-z0-9]+", str(name or "").lower())
    core = [t for t in toks if t and t not in _VARIANT and not t.isdigit()]
    return set(core or [t for t in toks if t])      # fall back if name was ALL variant tokens


def _norm_set(xs):
    out = set()
    for x in xs or []:
        k = re.sub(r"[^a-z0-9]+", "", str(x).lower())
        if k:
            out.add(k)
    return out


def _jaccard(a, b):
    if not a and not b:
        return 0.0
    if not a or not b:
        return 0.0
    return len(a & b) / float(len(a | b))


def _prep(dashboards):
    prepped = []
    for d in dashboards:
        prepped.append({
            "id": d.get("id"),
            "name": d.get("name") or d.get("id") or "(unnamed)",
            "name_toks": _norm_name_tokens(d.get("name")),
            "sources": _norm_set(d.get("sources")),
            "fields": _norm_set(d.get("fields")),
            "viz": _norm_set(d.get("viz")),
            "usage": d.get("usage"),
        })
    return prepped


def _pair_score(a, b):
    """Weighted similarity in [0,1]. Weights shift onto whatever signals are
    actually present so a tool that exposes only names+sources still scores."""
    name = _jaccard(a["name_toks"], b["name_toks"])
    have_fields = bool(a["fields"] and b["fields"])
    have_viz = bool(a["viz"] and b["viz"])
    have_src = bool(a["sources"] and b["sources"])
    field = _jaccard(a["fields"], b["fields"]) if have_fields else 0.0
    viz = _jaccard(a["viz"], b["viz"]) if have_viz else 0.0
    src = _jaccard(a["sources"], b["sources"]) if have_src else 0.0

    w = {"name": 0.30, "field": 0.40 if have_fields else 0.0,
         "viz": 0.10 if have_viz else 0.0, "src": 0.20 if have_src else 0.0}
    tot = sum(w.values()) or 1.0
    w = {k: v / tot for k, v in w.items()}                  # renormalize onto present signals
    score = w["name"] * name + w["field"] * field + w["viz"] * viz + w["src"] * src
    return round(score, 3), {"name_similarity": round(name, 2), "field_overlap": round(field, 2),
                             "viz_overlap": round(viz, 2), "source_overlap": round(src, 2)}


def detect(dashboards):
    """Return {groups:[...], summary:{...}}. A group = a connected component of
    dashboards linked by a pair scoring >= EMIT_FLOOR, where the pair also shares
    a data source OR a near-identical name (the pooling guard against coincidental
    field overlap across unrelated reports)."""
    items = _prep(dashboards)
    n = len(items)
    idx = {i: i for i in range(n)}                          # union-find

    def find(x):
        while idx[x] != x:
            idx[x] = idx[idx[x]]
            x = idx[x]
        return x

    def union(x, y):
        idx[find(x)] = find(y)

    pair_ev = {}
    for i, j in combinations(range(n), 2):
        a, b = items[i], items[j]
        shares_source = bool(a["sources"] & b["sources"])
        name_close = _jaccard(a["name_toks"], b["name_toks"]) >= 0.6
        if not (shares_source or name_close):               # pooling guard
            continue
        score, drivers = _pair_score(a, b)
        if score >= EMIT_FLOOR:
            pair_ev[(i, j)] = {"score": score, **drivers}
            union(i, j)

    comps = {}
    for i in range(n):
        comps.setdefault(find(i), []).append(i)

    groups = []
    for members in comps.values():
        if len(members) < 2:
            continue
        ev = [pair_ev[(i, j)] for i, j in combinations(sorted(members), 2) if (i, j) in pair_ev]
        if not ev:
            continue
        min_field = min(e["field_overlap"] for e in ev)
        min_source = min(e["source_overlap"] for e in ev)
        max_score = max(e["score"] for e in ev)
        if min_field >= CONSOLIDATE_FIELD and min_source >= CONSOLIDATE_SOURCE:
            rec = "consolidate"
        elif max_score >= REVIEW_SCORE:
            rec = "review"
        else:
            rec = "review"
        mem = sorted((items[m] for m in members),
                     key=lambda x: -(x["usage"] or 0))       # most-used first = the survivor
        groups.append({
            "recommendation": rec,
            "members": [{"id": m["id"], "name": m["name"], "usage": m["usage"]} for m in mem],
            "size": len(members),
            "drivers": {
                "max_pair_score": max_score,
                "min_field_overlap": round(min_field, 2),
                "min_source_overlap": round(min_source, 2),
                "shared_sources": sorted(set.intersection(*[items[m]["sources"] for m in members]) or set()),
            },
            "conversions_avoided": len(members) - 1,          # build 1, retire the rest
        })

    groups.sort(key=lambda g: (g["recommendation"] != "consolidate", -g["size"], -g["drivers"]["max_pair_score"]))
    return {
        "groups": groups,
        "summary": {
            "dashboards_scanned": n,
            "duplicate_groups": len(groups),
            "dashboards_in_groups": sum(g["size"] for g in groups),
            "conversions_avoided": sum(g["conversions_avoided"] for g in groups),
        },
    }


def render_md(result):
    g = result["groups"]
    s = result["summary"]
    if not g:
        return "### Duplicate / consolidation candidates\n\n_None found — no two dashboards overlap enough to merge._\n"
    out = ["### Duplicate / consolidation candidates", "",
           f"**{s['duplicate_groups']} group(s)** spanning **{s['dashboards_in_groups']}** dashboards — "
           f"consolidating would avoid **{s['conversions_avoided']}** redundant migration(s).", ""]
    for i, grp in enumerate(g, 1):
        d = grp["drivers"]
        out.append(f"**Group {i} — {grp['recommendation'].upper()}** "
                   f"(field overlap ≥{int(d['min_field_overlap']*100)}%, "
                   f"shared sources: {', '.join(d['shared_sources']) or '—'})")
        for m in grp["members"]:
            u = f" · {m['usage']} views" if m.get("usage") is not None else ""
            out.append(f"- {m['name']}  `{m['id']}`{u}")
        out.append("")
    return "\n".join(out)


def render_html(result):
    g = result["groups"]
    s = result["summary"]
    if not g:
        return ('<section class="dup-dashboards"><h2>Duplicate / consolidation candidates</h2>'
                '<p>None found — no two dashboards overlap enough to merge.</p></section>')
    rows = []
    for i, grp in enumerate(g, 1):
        d = grp["drivers"]
        badge = "#b91c1c" if grp["recommendation"] == "consolidate" else "#b45309"
        def _li(m):
            usage = "" if m.get("usage") is None else f" · {m['usage']} views"
            return f'<li>{_esc(m["name"])} <code>{_esc(str(m["id"]))}</code>{usage}</li>'
        mem = "".join(_li(m) for m in grp["members"])
        rows.append(
            f'<div class="dup-group" style="margin:.5em 0;padding:.6em .8em;border-left:4px solid {badge}">'
            f'<strong>Group {i} — <span style="color:{badge}">{grp["recommendation"].upper()}</span></strong> '
            f'<span style="color:#555">(field overlap ≥{int(d["min_field_overlap"]*100)}%, '
            f'shared sources: {_esc(", ".join(d["shared_sources"]) or "—")}, '
            f'avoids {grp["conversions_avoided"]} migration(s))</span>'
            f'<ul style="margin:.3em 0 0 1.2em">{mem}</ul></div>')
    return ('<section class="dup-dashboards"><h2>Duplicate / consolidation candidates</h2>'
            f'<p>{s["duplicate_groups"]} group(s) across {s["dashboards_in_groups"]} dashboards — '
            f'consolidating avoids {s["conversions_avoided"]} redundant migration(s).</p>'
            + "".join(rows) + "</section>")


def _esc(t):
    return (str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True, help="normalized dashboard list JSON (or '-' for stdin)")
    ap.add_argument("--out", help="write the groups JSON here (default stdout)")
    ap.add_argument("--html", help="also write an HTML fragment here")
    ap.add_argument("--md", action="store_true", help="print a Markdown block to stderr")
    ap.add_argument("--md-stdout", dest="md_stdout", action="store_true",
                    help="print ONLY the Markdown block to stdout (for renderers that embed it)")
    ap.add_argument("--html-stdout", dest="html_stdout", action="store_true",
                    help="print ONLY the HTML fragment to stdout (for renderers that embed it)")
    ap.add_argument("--render", action="store_true",
                    help="--in is an already-detected result (a {groups,summary} dict, "
                         "e.g. inventory.json's duplicate_dashboards); render it instead of re-detecting")
    a = ap.parse_args()
    raw = sys.stdin.read() if a.inp == "-" else open(a.inp).read()
    parsed = json.loads(raw)
    if a.render:
        # Accept either the bare result or a wrapper carrying duplicate_dashboards.
        result = parsed.get("duplicate_dashboards", parsed) if isinstance(parsed, dict) else {"groups": [], "summary": {}}
    else:
        dashboards = parsed
        if isinstance(dashboards, dict):                     # tolerate {"dashboards":[...]} or {"liveboards":[...]}
            dashboards = (dashboards.get("dashboards") or dashboards.get("liveboards")
                          or dashboards.get("items") or [])
        result = detect(dashboards)
    if a.md_stdout:
        # Embed-only mode: emit just the Markdown block on stdout, nothing else.
        sys.stdout.write(render_md(result))
        return
    if a.html_stdout:
        # Embed-only mode: emit just the HTML fragment on stdout, nothing else.
        sys.stdout.write(render_html(result))
        return
    out_json = json.dumps(result, indent=2)
    if a.out:
        open(a.out, "w").write(out_json)
    else:
        print(out_json)
    if a.html:
        open(a.html, "w").write(render_html(result))
    if a.md:
        sys.stderr.write(render_md(result) + "\n")
    s = result.get("summary") or {}
    sys.stderr.write(f"[dup-dashboards] {s.get('duplicate_groups', 0)} group(s), "
                     f"{s.get('conversions_avoided', 0)} conversion(s) avoidable\n")


if __name__ == "__main__":
    main()
