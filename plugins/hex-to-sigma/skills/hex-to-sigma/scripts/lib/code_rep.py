"""Shape adapter for the Sigma WORKBOOK code representation
(POST /v2/workbooks/spec, GET|PUT /v2/workbooks/{id}/spec, POST /v2/workbooks/spec/verify).

Verified live 2026-08-03/04: this surface nests non-metadata fields under a top-level
`document` key and rejects the old flat body with HTTP 400 — including on /verify.
Sigma engineering confirmed 2026-08-03 that the DATA-MODEL code-rep surface is NOT
changing, so this adapter is workbook-only and always writes the nested shape.
Do NOT use it on /v2/dataModels/.../spec payloads — that API ignores `document`.

Reads stay tolerant of the legacy flat shape because flat artifacts still exist
on disk (committed workbook snapshots, fixtures).
"""

DOC_KEYS = ("schemaVersion", "pages", "kind", "layout")


def document(response):
    """Return the workbook document from either the nested or legacy flat shape."""
    if not isinstance(response, dict):
        return {}
    inner = response.get("document")
    if isinstance(inner, dict):
        return inner
    return {k: v for k, v in response.items() if k in DOC_KEYS}


def metadata(response):
    if not isinstance(response, dict):
        return {}
    return {k: v for k, v in response.items() if k != "document" and k not in DOC_KEYS}


def wrap(doc, extra=None):
    """Build a request body. Every live workbook code-rep endpoint requires the wrapper."""
    out = dict(extra or {})
    out["document"] = doc
    return out
