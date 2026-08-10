"""Wire helper for excel-to-sigma workbook builders.

Builders still author the convenient nested `pages[].elements` draft shape.
Before POST /v2/workbooks/spec (and when writing dry-run artifacts that would
be POSTed), call `wire_workbook(spec)` so the body matches the released
workbook code representation:

  { name, folderId?, description?, document: { schemaVersion, kind, pages, elements, layout } }

`code_rep.wrap` flattens nested elements and canonicalizes layout tags. This
helper invents a stacked notebook-flow `layout` when the draft lacks one —
layout is required on the live surface and owns page membership.
Data-model specs are unchanged — do not wrap /v2/dataModels/... payloads.
"""
from __future__ import annotations

import sys
from pathlib import Path

_LIB = Path(__file__).resolve().parent
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))

import code_rep  # noqa: E402

GRID_COLS = 24
DEFAULT_ROW_HEIGHT = 12


def stack_layout(pages, row_height: int = DEFAULT_ROW_HEIGHT) -> str:
    """One full-width stacked tile per element, page order preserved."""
    blocks = []
    for page in pages or []:
        if not isinstance(page, dict) or not page.get("id"):
            continue
        pid = page["id"]
        els = [el for el in (page.get("elements") or []) if isinstance(el, dict) and el.get("id")]
        lines = [
            f'<Page type="grid" gridTemplateColumns="repeat({GRID_COLS}, 1fr)" '
            f'gridTemplateRows="auto" id="{pid}">'
        ]
        cursor = 1
        for el in els:
            end = cursor + row_height
            lines.append(
                f'  <Element elementId="{el["id"]}" '
                f'gridColumn="1 / {GRID_COLS + 1}" gridRow="{cursor} / {end}"/>'
            )
            cursor = end
        lines.append("</Page>")
        blocks.append("\n".join(lines))
    return '<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(blocks)


def wire_workbook(spec: dict) -> dict:
    """Return a POST-ready workbook body (document wrapper + flat elements)."""
    if not isinstance(spec, dict):
        raise TypeError("workbook spec must be a dict")

    # Already wrapped — re-canonicalize through code_rep for safety.
    if isinstance(spec.get("document"), dict):
        doc = code_rep.document(spec)
        return code_rep.wrap(doc, extra=code_rep.metadata(spec))

    draft = dict(spec)
    draft.setdefault("schemaVersion", 1)
    draft.setdefault("kind", "workbook")
    pages = draft.get("pages")
    if "layout" not in draft and isinstance(pages, list):
        draft["layout"] = stack_layout(pages)

    meta = code_rep.metadata(draft)
    doc = code_rep.document(draft)
    return code_rep.wrap(doc, extra=meta)
