#!/usr/bin/env python3
"""Build deterministic, full-app Qlik migration accounting artifacts.

The source inventory is authoritative: every discovered app object receives
exactly one terminal status and evidence. Missing target evidence is represented
as ``needs-review`` *and* an unaccounted diagnostic, so downstream reporting can
remain structurally complete while the command fails closed.
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path


TERMINAL = ("migrated", "approximated", "needs-review", "skipped", "not-applicable")
PROVENANCE = ("live", "engine-export", "inferred")
PASS = {
    "pass", "passed", "green", "ok", "success", "successful", "match",
    "matched", "exact",
}
APPROX = {"approximate", "approximated", "partial", "degraded", "substituted", "fallback"}
SKIP = {"skip", "skipped", "dropped", "omitted", "not-emitted", "excluded"}
REVIEW = {"review", "needs-review", "blocked", "unresolved", "failed", "fail", "error", "manual"}
STRUCTURAL = {
    "sheet", "singlepublic", "appprops", "loadmodel", "measure", "dimension",
    "masterobject", "sheetlist",
    # app metadata objects (Insight Advisor logical model, master-item color map)
    "businessmodel", "colormap",
}
# Queryable-looking object kinds the pipeline does not rebuild: each gets an
# explicit, reasoned `skipped` disposition instead of an unaccounted error.
NO_SIGMA_EQUIVALENT = {
    "story": "Qlik storytelling has no Sigma equivalent; not migrated",
    "slide": "Qlik story slide has no Sigma equivalent; not migrated",
    "action-button": "Qlik action button (variable/navigation actions) is not auto-migrated; "
                     "Sigma page tabs replace sheet navigation — re-author any needed button actions",
}
CONTROL_KINDS = {"filterpane", "listbox"}
TEXT_KINDS = {"text-image", "text", "image"}


class InputError(Exception):
    pass


def fold(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def status_class(value):
    word = str(value or "").strip().lower().replace("_", "-").replace(" ", "-")
    if word in PASS:
        return "migrated"
    if word in APPROX:
        return "approximated"
    if word in SKIP:
        return "skipped"
    if word in REVIEW:
        return "needs-review"
    if word in TERMINAL:
        return word
    return None


def read_json(path):
    if path is None:
        return None
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise InputError("malformed JSON %s: %s" % (path, exc)) from exc
    except OSError as exc:
        raise InputError("cannot read %s: %s" % (path, exc)) from exc


def artifact(workdir, explicit, names, required=False):
    if explicit:
        path = Path(explicit)
        path = path if path.is_absolute() else workdir / path
        if not path.is_file():
            raise InputError("artifact does not exist: %s" % path)
        return path.resolve()
    for name in names:
        matches = sorted(p for p in workdir.glob(name) if p.is_file())
        if matches:
            return matches[0].resolve()
    if required:
        raise InputError("required artifact not found (tried %s)" % ", ".join(names))
    return None


def root(doc):
    if not isinstance(doc, dict):
        return {}
    return doc.get("document") if isinstance(doc.get("document"), dict) else doc


def flatten_elements(doc):
    value = root(doc)
    rows = [row for row in value.get("elements") or [] if isinstance(row, dict)]
    for page in value.get("pages") or []:
        if isinstance(page, dict):
            rows.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
    return rows


def scalar_names(row):
    if not isinstance(row, dict):
        return set()
    values = []
    for key in ("id", "name", "title", "label", "sourceName", "source_object_id",
                "sourceObjectId", "objectId", "visual"):
        value = row.get(key)
        if value is not None and not isinstance(value, (dict, list)):
            values.append(fold(value))
    return {value for value in values if value}


def scalar_mentions(value, name):
    """Whether an artifact scalar contains an exact source identifier token."""
    if not str(name or "").strip():
        return False
    pattern = re.compile(
        r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(str(name)),
        re.IGNORECASE,
    )
    if isinstance(value, dict):
        return any(scalar_mentions(child, name) for child in value.values())
    if isinstance(value, list):
        return any(scalar_mentions(child, name) for child in value)
    return isinstance(value, str) and bool(pattern.search(value))


def mapping_rows(doc):
    if isinstance(doc, list):
        return [row for row in doc if isinstance(row, dict)]
    if not isinstance(doc, dict):
        return []
    for key in ("mappings", "formulas", "objects", "records", "items"):
        if isinstance(doc.get(key), list):
            return [row for row in doc[key] if isinstance(row, dict)]
    return []


def parity_pass(doc):
    if not isinstance(doc, dict):
        return False
    state = str(doc.get("status") or doc.get("verdict") or "").strip().lower()
    total = doc.get("charts_total")
    passed = doc.get("charts_pass")
    return (
        state in PASS
        and isinstance(total, int)
        and total > 0
        and passed == total
        and not (doc.get("fail_names") or [])
        and doc.get("strict", True) is not False
    )


class Accounting:
    def __init__(self, workdir, paths, docs):
        self.workdir = workdir
        self.paths = paths
        self.docs = docs
        self.objects = OrderedDict()
        self.errors = []
        self.unaccounted = set()
        self.contradictory = set()
        self.wb_elements = flatten_elements(docs.get("wb_readback") or docs.get("wb_spec") or {})
        self.wb_pages = [
            row for row in root(docs.get("wb_readback") or docs.get("wb_spec") or {}).get("pages") or []
            if isinstance(row, dict)
        ]
        self.dm_elements = flatten_elements(docs.get("dm_readback") or docs.get("dm_spec") or {})
        dm_doc = docs.get("dm_readback") or docs.get("dm_spec") or {}
        wb_doc = docs.get("wb_readback") or docs.get("wb_spec") or {}
        self.dm_doc = dm_doc
        self.wb_doc = wb_doc
        self.parity_ok = parity_pass(docs.get("parity"))
        self.formulas = mapping_rows(docs.get("formula_mapping"))
        self.formula_index = {}
        for row in self.formulas:
            for name in scalar_names(row):
                self.formula_index.setdefault(name, []).append(row)
        self.element_map = docs.get("element_map") if isinstance(docs.get("element_map"), list) else []
        self.coverage_input = docs.get("workbook_coverage") or {}
        self.scope = docs.get("control_scope") or {}
        self.chart_by_id = {
            str(row.get("id")): row for row in docs["charts"]
            if isinstance(row, dict) and row.get("id") is not None
        }

    def artifact_name(self, kind):
        path = self.paths.get(kind)
        if path is None:
            return kind
        try:
            return str(path.relative_to(self.workdir))
        except ValueError:
            return str(path)

    def evidence(self, kind, detail):
        return {"artifact": self.artifact_name(kind), "detail": str(detail)}

    def add(self, obj_type, obj_id, name, provenance, kind, detail, **meta):
        if provenance not in PROVENANCE:
            raise AssertionError("invalid provenance")
        key = (str(obj_type), str(obj_id))
        if key in self.objects:
            obj = self.objects[key]
            obj["_evidence"].append(self.evidence(kind, detail))
            return obj
        obj = {
            "type": str(obj_type),
            "id": str(obj_id),
            "name": str(name or obj_id),
            "source_provenance": provenance,
            "_evidence": [self.evidence(kind, detail)],
            "_meta": meta,
            "_signals": [],
            "_accounted": True,
        }
        self.objects[key] = obj
        return obj

    def signal(self, obj, value, kind, detail):
        status = status_class(value)
        if status:
            obj["_signals"].append((status, self.evidence(kind, detail)))

    def unaccount(self, obj, detail):
        obj["_accounted"] = False
        self.unaccounted.add(obj["id"])
        self.errors.append("unaccounted: %s:%s — %s" % (obj["type"], obj["id"], detail))
        obj["_evidence"].append(self.evidence("accounting", detail))

    def contradict(self, obj, detail):
        self.contradictory.add(obj["id"])
        self.errors.append("contradiction: %s" % detail)
        obj["_evidence"].append(self.evidence("accounting", "contradiction: " + detail))

    def inventory(self):
        converter = self.docs["converter"]
        charts = self.docs["charts"]
        layout = self.docs["layout"]
        app_meta = self.docs.get("app_meta") or {}
        app_name = app_meta.get("name") or converter.get("appName") or "Qlik app"
        app_id = app_meta.get("id") or app_meta.get("resourceId") or converter.get("appId") or app_name
        app_provenance = "live" if app_meta.get("id") or app_meta.get("resourceId") else "engine-export"
        self.add("app", "app:%s" % app_id, app_name, app_provenance, "app_meta",
                 "Qlik app discovery record")

        for table in converter.get("tables") or []:
            if not isinstance(table, dict):
                continue
            table_name = table.get("name")
            if not table_name:
                continue
            self.add("source-table", "table:%s" % table_name, table_name, "engine-export",
                     "converter", "source table with %d field(s)" % len(table.get("fields") or []),
                     table=table_name)
            seen = Counter()
            for field in table.get("fields") or []:
                if isinstance(field, str):
                    field = {"name": field}
                if not isinstance(field, dict) or not field.get("name"):
                    continue
                field_name = str(field["name"])
                seen[field_name] += 1
                suffix = "" if seen[field_name] == 1 else ":%d" % seen[field_name]
                self.add("source-field", "field:%s.%s%s" % (table_name, field_name, suffix),
                         "%s.%s" % (table_name, field_name), "engine-export", "converter",
                         "field in source table %s" % table_name, table=table_name,
                         field=field_name, record=field)

        for index, sheet in enumerate(layout):
            if not isinstance(sheet, dict):
                continue
            sheet_id = sheet.get("sheetId") or sheet.get("id") or "sheet-%d" % index
            self.add("sheet", "sheet:%s" % sheet_id, sheet.get("title") or sheet_id,
                     "engine-export", "layout", "authored Qlik sheet", record=sheet)

        for index, chart in enumerate(charts):
            if not isinstance(chart, dict):
                continue
            chart_id = chart.get("id") or "object-%d" % index
            title = chart.get("title") or chart_id
            self.add("inline-visual", "visual:%s" % chart_id, title, "engine-export",
                     "charts", "Qlik object type=%s" % (chart.get("vizType") or "unknown"),
                     record=chart, object_id=str(chart_id))

        for kind, obj_type in (("measures", "master-measure"), ("dimensions", "master-dimension")):
            for index, item in enumerate(self.docs.get(kind) or []):
                if not isinstance(item, dict):
                    continue
                item_id = item.get("id") or item.get("title") or "%s-%d" % (kind, index)
                self.add(obj_type, "%s:%s" % (obj_type, item_id), item.get("title") or item_id,
                         "engine-export", kind, "Qlik master item", record=item)

        script = self.docs.get("script") or ""
        discovered_variables = []
        for owner in (converter, app_meta):
            if not isinstance(owner, dict):
                continue
            for key in ("variables", "appVariables", "masterVariables"):
                discovered_variables.extend(
                    row for row in owner.get(key) or [] if isinstance(row, dict)
                )
        for index, variable in enumerate(discovered_variables):
            name = variable.get("name") or variable.get("id") or "variable-%d" % index
            expression = (
                variable.get("expression") or variable.get("definition")
                or variable.get("value") or ""
            )
            self.add(
                "variable", "variable:%s" % name, name, "engine-export",
                "converter" if variable in (converter.get("variables") or []) else "app_meta",
                "Qlik variable discovered through the engine export",
                expression=str(expression),
            )
        for match in re.finditer(r"(?im)^\s*(SET|LET)\s+([A-Za-z_][\w.]*)\s*=\s*(.*?);", script):
            mode, name, expression = match.groups()
            self.add("variable", "variable:%s" % name, name, "inferred", "script",
                     "%s variable parsed from load script" % mode.upper(), expression=expression)

        states = {}
        for owner in (converter, app_meta):
            if not isinstance(owner, dict):
                continue
            for state in owner.get("alternateStates") or owner.get("states") or []:
                if isinstance(state, dict):
                    state = state.get("name") or state.get("id")
                if state and str(state).strip() not in ("$", "1"):
                    states.setdefault(str(state), []).append("app discovery")
        for chart in charts:
            if not isinstance(chart, dict):
                continue
            state = chart.get("state")
            if isinstance(chart.get("listbox"), dict):
                state = chart["listbox"].get("state") or state
            if state and str(state).strip() not in ("$", "1"):
                states.setdefault(str(state), []).append(str(chart.get("id") or chart.get("title")))
        for state, owners in sorted(states.items()):
            self.add("alternate-state", "alternate-state:%s" % state, state, "engine-export",
                     "charts", "alternate state used by %s" % ", ".join(owners), owners=owners)

        has_section = (
            app_meta.get("hasSectionAccess") is True
            or bool(re.search(r"(?im)^\s*SECTION\s+ACCESS\s*;", script))
        )
        self.add("security", "security:section-access", "Section Access / row security",
                 "live" if app_meta.get("hasSectionAccess") is not None else "inferred",
                 "app_meta" if app_meta.get("hasSectionAccess") is not None else "script",
                 "Section Access %s" % ("detected" if has_section else "not detected"),
                 section_access=has_section)

        known_visuals = {str(row.get("id")) for row in charts if isinstance(row, dict)}
        for object_id in self.coverage_input.get("unbuiltSourceVisualIds") or []:
            if str(object_id) not in known_visuals:
                self.add("dropped-object", "dropped:%s" % object_id, object_id,
                         "inferred", "workbook_coverage",
                         "coverage references a dropped source object absent from charts.json",
                         object_id=str(object_id))
        if not self.objects:
            raise InputError("Qlik source artifacts contain no recognizable objects")

    def formula_status(self, obj):
        meta = obj["_meta"]
        names = [obj["id"], obj["name"], meta.get("field")]
        record = meta.get("record") or {}
        names.extend([record.get("id"), record.get("title"), record.get("expr"),
                      record.get("qDef"), record.get("fieldDef")])
        hits = []
        for name in names:
            hits.extend(self.formula_index.get(fold(name), []))
        hits = list({id(row): row for row in hits}.values())
        statuses = {
            status_class(row.get("status") or row.get("mapping") or row.get("outcome"))
            for row in hits
        }
        statuses.discard(None)
        for row in hits:
            obj["_evidence"].append(self.evidence(
                "formula_mapping",
                "formula mapping=%s" % (row.get("status") or row.get("mapping") or row.get("outcome") or "recorded"),
            ))
        if len(statuses) > 1:
            self.contradict(obj, "%s has incompatible formula mapping statuses %s" %
                            (obj["id"], ", ".join(sorted(statuses))))
            return "needs-review"
        return next(iter(statuses)) if statuses else None

    def built_visual(self, obj):
        oid = obj["_meta"].get("object_id")
        chart = obj["_meta"].get("record") or {}
        for row in self.element_map:
            qlik = row.get("qlik") if isinstance(row.get("qlik"), dict) else {}
            if str(qlik.get("objectId")) == str(oid):
                obj["_evidence"].append(self.evidence("element_map", "mapped to Sigma element %s" %
                                                      (row.get("elementId") or row.get("name"))))
                return True
        wanted = {fold(oid), fold(obj["name"])}
        if any(wanted & scalar_names(row) for row in self.wb_elements):
            obj["_evidence"].append(self.evidence("wb_readback" if self.docs.get("wb_readback") else "wb_spec",
                                                  "matching Sigma workbook element"))
            return True
        if str(oid) in set(map(str, self.coverage_input.get("builtSourceVisualIds") or [])):
            obj["_evidence"].append(self.evidence("workbook_coverage", "source visual recorded built"))
            return True
        if str(chart.get("vizType") or "").lower() in CONTROL_KINDS:
            return self.control_status(obj) == "migrated"
        return False

    def control_status(self, obj):
        chart = obj["_meta"].get("record") or {}
        oid = str(chart.get("id") or "")
        names = {fold(oid), fold(obj["name"])}
        if isinstance(chart.get("listbox"), dict):
            names |= {fold(chart["listbox"].get("label")), fold(chart["listbox"].get("field"))}
        rows = list(self.scope.get("controls") or []) + list(self.scope.get("unbound") or []) + list(
            self.scope.get("dropped") or []
        )
        def row_names(row):
            # control-scope sourceName is "<vizType> <objectId> field '<field>'"
            found = scalar_names(row)
            tagged = re.match(r"\s*\S+\s+(\S+)", str(row.get("sourceName") or ""))
            if tagged:
                found.add(fold(tagged.group(1)))
            return found
        matches = [row for row in rows if isinstance(row, dict) and names & row_names(row)]
        if not matches and chart.get("vizType") == "filterpane":
            children = set(map(str, chart.get("children") or []))
            matches = [
                row for row in rows if isinstance(row, dict)
                and ({fold(c) for c in children} & ({fold(row.get("sourceId")), fold(row.get("objectId")),
                                                     fold(row.get("id"))} | row_names(row)))
            ]
        statuses = []
        for row in matches:
            state = str(row.get("status") or "").lower()
            statuses.append("migrated" if state in ("wired", "emitted", "built", "pass") else
                            "skipped" if state in ("dropped", "skipped", "unbound") else "needs-review")
            obj["_evidence"].append(self.evidence("control_scope", "control status=%s" % (state or "recorded")))
        if not statuses:
            return None
        if len(set(statuses)) > 1:
            self.contradict(obj, "control scope gives %s multiple dispositions" % obj["name"])
            return "needs-review"
        return statuses[0]

    def account(self):
        for obj in self.objects.values():
            obj_type = obj["type"]
            meta = obj["_meta"]
            mapping = self.formula_status(obj)
            status = None

            if obj_type == "app":
                built = bool(self.wb_pages and self.dm_elements)
                status = "migrated" if built and self.parity_ok else "needs-review"
                if built:
                    obj["_evidence"].append(self.evidence("parity", "built app has %s final parity" %
                                                          ("passing" if self.parity_ok else "non-passing")))
                else:
                    self.unaccount(obj, "app has no complete DM + workbook target")
            elif obj_type == "source-table":
                built = bool(self.dm_elements) and (
                    scalar_mentions(self.dm_doc, meta.get("table"))
                    or bool(self.docs.get("denorm"))
                    or bool(self.docs.get("converter_out"))
                )
                status = "migrated" if built and self.parity_ok else "needs-review"
                if built:
                    obj["_evidence"].append(self.evidence("dm_readback" if self.docs.get("dm_readback") else "dm_spec",
                                                          "table contributes to built data model"))
                else:
                    self.unaccount(obj, "source table has no matching built data-model evidence")
            elif obj_type == "source-field":
                built = scalar_mentions(self.dm_doc, meta.get("field"))
                if mapping == "skipped":
                    status = "skipped"
                elif mapping in ("approximated", "needs-review"):
                    status = mapping if built or mapping == "needs-review" else "needs-review"
                elif built:
                    status = "migrated" if self.parity_ok else "needs-review"
                    obj["_evidence"].append(self.evidence("dm_readback" if self.docs.get("dm_readback") else "dm_spec",
                                                          "matching field/formula in data model"))
                else:
                    status = "needs-review"
                    self.unaccount(obj, "field has no mapping/omission and no matching built column")
            elif obj_type == "sheet":
                names = {fold(obj["name"]), fold(obj["id"].split(":", 1)[-1])}
                built = any(names & scalar_names(page) for page in self.wb_pages)
                if not built and len(self.wb_pages) == len([
                    row for row in self.objects.values() if row["type"] == "sheet"
                ]):
                    built = True
                status = "migrated" if built and self.parity_ok else "needs-review"
                if built:
                    obj["_evidence"].append(self.evidence("wb_readback" if self.docs.get("wb_readback") else "wb_spec",
                                                          "matching Sigma page"))
                else:
                    self.unaccount(obj, "sheet has no matching Sigma page")
            elif obj_type == "inline-visual":
                chart = meta.get("record") or {}
                kind = str(chart.get("vizType") or "").lower()
                if kind in STRUCTURAL:
                    status = "not-applicable"
                    obj["_evidence"].append(self.evidence("charts", "structural/placeholder object is not a visual"))
                elif kind in NO_SIGMA_EQUIVALENT and not self.built_visual(obj):
                    status = "skipped"
                    obj["_evidence"].append(self.evidence("charts", NO_SIGMA_EQUIVALENT[kind]))
                elif kind in CONTROL_KINDS:
                    status = self.control_status(obj)
                    if status is None:
                        status = "needs-review"
                        self.unaccount(obj, "source control has no control-scope disposition")
                elif kind in TEXT_KINDS:
                    status = "migrated" if self.built_visual(obj) else "skipped"
                    if status == "skipped":
                        obj["_evidence"].append(self.evidence("workbook_coverage",
                                                              "content object not present in workbook"))
                else:
                    built = self.built_visual(obj)
                    if mapping == "skipped":
                        status = "skipped"
                    elif mapping == "approximated" and built:
                        status = "approximated" if self.parity_ok else "needs-review"
                    elif built:
                        status = "migrated" if self.parity_ok else "needs-review"
                        obj["_evidence"].append(self.evidence(
                            "parity", "visual %s final measured parity" %
                            ("passed" if self.parity_ok else "did not pass"),
                        ))
                    elif str(meta.get("object_id")) in set(map(str, self.coverage_input.get("unbuiltSourceVisualIds") or [])):
                        status = "skipped"
                        obj["_evidence"].append(self.evidence("workbook_coverage",
                                                              "source visual explicitly recorded unbuilt"))
                    else:
                        status = "needs-review"
                        self.unaccount(obj, "visual has no explicit omission or matching Sigma element")
            elif obj_type in ("master-measure", "master-dimension"):
                record = meta.get("record") or {}
                expression = record.get("expr") or record.get("qDef") or record.get("fieldDef")
                built = scalar_mentions(self.dm_doc, obj["name"]) or (
                    expression and scalar_mentions(self.dm_doc, expression)
                )
                if mapping == "skipped":
                    status = "skipped"
                elif mapping == "approximated":
                    status = "approximated" if built and self.parity_ok else "needs-review"
                elif mapping == "needs-review":
                    status = "needs-review"
                elif built:
                    status = "migrated" if self.parity_ok else "needs-review"
                    obj["_evidence"].append(self.evidence("dm_spec", "master item emitted in data model"))
                elif expression and fold(expression) not in fold(json.dumps(self.docs["charts"], sort_keys=True)):
                    status = "not-applicable"
                    obj["_evidence"].append(self.evidence("charts", "unused master item has no workbook impact"))
                else:
                    status = "needs-review"
                    self.unaccount(obj, "used master item has no formula mapping or built target")
            elif obj_type == "variable":
                expression = meta.get("expression")
                script_without_decl = re.sub(
                    r"(?im)^\s*(?:SET|LET)\s+%s\s*=.*?;" % re.escape(obj["name"]), "", self.docs.get("script") or ""
                )
                used = bool(re.search(r"\$\(\s*%s\s*\)" % re.escape(obj["name"]), script_without_decl, re.I))
                built = scalar_mentions(self.dm_doc, obj["name"]) or scalar_mentions(
                    self.wb_doc, obj["name"]
                )
                if mapping == "skipped":
                    status = "skipped"
                elif mapping in ("approximated", "needs-review"):
                    status = mapping
                elif not used:
                    status = "not-applicable"
                    obj["_evidence"].append(self.evidence("script", "variable is declared but unused"))
                elif built:
                    status = "migrated" if self.parity_ok else "needs-review"
                    obj["_evidence"].append(self.evidence("dm_spec", "variable dependency represented in target"))
                else:
                    status = "needs-review"
                    self.unaccount(obj, "used variable has no formula-mapping or target evidence")
            elif obj_type == "alternate-state":
                status = "needs-review"
                obj["_evidence"].append(self.evidence("control_scope",
                                                      "alternate selection state requires explicit Sigma design"))
            elif obj_type == "security":
                if not meta.get("section_access"):
                    status = "not-applicable"
                else:
                    security_docs = [
                        self.workdir / "rls-result.json", self.workdir / "security-result.json",
                        self.workdir / "rls-applied.json",
                    ]
                    applied = any(path.is_file() and status_class((read_json(path) or {}).get("status")) == "migrated"
                                  for path in security_docs)
                    status = "migrated" if applied else "needs-review"
                    obj["_evidence"].append(self.evidence(
                        "security", "Section Access %s" % ("has applied Sigma RLS evidence" if applied else
                                                           "requires RLS migration and validation"),
                    ))
            elif obj_type == "dropped-object":
                status = "skipped"
            else:
                status = "needs-review"
                self.unaccount(obj, "unknown source object type")

            if status not in TERMINAL:
                raise AssertionError("no terminal status for %s" % obj["id"])
            obj["status"] = status

    def outputs(self):
        public = []
        for obj in sorted(self.objects.values(), key=lambda row: (fold(row["type"]), fold(row["id"]))):
            unique = {
                (row["artifact"], row["detail"]): row
                for row in obj["_evidence"] if row.get("artifact") and row.get("detail")
            }
            public.append({
                "type": obj["type"],
                "id": obj["id"],
                "name": obj["name"],
                "status": obj["status"],
                "source_provenance": obj["source_provenance"],
                "evidence": [unique[key] for key in sorted(unique)],
            })
        counts = {status: sum(row["status"] == status for row in public) for status in TERMINAL}
        diagnostics = {
            "errors": sorted(set(self.errors)),
            "unaccounted": sorted(self.unaccounted),
            "contradictory": sorted(self.contradictory),
        }
        census = {
            "schema_version": 1,
            "source": "qlik",
            "summary": {
                "total": len(public),
                "accounted": len(public) - len(self.unaccounted),
                "complete": not self.errors,
                "counts": counts,
            },
            "objects": public,
            "inputs": [
                {"kind": kind.replace("_", "-"), "path": self.artifact_name(kind),
                 "present": path is not None}
                for kind, path in sorted(self.paths.items())
            ],
            "diagnostics": diagnostics,
        }
        coverage = self.coverage(public, diagnostics)
        controls = self.controls(public, diagnostics)
        tiles, layout_census = self.tiles()
        return census, coverage, controls, tiles, layout_census

    def coverage(self, public, diagnostics):
        prior = dict(self.coverage_input) if isinstance(self.coverage_input, dict) else {}
        visuals = [row for row in public if row["type"] == "inline-visual"]
        visual_rows = []
        unresolved = []
        for row in visuals:
            visual_rows.append({
                "type": row["type"], "source_object_id": row["id"], "name": row["name"],
                "status": row["status"], "detail": "; ".join(e["detail"] for e in row["evidence"]),
            })
            if row["status"] not in ("migrated", "not-applicable"):
                severity = {
                    "approximated": "approximated", "needs-review": "degraded",
                    "skipped": "dropped",
                }.get(row["status"], "degraded")
                unresolved.append({
                    "visual": row["name"], "source_object_id": row["id"],
                    "severity": severity,
                    "detail": row["evidence"][-1]["detail"],
                    "recoverable": row["status"] == "needs-review",
                    "role_class": "chart",
                })
        summary = {
            "sourceVisuals": len(visuals),
            "builtElements": sum(row["status"] in ("migrated", "approximated") for row in visuals),
            "dropped": sum(row["severity"] == "dropped" for row in unresolved),
            "degraded": sum(row["severity"] == "degraded" for row in unresolved),
            "approximated": sum(row["severity"] == "approximated" for row in unresolved),
        }
        return {
            "version": 1,
            "source": "qlik",
            "summary": summary,
            "workbook_coverage": prior,
            "unresolved": sorted(unresolved, key=lambda row: (row["severity"], fold(row["visual"]))),
            "objects": [
                {
                    "type": row["type"], "source_object_id": row["id"], "name": row["name"],
                    "status": row["status"], "detail": "; ".join(e["detail"] for e in row["evidence"]),
                }
                for row in public
            ],
            "diagnostics": diagnostics,
        }

    def controls(self, public, diagnostics):
        rows = []
        for row in public:
            if row["type"] not in ("inline-visual", "alternate-state"):
                continue
            source = self.chart_by_id.get(row["id"].split(":", 1)[-1], {})
            if row["type"] == "inline-visual" and str(source.get("vizType") or "").lower() not in CONTROL_KINDS:
                continue
            terminal = row["status"]
            ledger = "emitted" if terminal == "migrated" else "dropped" if terminal == "skipped" else "needs-wiring"
            rows.append({
                "kind": "alternate-state" if row["type"] == "alternate-state" else
                        str(source.get("vizType") or "control"),
                "type": row["type"],
                "id": row["id"],
                "name": row["name"],
                "status": ledger,
                "terminal_status": terminal,
                "detail": row["evidence"][-1]["detail"],
                "evidence": row["evidence"],
            })
        return {
            "version": 1,
            "source": "qlik",
            "summary": {
                "sourceFilters": len(rows),
                "emitted": sum(row["status"] == "emitted" for row in rows),
                "dropped": sum(row["status"] == "dropped" for row in rows),
                "needsWiring": sum(row["status"] == "needs-wiring" for row in rows),
            },
            "detail": sorted(rows, key=lambda row: (fold(row["id"]), fold(row["name"]))),
            "diagnostics": diagnostics,
        }

    def tiles(self):
        zones = []
        pages = []
        for sheet in self.docs["layout"]:
            if not isinstance(sheet, dict):
                continue
            columns = max(float(sheet.get("columns") or 24), 1.0)
            rows = max(float(sheet.get("rows") or 12), 1.0)
            page_zones = []
            for cell in sheet.get("cells") or []:
                if not isinstance(cell, dict):
                    continue
                chart = self.chart_by_id.get(str(cell.get("objectId")))
                if not chart:
                    continue
                kind = str(chart.get("vizType") or "").lower()
                if kind in STRUCTURAL or kind in CONTROL_KINDS or kind in TEXT_KINDS:
                    continue
                zone = {
                    "id": str(chart.get("id") or cell.get("objectId")),
                    "name": str(chart.get("title") or chart.get("id") or cell.get("objectId")),
                    "page": str(sheet.get("sheetId") or sheet.get("title") or "page"),
                    # visual-similarity.py intentionally accepts only broad
                    # chart-ish tile kinds. Preserve the source family
                    # separately instead of emitting "bar"/"line", which the
                    # tile parser correctly treats as an unknown/chrome kind.
                    "kind": "pivot" if kind in ("pivot-table", "pivot") else
                            "table" if kind == "table" else "chart",
                    "chart_kind": "kpi" if not (chart.get("dimensions") or []) else
                                  "line" if "line" in kind else
                                  "pie" if "pie" in kind else kind or "bar",
                    "x_pct": round(float(cell.get("col") or 0) / columns * 100, 4),
                    "y_pct": round(float(cell.get("row") or 0) / rows * 100, 4),
                    "w_pct": round(float(cell.get("colspan") or 1) / columns * 100, 4),
                    "h_pct": round(float(cell.get("rowspan") or 1) / rows * 100, 4),
                }
                zones.append(zone)
                page_zones.append(zone)
            placed = sum(
                1 for zone in page_zones
                if any(str(row.get("qlik", {}).get("objectId")) == zone["id"] for row in self.element_map)
            )
            area = min(1.0, sum(zone["w_pct"] * zone["h_pct"] for zone in page_zones) / 10000.0)
            pages.append({
                "page": str(sheet.get("title") or sheet.get("sheetId") or "page"),
                "page_id": str(sheet.get("sheetId") or ""),
                "zones": len(page_zones),
                "placed": placed,
                "grid_fill_pct": round(area, 4),
                "unplaced_elements": [zone["name"] for zone in page_zones
                                      if not any(str(row.get("qlik", {}).get("objectId")) == zone["id"]
                                                 for row in self.element_map)],
            })
        return zones, {"version": 1, "source": "qlik", "pages": pages}


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


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    for option in (
        "converter-input", "measures", "dimensions", "charts", "layout", "app-meta",
        "script", "formula-mapping", "dm-spec", "dm-readback", "wb-spec", "wb-readback",
        "workbook-coverage", "control-scope", "parity", "element-map", "denorm",
        "converter-out",
    ):
        parser.add_argument("--" + option, dest=option.replace("-", "_"))
    parser.add_argument("--census-out")
    parser.add_argument("--coverage-out")
    parser.add_argument("--controls-out")
    parser.add_argument("--tiles-out")
    parser.add_argument("--layout-census-out")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = parse_args(argv)
        workdir = Path(args.workdir).expanduser().resolve()
        if not workdir.is_dir():
            raise InputError("--workdir is not a directory: %s" % workdir)
        specs = {
            "converter": (args.converter_input, ("converter-input.json",), True),
            "measures": (args.measures, ("measures.json",), False),
            "dimensions": (args.dimensions, ("dimensions.json",), False),
            "charts": (args.charts, ("charts.json",), True),
            "layout": (args.layout, ("layout.json",), True),
            "app_meta": (args.app_meta, ("app-meta.json",), False),
            "formula_mapping": (args.formula_mapping, ("formula-mapping.json",), False),
            "dm_spec": (args.dm_spec, ("dm-spec.json",), False),
            "dm_readback": (args.dm_readback, ("dm-readback.json", "data-model-readback.json"), False),
            "wb_spec": (args.wb_spec, ("wb-spec.json",), False),
            "wb_readback": (args.wb_readback, ("wb-readback.json", "workbook-readback.json"), False),
            "workbook_coverage": (args.workbook_coverage, ("workbook-coverage.json",), False),
            "control_scope": (args.control_scope, ("control-scope.json",), False),
            "parity": (args.parity, ("parity-final.json",), False),
            "element_map": (args.element_map, ("element-map.json",), False),
            "denorm": (args.denorm, ("denorm.json",), False),
            "converter_out": (args.converter_out, ("converter-out.json",), False),
        }
        paths = {
            kind: artifact(workdir, explicit, names, required)
            for kind, (explicit, names, required) in specs.items()
        }
        script_path = artifact(workdir, args.script, ("script.qvs",), required=True)
        paths["script"] = script_path
        docs = {kind: read_json(path) for kind, path in paths.items() if kind != "script"}
        docs["script"] = script_path.read_text(encoding="utf-8-sig")
        docs.setdefault("measures", [])
        docs.setdefault("dimensions", [])
        if not isinstance(docs["converter"], dict):
            raise InputError("converter-input must be a JSON object")
        if not isinstance(docs["charts"], list) or not isinstance(docs["layout"], list):
            raise InputError("charts.json and layout.json must be JSON arrays")

        accounting = Accounting(workdir, paths, docs)
        accounting.inventory()
        accounting.account()
        census, coverage, controls, tiles, layout_census = accounting.outputs()

        def out(value, default):
            path = Path(value) if value else workdir / default
            return (path if path.is_absolute() else workdir / path).resolve()

        write_json(out(args.census_out, "source-object-census.json"), census)
        write_json(out(args.coverage_out, "coverage.json"), coverage)
        write_json(out(args.controls_out, "qlik-controls-coverage.json"), controls)
        write_json(out(args.tiles_out, "qlik-tile-layout.json"), tiles)
        write_json(out(args.layout_census_out, "layout-census.json"), layout_census)
        print("qlik accounting: %d objects (%d accounted), %d visuals, %d controls" % (
            census["summary"]["total"], census["summary"]["accounted"],
            coverage["summary"]["sourceVisuals"], controls["summary"]["sourceFilters"],
        ))
        if accounting.errors:
            for error in sorted(set(accounting.errors)):
                print("ERROR: " + error, file=sys.stderr)
            return 1
        return 0
    except InputError as exc:
        print("build-qlik-accounting: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
