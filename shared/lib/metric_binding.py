#!/usr/bin/env python3
"""metric_binding.py — bind a workbook measure to a governed DM metric.

Every converter builds a Sigma data model whose elements carry reusable metrics
(name + formula), but the workbook builder tends to re-derive each measure inline
(``Sum([Master/Net Revenue])``, ``CountDistinct(...)``, ...), bypassing the
governed metric: the aggregation logic is duplicated (and can drift) and the
analyst never gets the metric object. This module is the thin, converter-agnostic
binder that lets a builder prefer a governed ``[Metrics/<name>]`` reference when it
is provably the same aggregation — and fall back to the inline formula otherwise.

Two pure functions, stdlib only:

- ``available_metrics(element_id, elements_by_id)`` — the metrics REFERENCEABLE on
  an element: its own metrics plus those it inherits through the ``source.elementId``
  chain (a denorm "<X> View" element carries 0 own metrics but inherits its base
  fact's; Sigma exposes them and they resolve as ``[Metrics/<name>]`` on the denorm
  — verified live). Deduped by name, nearest element wins. Each metric is
  ``{"name", "formula"}``; entries missing either field are skipped.

- ``metric_ref_or_inline(inline, master_name, metrics)`` — returns
  ``[Metrics/<name>]`` when ``inline`` matches a metric by FORMULA EQUIVALENCE
  (strip the master prefix so ``Sum([Data/Net Revenue])`` equals a metric's
  ``Sum([Net Revenue])``, then compare ignoring whitespace), else returns ``inline``
  unchanged. Naming-independent and SAFE: ratios / filtered / custom / no-match /
  empty-metrics all fall through to the inline formula, so passing no metrics is
  byte-identical to the pre-binding behavior. Whether a given column is even a
  measure (worth binding) is the caller's decision — only call this for measures.

The reference form is the literal namespace ``[Metrics/<Metric Name>]`` — NOT
``[Element/Name]`` (that errors). Extracted from the looker reference implementation
(PR #484); see beads-sigma-7bun. Mirror: shared/lib/metric_binding.rb — keep the
two in lockstep.
"""
import re

_WS = re.compile(r"\s+")


def canon(formula):
    """Whitespace-insensitive canonical form of a Sigma formula (or empty)."""
    return _WS.sub("", formula or "")


def available_metrics(element_id, elements_by_id):
    """Metrics referenceable on ``element_id`` = its own metrics + those inherited
    through the ``source.elementId`` chain, deduped by name (nearest element wins).

    ``elements_by_id`` maps an element id to its dict (each with an optional
    ``metrics`` list and ``source.elementId``). Returns a list of
    ``{"name", "formula"}`` dicts; metrics missing a name or formula are dropped.
    Cycle-safe."""
    seen, chain = set(), []
    eid = element_id
    while eid and eid not in seen:
        seen.add(eid)
        el = elements_by_id.get(eid)
        if not el:
            break
        for m in (el.get("metrics") or []):
            name, formula = m.get("name"), m.get("formula")
            if name and formula:
                chain.append({"name": name, "formula": formula})
        eid = (el.get("source") or {}).get("elementId")
    return _dedup_by_name(chain)


def _dedup_by_name(metrics):
    seen, out = set(), []
    for m in metrics:
        if m["name"] not in seen:
            seen.add(m["name"])
            out.append(m)
    return out


def metric_ref_or_inline(inline, master_name, metrics):
    """Prefer ``[Metrics/<name>]`` when ``inline`` matches a metric by formula
    equivalence (master prefix stripped, whitespace ignored); otherwise return
    ``inline`` unchanged. Safe no-op when ``metrics`` is empty or ``inline`` is not
    a string. See the module docstring."""
    if not isinstance(inline, str) or not metrics:
        return inline
    want = canon(inline.replace(f"[{master_name}/", "["))
    for m in metrics:
        name, formula = m.get("name"), m.get("formula")
        if name and formula and canon(formula) == want:
            return f"[Metrics/{name}]"
    return inline
