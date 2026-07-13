#!/usr/bin/env python3
"""
convert.py — MicroStrategy bundle.json -> Sigma data-model spec + workbook spec.

Everything is derived programmatically from the bundle:
  - Sources: every logical table in bundle["tables"], path [<database>, <namespace>, <tableName>].
  - Base/fact table: the logical table that carries fact expressions.
  - Joins: attributes whose ID (key) form has expressions mapped to BOTH the fact
    table and a different lookup table that is present in the bundle. The fact-side
    expression and the lookup-side expression become the left/right join keys.
  - Metrics: parsed from bundle["metrics"] expression tokens (function + fact /
    metric object references + Distinct=True parameter -> CountDistinct).
  - Workbook pages: one page per dossier chapter; each chapter's dataset report's
    dataTemplate units give the grouping attributes + metric columns.
  - Controls: dossier chapter filters + page/panel selectors -> Sigma controls.
    MSTR selectors DECLARE their targets (targets: [{key}] viz refs) — the
    strongest source-scope signal of any BI tool — so each control's filter
    targets are wired to exactly the table elements built from the declared
    vizzes (chapter filters reach every viz in their chapter). The intended
    scope is emitted as control-scope.json (contract:
    scripts/lib/control_lint.rb header + refs/control-parity.md).
  - Layout: container-banded pages (header band titled from the chapter /
    dossier name, controls band, full-width tables) -> layout.xml, applied
    after the workbook POST via scripts/put-layout.rb.

Usage:
  python3 convert.py --connection-id <uuid> --database CSA --folder-id <uuid> \
      [--inode-map inodes.json] [--bundle bundle.json] \
      [--dm-name "..."] [--wb-name "..."] \
      [--data-model-id <uuid>] [--orders-element-id <id>]

Outputs sigma_dm_spec.json and sigma_workbook_spec.json. The workbook spec uses
placeholders {{DATA_MODEL_ID}} / {{ORDERS_ELEMENT_ID}} unless the corresponding
args are given.
"""
import argparse
import json
import os
import re
import sys

# ── documentation-grounded mapping catalogs (SINGLE SOURCE OF TRUTH) ─────────
# Every enumerable classifier map below is loaded from refs/catalogs/<dim>.json —
# cited rows (MicroStrategy source doc + Sigma target + sigma_verified), and a
# LOUD fallback on anything unmapped. NO inline mapping literal may bypass these
# catalogs (grep-enforced by tests/test_grounding.py). The human-readable
# coverage matrix in refs/microstrategy-coverage.md is GENERATED from these files.
# Loader: shared/lib/coverage_catalog.py (synced to scripts/lib/). Design mirrors
# the beads-sigma-kvza / -93ps contract: catalog = data, code = thin resolver.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402
_CAT_DIR = _cc.default_catalog_dir(__file__)
AGG_CAT = _cc.load(_CAT_DIR, "aggregation")     # MSTR group function -> Sigma/SQL aggregate
FMT_CAT = _cc.load(_CAT_DIR, "number-format")   # MSTR format category -> Sigma number format
CTRL_CAT = _cc.load(_CAT_DIR, "control")        # bound-column type    -> Sigma control kind
VIZ_CAT = _cc.load(_CAT_DIR, "viz-kind")        # dossier visualizationType -> Sigma element kind
# viz-kind is now WIRED (beads-sigma-kvza): each dossier chapter's primary
# visualizationType is resolved through VIZ_CAT — bar/line/area chart types emit
# the matching Sigma chart element (a dim on the xAxis + the metrics on the
# yAxis); `grid`/compound/heat_map and any UNMAPPED type fall to a Sigma table
# with a LOUD warning (data preserved, never a silent wrong chart).
CHART_KINDS = {"bar-chart", "line-chart", "area-chart"}  # axis-bindable in build_workbook_spec

def primary_viz_type(chapter):
    """The chapter's primary (first) dossier visualizationType, e.g. 'grid' or
    'bar_chart'. convert.py builds one Sigma element per chapter, so the first
    visualization's type drives that element's kind."""
    for pg in chapter.get("pages") or []:
        for v in pg.get("visualizations") or []:
            vt = v.get("visualizationType")
            if vt:
                return vt
    return "grid"

# FN: MSTR metric group function -> warehouse SQL aggregate, DERIVED from the
# aggregation catalog (formerly an inline dict literal mapping Sum/Count/Avg/
# Max/Min to their uppercased SQL names). metric_sql() resolves through
# resolve_or_warn so an unmapped function WARNS loudly (never a silent
# passthrough), then still emits UPPER() as a documented degraded fallback.
FN = {r["source"]: r["sql"] for r in AGG_CAT.rows if r.get("sql")}


def friendly(col: str) -> str:
    """Sigma friendly-name normalization for ALL_CAPS_UNDERSCORE warehouse names."""
    return " ".join(p.capitalize() for p in col.split("_"))


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


# ---------------------------------------------------------------- bundle model
class Bundle:
    def __init__(self, raw):
        self.raw = raw
        # LOUD-fallback sink: catalog resolvers append standardized warnings here
        # (aggregation / number-format) from deep in the emit recursion; main()
        # prints the deduped union alongside build_workbook_spec's warnings.
        self.warnings = []
        self.tables = raw["tables"]          # logical table id -> def
        self.attributes = raw["attributes"]  # attribute id -> def
        self.metrics = raw["metrics"]        # metric id -> def
        self.facts = raw["facts"]            # fact id -> def
        self.reports = raw["reports"]
        self.dossier = raw["dossier"]

        # logical table id -> (name, schema/namespace, physical table name)
        self.table_info = {}
        for tid, t in self.tables.items():
            pt = t["physicalTable"]
            self.table_info[tid] = {
                "name": t["information"]["name"],
                "tableName": pt["tableName"],
                "namespace": pt.get("namespace"),
            }

        # fact table = the logical table that carries fact expressions
        fact_tids = set()
        for f in self.facts.values():
            for de in f["expressions"]:
                for tb in de.get("tables", []):
                    fact_tids.add(tb["objectId"])
        if len(fact_tids) != 1:
            raise SystemExit(f"expected exactly 1 fact table, found {fact_tids}")
        self.fact_tid = next(iter(fact_tids))

        # per logical table: attribute id -> list of forms
        #   form := {category, expr(column), isKeyForm}
        self.table_attr_forms = {}   # tid -> {attr_id: [form,...]}
        for tid, t in self.tables.items():
            am = {}
            for a in t.get("attributes", []):
                aid = a["information"]["objectId"]
                forms = []
                for f in a.get("forms", []):
                    forms.append({
                        "category": f["formCategory"]["name"],
                        "expr": f["expression"]["text"],
                        "isKeyForm": f.get("isKeyForm", False),
                        "lookupTable": f["lookupTable"]["objectId"],
                    })
                am[aid] = forms
            self.table_attr_forms[tid] = am

        # fact id -> physical column on the fact table
        self.fact_col = {}
        for fid, f in self.facts.items():
            for de in f["expressions"]:
                for tb in de.get("tables", []):
                    if tb["objectId"] == self.fact_tid:
                        self.fact_col[fid] = de["expression"]["text"]
        # name -> fact id (metric text sometimes references facts by bare name)
        self.fact_by_name = {f["information"]["name"]: fid
                             for fid, f in self.facts.items()}
        self.metric_by_name = {m["information"]["name"]: mid
                               for mid, m in self.metrics.items()}

    # ---- joins: attribute key form mapped to BOTH fact table and lookup table
    def derive_joins(self):
        joins = []
        fact_forms = self.table_attr_forms[self.fact_tid]
        for aid, forms in fact_forms.items():
            key_fact = next((f for f in forms if f["isKeyForm"]), None)
            if not key_fact:
                continue
            lookup_tid = key_fact["lookupTable"]
            if lookup_tid == self.fact_tid or lookup_tid not in self.tables:
                continue  # degenerate (fact-resident attr) or table not extracted
            lookup_forms = self.table_attr_forms.get(lookup_tid, {}).get(aid, [])
            key_lookup = next((f for f in lookup_forms if f["isKeyForm"]), None)
            if not key_lookup:
                continue
            joins.append({
                "attribute": aid,
                "lookup_tid": lookup_tid,
                "fact_col": key_fact["expr"],
                "lookup_col": key_lookup["expr"],
            })
        return joins

    # ---- columns each table contributes (any expression mapped to it)
    def table_columns(self, tid):
        cols = []
        seen = set()
        for aid, forms in self.table_attr_forms.get(tid, {}).items():
            for f in forms:
                c = f["expr"]
                if f["lookupTable"] == tid and c not in seen:
                    seen.add(c)
                    cols.append(c)
        if tid == self.fact_tid:
            for fid, c in self.fact_col.items():
                if c not in seen:
                    seen.add(c)
                    cols.append(c)
            # join keys on the fact side
            for j in self.derive_joins():
                if j["fact_col"] not in seen:
                    seen.add(j["fact_col"])
                    cols.append(j["fact_col"])
        return cols

    # ---- metric expression -> Sigma formula
    def metric_formula(self, mid, ref, expand_metrics=False):
        """ref(column_friendly) -> bracketed reference string.
        expand_metrics: inline referenced metrics (workbook context) instead of
        emitting [Metric Name] (data-model context)."""
        m = self.metrics[mid]
        toks = m["expression"]["tokens"]
        out = []
        i = 0
        while i < len(toks):
            t = toks[i]
            v, ty = t.get("value"), t.get("type")
            if ty == "function" and v not in ("=",):
                fname = v
                # peek a <...> parameter block for Distinct=True
                j = i + 1
                distinct = False
                if j < len(toks) and toks[j].get("value") == "<":
                    while j < len(toks) and toks[j].get("value") != ">":
                        if (toks[j].get("value") == "Distinct"
                                and j + 2 < len(toks)
                                and toks[j + 2].get("value") == "True"):
                            distinct = True
                        j += 1
                    i = j  # skip past the parameter block
                # COMPOSITIONAL (cited: refs/catalogs/aggregation.json Count row) —
                # MSTR Count<Distinct=True> -> Sigma CountDistinct. Not a flat
                # catalog row (the Distinct=True is an expression parameter, not a
                # distinct function token); the plain group functions (Sum/Count/
                # Avg/Max/Min) share tokens with their Sigma names, so metric_formula
                # emits the MSTR function name verbatim as the Sigma aggregate.
                if fname == "Count" and distinct:
                    fname = "CountDistinct"
                out.append(fname)
            elif ty == "object_reference":
                tgt = t.get("target", {})
                sub = tgt.get("subType")
                oid = tgt.get("objectId")
                if sub == "fact":
                    out.append(ref(friendly(self.fact_col[oid])))
                elif sub == "metric":
                    if expand_metrics:
                        out.append("(" + self.metric_formula(
                            oid, ref, expand_metrics=True) + ")")
                    else:
                        out.append(f"[{self.metrics[oid]['information']['name']}]")
                else:
                    raise SystemExit(f"unhandled object_reference {sub} in metric "
                                     f"{m['information']['name']}")
            elif ty == "character":
                if v in ("<", ">"):
                    pass  # parameter block delimiters already handled
                elif v in ("(", ")", ",", "+", "-", "*", "/"):
                    out.append(v)
            elif ty == "identifier" or ty == "boolean":
                pass  # parameter names/values inside <...>
            i += 1
        # join with spaces around operators, none around parens
        f = ""
        for tok in out:
            if tok in ("+", "-", "*", "/"):
                f += f" {tok} "
            elif tok == ",":
                f += ", "
            else:
                f += tok
        return f

    # ---- metric expression -> warehouse SQL (for AE-emulation sql elements)
    def metric_sql(self, mid, fact_alias="ORDER_FACT"):
        m = self.metrics[mid]
        toks = m["expression"]["tokens"]
        out = []
        distinct_pending = False
        i = 0
        while i < len(toks):
            t = toks[i]
            v, ty = t.get("value"), t.get("type")
            if ty == "function" and v not in ("=",):
                fname, distinct = v, False
                j = i + 1
                if j < len(toks) and toks[j].get("value") == "<":
                    while j < len(toks) and toks[j].get("value") != ">":
                        if (toks[j].get("value") == "Distinct"
                                and j + 2 < len(toks)
                                and toks[j + 2].get("value") == "True"):
                            distinct = True
                        j += 1
                    i = j
                # DOCUMENTATION-GROUNDED (refs/catalogs/aggregation.json). An
                # unmapped MSTR function no longer silently passes through as
                # fname.upper(): resolve_or_warn appends a LOUD warning, then we
                # emit UPPER() only as a documented degraded fallback.
                sql_fn = FN.get(fname)
                if sql_fn is None:
                    AGG_CAT.resolve_or_warn(
                        fname, self.warnings,
                        context="metric %r AE-emulation SQL"
                                % m["information"]["name"])
                    sql_fn = fname.upper()
                out.append(sql_fn)
                distinct_pending = distinct
            elif ty == "object_reference":
                tgt = t.get("target", {})
                if tgt.get("subType") == "fact":
                    out.append(f"{fact_alias}.{self.fact_col[tgt['objectId']]}")
                elif tgt.get("subType") == "metric":
                    out.append("(" + self.metric_sql(tgt["objectId"],
                                                     fact_alias) + ")")
            elif ty == "character":
                if v == "(":
                    out.append("(DISTINCT " if distinct_pending else "(")
                    distinct_pending = False
                elif v in (")", ",", "+", "-", "*", "/"):
                    out.append(v)
        # NB: '<'/'>' parameter blocks skipped above
            i += 1
        sql = ""
        for tok in out:
            if tok in ("+", "-", "*", "/"):
                sql += f" {tok} "
            elif tok == ",":
                sql += ", "
            else:
                sql += tok
        return sql

    # ---- clean per-(attribute keys) aggregation SQL for a report
    def report_attr_units(self, report):
        units = report["dataSource"]["dataTemplate"]["units"]
        return ([u for u in units if u.get("type") == "attribute"],
                [el for u in units if u.get("type") == "metrics"
                 for el in u["elements"]])

    def clean_group_aliases(self, report):
        attr_units, metric_units = self.report_attr_units(report)
        aliases = []
        for u in attr_units:
            key_col, desc_col = self.attribute_unit_cols(u["id"])
            aliases.append(friendly(key_col))
            if desc_col:
                aliases.append(friendly(desc_col))
        aliases += [el["name"] for el in metric_units]
        return aliases

    def build_clean_group_sql(self, database, report):
        """SELECT <attr keys>, MAX(<desc>) per desc form, <metric aggs>
        FROM fact JOIN needed dims GROUP BY keys — the same statement
        MicroStrategy generates for the report."""
        attr_units, metric_units = self.report_attr_units(report)
        fact = self.table_info[self.fact_tid]
        fq = lambda tid: ".".join([database,
                                   self.table_info[tid]["namespace"],
                                   self.table_info[tid]["tableName"]])
        joins_by_tid = {j["lookup_tid"]: j for j in self.derive_joins()}

        select, group_pos, needed_tids = [], [], []
        pos = 0
        for u in attr_units:
            key_col, desc_col = self.attribute_unit_cols(u["id"])
            a = self.attributes[u["id"]]
            lookup_tid = a["attributeLookupTable"]["objectId"]
            alias = self.table_info[lookup_tid]["tableName"]
            if lookup_tid != self.fact_tid and lookup_tid not in needed_tids:
                needed_tids.append(lookup_tid)
            pos += 1
            select.append(f'{alias}.{key_col} AS "{friendly(key_col)}"')
            group_pos.append(str(pos))
            if desc_col:
                pos += 1
                select.append(f'MAX({alias}.{desc_col}) AS "{friendly(desc_col)}"')
        for el in metric_units:
            select.append(f'{self.metric_sql(el["id"], fact["tableName"])} '
                          f'AS "{el["name"]}"')

        from_sql = f'{fq(self.fact_tid)} {fact["tableName"]}'
        for tid in needed_tids:
            j = joins_by_tid[tid]
            dim = self.table_info[tid]["tableName"]
            from_sql += (f'\n  JOIN {fq(tid)} {dim} ON '
                         f'{fact["tableName"]}.{j["fact_col"]} = '
                         f'{dim}.{j["lookup_col"]}')
        return ("SELECT " + ",\n       ".join(select)
                + f"\nFROM {from_sql}\nGROUP BY " + ", ".join(group_pos))

    def build_ae_sql(self, database, report, ae_cfg):
        """AE-emulation: clean groups, then every parent-key row takes the
        pinned representative row's label + metric values for its quirk key."""
        attr_units, metric_units = self.report_attr_units(report)
        qkey_f = friendly(ae_cfg["quirkKeyCol"])
        qdesc_f = friendly(ae_cfg["quirkDescCol"])
        parent_f = [friendly(c) for c in ae_cfg["parentKeyCols"]]

        def lit(v):
            s = str(v)
            try:
                float(s)
                return s
            except ValueError:
                return "'" + s.replace("'", "''") + "'"

        conds = []
        for w in ae_cfg["winners"]:
            parts = [f'w."{qkey_f}" = {lit(w[qkey_f])}']
            parts += [f'w."{p}" = {lit(w[p])}' for p in parent_f]
            conds.append("(" + " AND ".join(parts) + ")")

        out_cols = [f'f."{p}" AS "{p}"' for p in parent_f]
        out_cols.append(f'w."{qkey_f}" AS "{qkey_f}"')
        out_cols.append(f'w."{qdesc_f}" AS "{qdesc_f}"')
        out_cols += [f'w."{el["name"]}" AS "{el["name"]}"'
                     for el in metric_units]
        return (
            "WITH F AS (\n" + self.build_clean_group_sql(database, report)
            + "\n)\nSELECT " + ",\n       ".join(out_cols)
            + f'\nFROM F f\nJOIN F w ON w."{qkey_f}" = f."{qkey_f}"\n  AND ('
            + "\n    OR ".join(conds) + ")")

    # ---- display format for a metric — DOCUMENTATION-GROUNDED (beads-sigma-kvza)
    @staticmethod
    def _mstr_format_category(m):
        """Return the metric's EXPLICIT MicroStrategy number-format category
        (lowercased: 'currency' / 'percent' / 'fixed' / 'number' / 'scientific',
        etc.), or None when the metric carries no explicit format. Compositional
        cited predicate — the flat category->Sigma-format map lives in
        refs/catalogs/number-format.json (authoritative_doc). MicroStrategy
        expresses a metric's format via `metricFormatType` (a named category)
        and/or a `format.values` property block; a 'reserved'/'general' type with
        an empty format block means 'inherit the default' = NO explicit format."""
        ft = str(m.get("metricFormatType") or "").strip().lower()
        if ft and ft not in ("reserved", "default", "general", "automatic"):
            return ft
        fmt = m.get("format") or {}
        for v in (fmt.get("values") or []):
            if isinstance(v, dict):
                c = v.get("category") or v.get("formatCategory") or v.get("name")
                if c:
                    return str(c).strip().lower()
        return None

    def metric_display_format(self, mid):
        """Sigma number format for a metric, GROUNDED in the metric's real
        MicroStrategy format via refs/catalogs/number-format.json. When there is
        NO explicit MSTR format we ship the metric UNFORMATTED and record a LOUD
        note — we do NOT guess a currency/percent/integer format from the metric
        or fact-column NAME. (The old name/column-substring guessing —
        pct|percent|margin -> %, REVENUE|PROFIT|COST -> $ — with a silent None
        fallback was the beads-sigma-kvza disease and is GONE.)"""
        m = self.metrics[mid]
        cat = self._mstr_format_category(m)
        if not cat:
            self.warnings.append(
                "⚠ number-format: metric %r has no explicit MicroStrategy number "
                "format (metricFormatType=%r) — shipping UNFORMATTED; set an "
                "explicit format in Sigma if needed (no name-substring guess)."
                % (m["information"]["name"], m.get("metricFormatType")))
            return None
        row = FMT_CAT.resolve_or_warn(
            cat, self.warnings, context="metric %r" % m["information"]["name"])
        if not row or not row.get("sigma"):
            return None
        return {"kind": "number", "formatString": row["sigma"]}

    # ---- dossier filter signals (chapter filters + selectors)
    @staticmethod
    def _walk_selectors(node):
        """Selectors on a dossier page/panel, panelStacks walked recursively
        (panels nest further panelStacks — same walk as the assessment)."""
        out = list(node.get("selectors") or [])
        for ps in node.get("panelStacks") or []:
            for p in ps.get("panels") or []:
                out.extend(Bundle._walk_selectors(p))
        return out

    @staticmethod
    def _walk_viz_keys(node):
        out = [v["key"] for v in node.get("visualizations") or [] if v.get("key")]
        for ps in node.get("panelStacks") or []:
            for p in ps.get("panels") or []:
                out.extend(Bundle._walk_viz_keys(p))
        return out

    def filter_signals(self):
        """Every filter-like signal in the dossier, normalized:
        {kind: chapter-filter|selector, chapter, name, selectorType,
         source_id, targets: [viz keys] or None (None = whole chapter)}.
        Panel selectors are navigation, not data filters — returned with
        kind=panel-selector so the caller can flag them MANUAL without
        counting them as filter signals."""
        signals = []
        for ch in self.dossier.get("chapters", []):
            for f in ch.get("filters") or []:
                signals.append({
                    "kind": "chapter-filter", "chapter": ch["name"],
                    "name": f.get("name"), "key": f.get("key"),
                    "source_id": (f.get("source") or {}).get("id"),
                    "targets": None,
                })
            for pg in ch.get("pages") or []:
                for sel in self._walk_selectors(pg):
                    st = sel.get("selectorType", "")
                    kind = ("panel-selector" if st.startswith("panel_selector")
                            else "selector")
                    signals.append({
                        "kind": kind, "chapter": ch["name"],
                        "name": sel.get("name"), "key": sel.get("key"),
                        "selectorType": st,
                        "source_id": (sel.get("source") or {}).get("id"),
                        "targets": [t["key"] for t in sel.get("targets") or []]
                                   or None,
                    })
        return signals

    def viz_chapter(self):
        """visualization key -> chapter name (declared selector targets are
        viz keys; the converter builds one table element per chapter)."""
        out = {}
        for ch in self.dossier.get("chapters", []):
            for pg in ch.get("pages") or []:
                for k in self._walk_viz_keys(pg):
                    out[k] = ch["name"]
        return out

    def resolve_attribute(self, source_id=None, name=None):
        if source_id and source_id in self.attributes:
            return source_id
        if name:
            for aid, a in self.attributes.items():
                if a["information"]["name"] == name:
                    return aid
        return None

    def attribute_ctl_type(self, aid):
        """'date' | 'number' | 'text' for the column the control binds (the
        rendered DESC form, falling back to the key). Drives the control
        shape: a Sigma `list` control whose filter target is a DATETIME *or
        NUMERIC* column posts 200 but Sigma SILENTLY STRIPS the target
        (datetime: cross-plugin estate gotcha in refs/control-parity.md;
        numeric: live-verified on this converter 2026-06-12 — re-PUTting the
        filter returns 200 and reads back `filters: null`). Dates become
        date-range controls; numbers bind through a hidden Text() cast."""
        a = self.attributes[aid]
        forms = a["forms"]
        key = next((f for f in forms if f.get("category") == "ID"), forms[0])
        desc = next((f for f in forms if f.get("category") == "DESC"), None)
        f = desc or key  # the control filters the rendered (DESC) column
        dt = ((f.get("dataType") or {}).get("type") or "").lower()
        if dt in ("date", "time", "timestamp") or f.get("displayFormat") == "date":
            return "date"
        if dt and not any(t in dt for t in ("char", "text", "string", "binary")):
            return "number"
        return "text"

    # ---- attribute key + display columns for a report unit
    def attribute_unit_cols(self, aid):
        """Returns (key_col, desc_col_or_None) physical column names.

        MicroStrategy grids group by the attribute's KEY (ID) form and render
        the DESC form. When the DESC form differs from the key, the rendered
        label per element resolves to the max DESC value over the joined fact
        rows — so the converter emits the key as the grouping column and the
        DESC as a Max() calculation."""
        a = self.attributes[aid]
        forms = a["forms"]
        key = next((f for f in forms if f.get("category") == "ID"), forms[0])
        desc = next((f for f in forms if f.get("category") == "DESC"), None)
        key_col = key["expressions"][0]["expression"]["text"]
        desc_col = desc["expressions"][0]["expression"]["text"] if desc else None
        return key_col, desc_col


# ------------------------------------------------------------------- emitters
def ae_element_name(report_name):
    return f"{report_name} (MSTR AE)"


def join_column_names(b: "Bundle"):
    """Display names available on the consumable join element (mirrors
    build_dm_spec's add_join_col walk)."""
    names = {friendly(c) for c in b.table_columns(b.fact_tid)}
    join_key_lookup = {(j["lookup_tid"], j["lookup_col"]) for j in b.derive_joins()}
    for j in b.derive_joins():
        for c in b.table_columns(j["lookup_tid"]):
            if (j["lookup_tid"], c) in join_key_lookup:
                continue
            names.add(friendly(c))
    return names


# ---- dossier selectors / chapter filters -> Sigma controls ------------------
def emit_controls(b: "Bundle", pages, page_ctx, warnings):
    """Wire every dossier filter signal to Sigma controls (verified shapes:
    refs/control-parity.md). MSTR selectors carry DECLARED viz targets, so
    filter targets go to exactly the table elements built from those vizzes;
    chapter filters cover every element on their chapter's page. Controls are
    appended AFTER their target tables in spec order (POST requirement).
    Returns (n_signals, scope_entries, unbound) for control-scope.json."""
    viz_ch = b.viz_chapter()
    scope_entries, unbound, used_ctl_ids = [], [], set()
    n_signals = 0

    def ctl_id_for(name):
        base = re.sub(r"[^A-Za-z0-9]", "", str(name).title()) + "Filter"
        cid, n = base, 2
        while cid in used_ctl_ids:
            cid, n = f"{base}{n}", n + 1
        used_ctl_ids.add(cid)
        return cid

    def find_or_add_col(ctx, col, as_text=False):
        """Column for `friendly(col)` on the target element — reuse the
        grouping passthrough when present, else add a hidden passthrough.
        as_text wraps the reference in Text() (always a fresh hidden column):
        a list-control filter target on a NUMERIC column is silently stripped
        by Sigma (200 on POST/PUT, `filters: null` on readback — live-
        verified 2026-06-12), so numeric attribute selectors bind through a
        text cast. Returns columnId or None when the element can't carry the
        column."""
        fr = friendly(col)
        if fr not in ctx["available"]:
            # the grouping column may still exist (e.g. AE alias) — check
            if not any(c.get("formula") == ctx["ref"](fr)
                       for c in ctx["element"]["columns"]):
                return None
        if as_text:
            formula = f"Text({ctx['ref'](fr)})"
            for c in ctx["element"]["columns"]:
                if c.get("formula") == formula:
                    return c["id"]
            cid = f"ctlt-{slug(ctx['element']['id'])}-{slug(col)}"
            ctx["element"]["columns"].append(
                {"id": cid, "name": f"{fr} (Filter)", "formula": formula,
                 "hidden": True})
            return cid
        formula = ctx["ref"](fr)
        for c in ctx["element"]["columns"]:
            if c.get("formula") == formula:
                return c["id"]
        cid = f"ctlc-{slug(ctx['element']['id'])}-{slug(col)}"
        ctx["element"]["columns"].append(
            {"id": cid, "name": fr, "formula": formula, "hidden": True})
        return cid

    for sig in b.filter_signals():
        label = sig.get("name") or "Selector"
        src = f"{sig['kind']} '{label}' (chapter '{sig['chapter']}')"
        if sig["kind"] == "panel-selector":
            # navigation between panels, not a data filter — flagged MANUAL,
            # not counted as a filter signal
            unbound.append({"sourceName": src, "status": "manual",
                            "reason": "panel selector switches panels (navigation), "
                                      "not a data filter — no Sigma control emitted; "
                                      "panels land as separate elements"})
            continue
        n_signals += 1
        st = sig.get("selectorType", "")
        aid = b.resolve_attribute(sig.get("source_id"), sig.get("name"))
        if aid is None:
            reason = ("metric qualification selector — Sigma has no direct "
                      "equivalent; port by hand (e.g. a number-range control "
                      "wired to the metric's base column)"
                      if "metric" in st else
                      "source attribute not resolvable in the bundle — wire "
                      "manually rather than guessing a column")
            warnings.append(f"control {src}: {reason}")
            unbound.append({"sourceName": src, "status": "unbound",
                            "reason": reason})
            continue

        # targets: declared viz keys -> chapter tables; none -> own chapter
        if sig["targets"]:
            tgt_chapters, dropped = [], []
            for k in sig["targets"]:
                (tgt_chapters if k in viz_ch else dropped).append(
                    viz_ch.get(k, k))
            if dropped:
                warnings.append(f"control {src}: declared target viz key(s) "
                                f"{dropped} not found in the dossier — skipped")
            tgt_chapters = list(dict.fromkeys(tgt_chapters))
        else:
            tgt_chapters = [sig["chapter"]]
        ctxs = [page_ctx[c] for c in tgt_chapters if c in page_ctx]
        if not ctxs:
            warnings.append(f"control {src}: no target elements resolvable — "
                            "not emitted")
            unbound.append({"sourceName": src, "status": "unbound",
                            "reason": "declared targets resolve to no built element"})
            continue

        key_col, desc_col = b.attribute_unit_cols(aid)
        ctl_col = desc_col or key_col   # what MSTR renders in the selector
        ctl_type = b.attribute_ctl_type(aid)   # 'date' | 'number' | 'text'
        # DOCUMENTATION-GROUNDED control kind (refs/catalogs/control.json). The
        # bound-column type resolves to a Sigma control kind; a miss warns loudly
        # and falls back to the documented default 'list'. The as_text cast below
        # still keys off ctl_type == 'number' (numeric list targets are silently
        # stripped by Sigma — see the catalog row note).
        ctl_kind_row = CTRL_CAT.resolve_or_warn(ctl_type, warnings, context=src)
        ctl_kind = (ctl_kind_row or {}).get("sigma") or "list"
        filters, wired = [], []
        for ctx in ctxs:
            cid = find_or_add_col(ctx, ctl_col, as_text=(ctl_type == "number"))
            if cid is None:
                warnings.append(
                    f"control {src}: column {friendly(ctl_col)!r} not available "
                    f"on element '{ctx['element']['name']}' — target skipped")
                continue
            filters.append({"source": {"kind": "table",
                                       "elementId": ctx["element"]["id"]},
                            "columnId": cid})
            wired.append({"elementId": ctx["element"]["id"], "columnId": cid})
        if not filters:
            unbound.append({"sourceName": src, "status": "unbound",
                            "reason": f"column {friendly(ctl_col)!r} not on any "
                                      "target element — dropped loudly rather "
                                      "than wired to a wrong column"})
            continue

        ctl = {"id": f"ctl-{slug(sig['chapter'])}-{slug(label)}",
               "kind": "control", "controlId": ctl_id_for(label),
               "name": label,
               "filters": filters}
        if ctl_kind == "date-range":
            # date-range needs no `source` but DOES require a flat `mode` —
            # without it the POST fails with the misleading "Invalid kind:
            # control" (live-verified cross-plugin; see control-parity.md)
            ctl.update({"controlType": "date-range", "mode": "between",
                        "includeNulls": "when-no-value-is-selected"})
        else:
            ctl.update({"controlType": "list", "mode": "include",
                        "selectionMode": "multiple", "values": [],
                        "source": {"kind": "source",
                                   "source": filters[0]["source"],
                                   "columnId": filters[0]["columnId"]}})

        # the control lives on its own chapter's page, AFTER the tables
        home = page_ctx[sig["chapter"]]["page"]
        home["elements"].append(ctl)

        # CONTRACT entry (lib/control_lint.rb header): declared targets that
        # cover every queryable element on the control's page = scope "page";
        # a narrower declared set = the scope allowlist (selector-scoped-by-
        # design). mustReach always asserts the DECLARED targets.
        target_ids = [c["element"]["id"] for c in ctxs]
        page_tables = [e["id"] for e in home["elements"]
                       if e.get("kind") == "table"]
        full_page = set(page_tables) <= set(target_ids)
        scope_entries.append({
            "controlId": ctl["controlId"], "sourceName": src,
            "status": "wired", "controlType": ctl["controlType"],
            "scope": "page" if full_page else target_ids,
            "mustReach": target_ids, "wired": wired,
        })
    return n_signals, scope_entries, unbound


# ---- container-banded layout (layout-playbook.md shapes, shared across
# plugins; python port of the qlik builder's banded_page) ---------------------
HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
HEADER_ROWS = 3
GENERIC_TITLE = re.compile(r"^(?:page|sheet|dashboard)\s*\d+$", re.I)


def _le(eid, c0, c1, r0, r1):
    return (f'  <LayoutElement elementId="{eid}" gridColumn="{c0} / {c1}" '
            f'gridRow="{r0} / {r1}"/>')


def _gc(cid, c0, c1, r0, r1, inner):
    return (f'<GridContainer elementId="{cid}" type="grid" '
            f'gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}" '
            f'gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto">\n{inner}\n</GridContainer>')


def _cluster_bands(items):
    bands = []
    for it in sorted(items, key=lambda i: (i[3], i[1])):
        if bands and it[3] < bands[-1]["r1"]:
            bands[-1]["items"].append(it)
            bands[-1]["r1"] = max(bands[-1]["r1"], it[4])
        else:
            bands.append({"r0": it[3], "r1": it[4], "items": [it]})
    return [bb["items"] for bb in bands]


def banded_page(page_id, items, title, id_prefix=None):
    """Header band + one full-width GridContainer per row band, children
    container-relative. Returns (page_xml, extra_spec_elements)."""
    pfx = id_prefix or f"band-{page_id}"
    extra, children = [], []
    offset = 0
    if title:
        hdr, txt = f"{pfx}-hdr", f"{pfx}-hdrtext"
        extra.append({"id": hdr, "kind": "container",
                      "style": dict(HEADER_STYLE)})
        extra.append({"id": txt, "kind": "text",
                      "body": f'# <span style="color: #FFFFFF">{title}</span>'})
        children.append(_gc(hdr, 1, 25, 1, 1 + HEADER_ROWS,
                            _le(txt, 1, 25, 1, 1 + HEADER_ROWS)))
        offset = HEADER_ROWS
    if items:
        offset += 1 - min(i[3] for i in items)
    for n, band in enumerate(_cluster_bands(items), 1):
        cid = f"{pfx}-{n}"
        extra.append({"id": cid, "kind": "container"})
        r0 = min(i[3] for i in band)
        r1 = max(i[4] for i in band)
        inner = "\n".join(_le(i[0], i[1], i[2], i[3] - r0 + 1, i[4] - r0 + 1)
                          for i in band)
        children.append(_gc(cid, 1, 25, r0 + offset, r1 + offset, inner))
    body = "\n".join(children)
    return (f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page_id}">\n{body}\n</Page>', extra)


def build_layout(pages, dossier_name):
    """Banded layout for every workbook page: controls band (split evenly),
    then full-width tables. Header title = the chapter name (never a generic
    "Page N" auto-name — those fall back to the dossier name). Mutates each
    page's elements to add the container/header placeholders and returns the
    layout XML for scripts/put-layout.rb."""
    xml_pages = []
    for pg in pages:
        ctls = [e for e in pg["elements"] if e.get("kind") == "control"]
        tables = [e for e in pg["elements"] if e.get("kind") != "control"]
        items, row = [], 1
        if ctls:
            w = 24 // len(ctls)
            for i, e in enumerate(ctls):
                c0 = 1 + i * w
                c1 = c0 + w if i < len(ctls) - 1 else 25
                items.append([e["id"], c0, c1, row, row + 3])
            row += 3
        for e in tables:
            items.append([e["id"], 1, 25, row, row + 12])
            row += 12
        title = pg["name"]
        if not title or GENERIC_TITLE.match(title.strip()):
            title = dossier_name
        xml, extra = banded_page(pg["id"], items, title)
        pg["elements"] = pg["elements"] + extra
        xml_pages.append(xml)
    return ('<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(xml_pages))


def build_dm_spec(b: Bundle, args, inode_map, ae_winners=None):
    conn = args.connection_id
    elements = []
    el_id = {}    # tid -> element id
    el_name = {}  # tid -> element name (= logical table name)

    def col_id(tid, col):
        tail = inode_map.get(b.table_info[tid]["tableName"])
        if tail:
            return f"inode-{tail}/{col}"
        return f"{slug(b.table_info[tid]['name'])}-{slug(col)}"

    for tid, info in b.table_info.items():
        eid = f"el-{slug(info['name'])}"
        el_id[tid], el_name[tid] = eid, info["name"]
        cols = b.table_columns(tid)
        elements.append({
            "id": eid,
            "kind": "table",
            "name": info["name"],
            "source": {
                "kind": "warehouse-table",
                "connectionId": conn,
                "path": [args.database, info["namespace"], info["tableName"]],
            },
            "columns": [
                {
                    "id": col_id(tid, c),
                    "name": friendly(c),
                    "formula": f"[{info['tableName']}/{friendly(c)}]",
                }
                for c in cols
            ],
        })

    # ---- join element (the consumable "Orders" view)
    joins = b.derive_joins()
    join_legs = [
        {
            "left": {"kind": "table", "elementId": el_id[b.fact_tid]},
            "right": {"kind": "table", "elementId": el_id[j["lookup_tid"]]},
            "columns": [{
                "left": f"[{friendly(j['fact_col'])}]",
                "right": f"[{friendly(j['lookup_col'])}]",
            }],
            "joinType": "left-outer",
        }
        for j in joins
    ]

    join_cols = []
    seen_names = set()

    def add_join_col(src_tid, col):
        name = friendly(col)
        if name in seen_names:
            return
        seen_names.add(name)
        join_cols.append({
            "id": f"ord-{slug(col)}",
            "name": name,
            "formula": f"[{el_name[src_tid]}/{name}]",
        })

    join_key_lookup_cols = {(j["lookup_tid"], j["lookup_col"]) for j in joins}
    # fact columns first (skip nothing on the fact side)
    for c in b.table_columns(b.fact_tid):
        add_join_col(b.fact_tid, c)
    # dim columns, skipping each join's own key column on the lookup side
    for j in joins:
        for c in b.table_columns(j["lookup_tid"]):
            if (j["lookup_tid"], c) in join_key_lookup_cols:
                continue
            add_join_col(j["lookup_tid"], c)

    # ---- metrics on the join element
    def dm_ref(col_friendly):
        return f"[{col_friendly}]"

    metrics = []
    for mid, m in b.metrics.items():
        md = {
            "id": f"m-{slug(m['information']['name'])}",
            "name": m["information"]["name"],
            "formula": b.metric_formula(mid, dm_ref, expand_metrics=False),
        }
        fmt = b.metric_display_format(mid)
        if fmt:
            md["format"] = fmt
        metrics.append(md)

    elements.append({
        "id": "el-orders",
        "kind": "table",
        "name": args.join_element_name,
        "source": {
            "kind": "join",
            "joins": join_legs,
            "primarySource": {"kind": "table", "elementId": el_id[b.fact_tid]},
        },
        "columns": join_cols,
        "metrics": metrics,
    })

    # ---- AE-emulation sql elements (MicroStrategy non-unique-key collapse)
    report_by_name = {r["information"]["name"]: r for r in b.reports.values()}
    for rname, cfg in (ae_winners or {}).items():
        report = report_by_name[rname]
        attr_units, metric_units = b.report_attr_units(report)
        aliases = ([friendly(c) for c in cfg["parentKeyCols"]]
                   + [friendly(cfg["quirkKeyCol"]), friendly(cfg["quirkDescCol"])]
                   + [el["name"] for el in metric_units])
        elements.append({
            "id": f"el-ae-{slug(rname)}",
            "kind": "table",
            "name": ae_element_name(rname),
            "source": {
                "kind": "sql",
                "connectionId": args.connection_id,
                "statement": b.build_ae_sql(args.database, report, cfg),
            },
            "columns": [
                {"id": f"ae-{slug(rname)}-{slug(a)}", "name": a,
                 "formula": f"[Custom SQL/{a}]"}
                for a in aliases
            ],
        })

    return {
        "name": args.dm_name,
        "folderId": args.folder_id,
        "schemaVersion": 1,
        "pages": [{"id": "page-1", "name": "Model", "elements": elements}],
    }


def build_ae_page(b: Bundle, args, ch_name, report, cfg, dm_id, el_ref,
                  report_keys):
    """Page backed by the AE-emulation sql element. Groups by parent keys +
    quirk key; label and metric values are already representative-resolved
    in the element's SQL, so metric columns aggregate the (single) row with
    Sum() and the label with Max()."""
    rname = report["information"]["name"]
    el_name = ae_element_name(rname)
    _attr_units, metric_units = b.report_attr_units(report)
    qkey_f = friendly(cfg["quirkKeyCol"])
    qdesc_f = friendly(cfg["quirkDescCol"])
    parent_f = [friendly(c) for c in cfg["parentKeyCols"]]

    columns, group_ids, calc_ids = [], [], []
    for p in parent_f:
        cid = f"c-{slug(ch_name)}-{slug(p)}"
        columns.append({"id": cid, "name": p, "formula": f"[{el_name}/{p}]"})
        group_ids.append(cid)
    kid = f"c-{slug(ch_name)}-{slug(qkey_f)}"
    columns.append({"id": kid, "name": qkey_f,
                    "formula": f"[{el_name}/{qkey_f}]"})
    group_ids.append(kid)
    did = f"c-{slug(ch_name)}-{slug(qdesc_f)}"
    columns.append({"id": did, "name": qdesc_f,
                    "formula": f"Max([{el_name}/{qdesc_f}])"})
    calc_ids.append(did)
    for el in metric_units:
        mname = el["name"]
        cid = f"c-{slug(ch_name)}-{slug(mname)}"
        col = {"id": cid, "name": mname,
               "formula": f"Sum([{el_name}/{mname}])"}
        fmt = b.metric_display_format(el["id"])
        if fmt:
            col["format"] = fmt
        columns.append(col)
        calc_ids.append(cid)

    report_keys[rname] = parent_f + [qdesc_f]
    return {
        "id": f"pg-{slug(ch_name)}",
        "name": ch_name,
        "elements": [{
            "id": f"tbl-{slug(ch_name)}",
            "kind": "table",
            "name": rname,
            "source": {"kind": "data-model", "dataModelId": dm_id,
                       "elementId": el_ref(el_name)},
            "columns": columns,
            "groupings": [{
                "id": f"g-{slug(ch_name)}",
                "groupBy": group_ids,
                "calculations": calc_ids,
            }],
        }],
    }


def build_workbook_spec(b: Bundle, args, ae_winners=None, dm_element_ids=None):
    dm_id = args.data_model_id or "{{DATA_MODEL_ID}}"
    dm_element_ids = dm_element_ids or {}
    join_name = args.join_element_name

    def el_ref(name):
        if name == join_name and args.orders_element_id:
            return args.orders_element_id
        return dm_element_ids.get(name, "{{ELEMENT_" + slug(name) + "}}")

    def wb_ref(col_friendly):
        return f"[{join_name}/{col_friendly}]"

    pages = []
    report_keys = {}  # report name -> ordered display column names of its keys
    page_ctx = {}     # chapter name -> {page, element, ref, available}
    avail_join = join_column_names(b)
    # chapter -> dataset/report mapping comes from the dossier datasets by name
    report_by_name = {r["information"]["name"]: (rid, r)
                      for rid, r in b.reports.items()}
    # chapters whose element a control/selector filters. A Sigma list control
    # sources its value list from a TABLE element, not a chart — so a charted
    # chapter that has such a control would POST-fail ("Dependency not found").
    # Ship-safe: keep those chapters as tables (data preserved) + warn, until
    # chart+control composition (a hidden control-source table) lands. beads-sigma-kvza.
    _controlled_chapters = {s.get("chapter") for s in b.filter_signals()
                            if s.get("kind") in ("chapter-filter", "selector")}
    for ch in b.dossier["chapters"]:
        ch_name = ch["name"]
        rid, report = report_by_name[ch_name]
        rname = report["information"]["name"]
        units = report["dataSource"]["dataTemplate"]["units"]

        if ae_winners and rname in ae_winners:
            page = build_ae_page(b, args, ch_name, report,
                                 ae_winners[rname], dm_id, el_ref,
                                 report_keys)
            pages.append(page)
            ae_name = ae_element_name(rname)
            cfg = ae_winners[rname]
            _au, metric_units = b.report_attr_units(report)
            ae_avail = ({friendly(c) for c in cfg["parentKeyCols"]}
                        | {friendly(cfg["quirkKeyCol"]),
                           friendly(cfg["quirkDescCol"])}
                        | {el["name"] for el in metric_units})
            page_ctx[ch_name] = {
                "page": page, "element": page["elements"][0],
                "ref": (lambda n, _e=ae_name: f"[{_e}/{n}]"),
                "available": ae_avail,
            }
            continue

        columns, group_ids, calc_ids, key_names = [], [], [], []
        metric_ids = []  # metric columns only (for a chart yAxis; excludes DESC-label calcs)
        filters = []
        for u in units:
            if u.get("type") == "attribute":
                key_col, desc_col = b.attribute_unit_cols(u["id"])
                cid = f"c-{slug(ch_name)}-{slug(key_col)}"
                columns.append({
                    "id": cid,
                    "name": friendly(key_col),
                    "formula": wb_ref(friendly(key_col)),
                })
                group_ids.append(cid)
                # MicroStrategy inner-joins the lookup table, so fact rows
                # with no matching dim row never appear in its grid. The DM
                # join is left-outer (other reports need all fact rows), so
                # drop the null group keys per-element to mirror MSTR.
                a = b.attributes[u["id"]]
                if a["attributeLookupTable"]["objectId"] != b.fact_tid:
                    filters.append({
                        "id": f"f-{slug(ch_name)}-{slug(key_col)}",
                        "columnId": cid,
                        "kind": "list",
                        "mode": "exclude",
                        "values": [None],
                    })
                if desc_col:
                    # DESC label rendered per key element = Max over fact rows
                    did = f"c-{slug(ch_name)}-{slug(desc_col)}"
                    columns.append({
                        "id": did,
                        "name": friendly(desc_col),
                        "formula": f"Max({wb_ref(friendly(desc_col))})",
                    })
                    calc_ids.append(did)
                    key_names.append(friendly(desc_col))
                else:
                    key_names.append(friendly(key_col))
            elif u.get("type") == "metrics":
                for el in u["elements"]:
                    mid = el["id"]
                    mname = b.metrics[mid]["information"]["name"]
                    cid = f"c-{slug(ch_name)}-{slug(mname)}"
                    col = {
                        "id": cid,
                        "name": mname,
                        "formula": b.metric_formula(mid, wb_ref,
                                                    expand_metrics=True),
                    }
                    fmt = b.metric_display_format(mid)
                    if fmt:
                        col["format"] = fmt
                    columns.append(col)
                    calc_ids.append(cid)
                    metric_ids.append(cid)

        report_keys[report["information"]["name"]] = key_names
        # viz-kind (beads-sigma-kvza): resolve the chapter's primary dossier
        # visualizationType through the catalog. bar/line/area with a dim + a
        # measure emit the matching Sigma CHART (dim -> xAxis, metrics -> yAxis);
        # grid/compound/heat_map -> table; an unmapped type or a chart type with
        # no wired emission -> table + a LOUD warning (data preserved, never a
        # silent wrong chart).
        _viz = primary_viz_type(ch)
        _vrow = VIZ_CAT.resolve(_viz)
        _kind = _vrow["sigma"] if _vrow else None
        _base = {
            "id": f"tbl-{slug(ch_name)}",
            "kind": "table",
            "name": report["information"]["name"],
            "source": {
                "kind": "data-model",
                "dataModelId": dm_id,
                "elementId": el_ref(join_name),
            },
            "columns": columns,
        }
        _chartable = _kind in CHART_KINDS and group_ids and metric_ids
        if _chartable and ch_name in _controlled_chapters:
            # a chart can't be a list control's value source — keep the table + say so
            b.warnings.append("chapter %r: %s chart has a control/selector filtering it — a "
                              "Sigma list control can't source values from a chart, so it was "
                              "emitted as a table (data preserved); chart+control composition is "
                              "a tracked follow-up." % (ch_name, _viz))
            _chartable = False
        if _chartable:
            # keep the base element id (tbl-<ch>) so the layout XML + control
            # targets still resolve — only the kind + axes change.
            element = dict(_base)
            element["kind"] = _kind
            element["xAxis"] = {"columnId": group_ids[0]}   # primary attribute -> x
            element["yAxis"] = {"columnIds": metric_ids}     # metrics only (not DESC-label calcs)
        else:
            if _vrow is None:
                VIZ_CAT.resolve_or_warn(_viz, b.warnings, context="chapter %r" % ch_name)
            elif _kind in CHART_KINDS and not (ch_name in _controlled_chapters):
                b.warnings.append("chapter %r: %s chart needs a dimension + a measure to "
                                  "bind axes — emitted a table (data preserved)." % (ch_name, _viz))
            elif _kind not in ("table", None):
                b.warnings.append("chapter %r: MSTR visualizationType %r (-> %s) has no wired "
                                  "chart emission yet — emitted a table (data preserved)."
                                  % (ch_name, _viz, _kind))
            element = dict(_base)
            element["groupings"] = [{
                "id": f"g-{slug(ch_name)}",
                "groupBy": group_ids,
                "calculations": calc_ids,
            }]
        if filters:
            element["filters"] = filters
        page = {
            "id": f"pg-{slug(ch_name)}",
            "name": ch_name,
            "elements": [element],
        }
        pages.append(page)
        page_ctx[ch_name] = {"page": page, "element": element,
                             "ref": wb_ref, "available": avail_join}

    # dossier selectors / chapter filters -> Sigma controls (+ sidecar data),
    # then the banded layout (mutates pages: containers + header text)
    warnings = []
    n_signals, scope_entries, unbound = emit_controls(b, pages, page_ctx,
                                                      warnings)
    layout_xml = build_layout(pages, b.dossier.get("name", "MicroStrategy"))
    control_scope = {"version": 1, "source": "microstrategy",
                     "sourceFilterSignals": n_signals,
                     "controls": scope_entries, "unbound": unbound}

    return {
        "name": args.wb_name,
        "folderId": args.folder_id,
        "schemaVersion": 1,
        "pages": pages,
    }, report_keys, layout_xml, control_scope, warnings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", default="bundle.json")
    ap.add_argument("--connection-id", required=True)
    ap.add_argument("--database", required=True,
                    help="warehouse database the Sigma connection reads")
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--inode-map", default=None,
                    help="JSON file: physical table name -> inode tail")
    ap.add_argument("--dm-name", default=None,
                    help="default: '<dossier name> (MSTR Model)'")
    ap.add_argument("--wb-name", default=None,
                    help="default: '<dossier name> (MSTR)'")
    ap.add_argument("--join-element-name", default="Orders")
    ap.add_argument("--data-model-id", default=None)
    ap.add_argument("--orders-element-id", default=None)
    ap.add_argument("--dm-element-ids", default=None,
                    help="JSON file: DM element name -> server element id")
    ap.add_argument("--ae-winners", default=None,
                    help="ae_winners.json from resolve_ae_winners.py")
    ap.add_argument("--out-dm", default="sigma_dm_spec.json")
    ap.add_argument("--out-wb", default="sigma_workbook_spec.json")
    ap.add_argument("--out-layout", default="layout.xml",
                    help="banded layout XML for scripts/put-layout.rb")
    ap.add_argument("--control-scope-out", default="control-scope.json",
                    help="intended-scope contract for the control lint "
                         "(scripts/lib/control_lint.rb CONTRACT)")
    args = ap.parse_args()

    b = Bundle(json.load(open(args.bundle)))
    dossier_name = b.dossier.get("name", "MicroStrategy")
    args.dm_name = args.dm_name or f"{dossier_name} (MSTR Model)"
    args.wb_name = args.wb_name or f"{dossier_name} (MSTR)"
    inode_map = json.load(open(args.inode_map)) if args.inode_map else {}
    ae_winners = json.load(open(args.ae_winners)) if args.ae_winners else None
    dm_element_ids = (json.load(open(args.dm_element_ids))
                      if args.dm_element_ids else None)

    dm = build_dm_spec(b, args, inode_map, ae_winners)
    wb, report_keys, layout_xml, control_scope, warnings = \
        build_workbook_spec(b, args, ae_winners, dm_element_ids)
    json.dump(dm, open(args.out_dm, "w"), indent=1)
    json.dump(wb, open(args.out_wb, "w"), indent=1)
    json.dump(report_keys, open("parity_keys.json", "w"), indent=1)
    open(args.out_layout, "w").write(layout_xml)
    json.dump(control_scope, open(args.control_scope_out, "w"), indent=1)

    print(f"fact table: {b.table_info[b.fact_tid]['name']}")
    for j in b.derive_joins():
        print(f"join: {b.table_info[b.fact_tid]['tableName']}.{j['fact_col']} = "
              f"{b.table_info[j['lookup_tid']]['tableName']}.{j['lookup_col']}")
    for el in dm["pages"][0]["elements"]:
        for m in el.get("metrics", []):
            print(f"metric: {m['name']} = {m['formula']}")
    for c in control_scope["controls"]:
        print(f"control: {c['controlId']} ({c['controlType']}) -> "
              f"{[w['elementId'] for w in c['wired']]} scope={c['scope']}")
    for u in control_scope["unbound"]:
        print(f"control UNBOUND [{u['status']}]: {u['sourceName']} — {u['reason']}")
    # LOUD fallbacks: the catalog resolvers append to b.warnings (aggregation /
    # number-format, from build_dm_spec + build_workbook_spec) and to `warnings`
    # (control, from emit_controls). Print the deduped union.
    for w in dict.fromkeys(list(b.warnings) + list(warnings)):
        print(f"WARN: {w}")
    print(f"signals: {control_scope['sourceFilterSignals']} filter signal(s), "
          f"{len(control_scope['controls'])} control(s) emitted")
    print(f"wrote {args.out_dm}, {args.out_wb}, {args.out_layout}, "
          f"{args.control_scope_out}")


if __name__ == "__main__":
    main()
