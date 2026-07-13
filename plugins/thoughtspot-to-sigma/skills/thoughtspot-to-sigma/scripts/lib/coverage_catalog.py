#!/usr/bin/env python3
"""coverage_catalog.py — load a documentation-grounded mapping catalog and
resolve source constructs to Sigma targets, LOUDLY on a miss.

The single source of truth for a classifier's mappings is a JSON catalog under
the skill's ``refs/catalogs/<dimension>.json``. Each catalog is an envelope::

    {
      "dimension": "number-format",
      "source_tool": "looker",
      "authoritative_doc": "https://cloud.google.com/looker/docs/reference/param-measure-value-format-name",
      "on_unmapped_default": "warn+skip",
      "rows": [
        {"source": "usd_0", "sigma": "$,.0f",
         "doc_ref": "https://cloud.google.com/looker/docs/reference/param-measure-value-format-name",
         "sigma_verified": {"status": "y", "date": "2026-07-13"},
         "on_unmapped": "warn+skip",
         "notes": "..."}
      ]
    }

Rows are indexed by ``source`` (normalized: trimmed + lowercased — every one of
the four classifier dimensions keys on lowercase tokens). ``resolve()`` returns
the row dict or ``None``. The classifier MUST honor a ``None`` by warning +
skipping/placeholdering — never by emitting a silent wrong default.
``resolve_or_warn()`` enforces that: it appends a standardized warning to the
caller's ``warnings`` list and returns ``None`` on a miss.

Stdlib only (json/os); Windows-safe (os.path). Mirrors the beads-sigma-93ps
design contract: the catalog is language-neutral data; this loader is the thin
resolver. See refs/<skill>-coverage.md (generated FROM the catalogs) for the
human-readable, cited coverage matrix.
"""
import json
import os

MISS = None  # sentinel: resolve() returns None when a source key is absent


class Catalog:
    """A single loaded mapping dimension (viz-kind / number-format / aggregation
    / control), indexed by source construct."""

    def __init__(self, data, path):
        self.path = path
        self.filename = os.path.basename(path)
        self.dimension = data.get("dimension") or os.path.splitext(self.filename)[0]
        self.source_tool = data.get("source_tool", "")
        self.authoritative_doc = data.get("authoritative_doc", "")
        self.on_unmapped_default = data.get("on_unmapped_default", "warn+skip")
        self.rows = data.get("rows", [])
        self._by_source = {}
        for r in self.rows:
            k = r.get("source")
            if k is None:
                continue
            self._by_source[self._norm(k)] = r

    @staticmethod
    def _norm(k):
        return str(k).strip().lower()

    def resolve(self, source_key):
        """Return the full catalog row for ``source_key``, or ``None`` on a miss."""
        if source_key is None:
            return None
        return self._by_source.get(self._norm(source_key))

    def target(self, source_key):
        """Return just the Sigma target string for ``source_key`` (row['sigma']),
        or ``None`` on a miss. Convenience for the common case."""
        row = self.resolve(source_key)
        return row.get("sigma") if row else None

    def resolve_or_warn(self, source_key, warnings, *, context=""):
        """Resolve ``source_key``; on a miss append a standardized LOUD warning to
        ``warnings`` and return ``None``. The caller must then skip/placeholder —
        this makes the loud fallback mandatory and uniform across classifiers."""
        row = self.resolve(source_key)
        if row is not None:
            return row
        where = " (%s)" % context if context else ""
        warnings.append(
            "⚠ %s: no documented %s mapping for '%s'%s — %s. "
            "Add a cited row to refs/catalogs/%s if this is a real construct."
            % (self.dimension, self.source_tool or "source", source_key, where,
               self.on_unmapped_default, self.filename)
        )
        return None

    def sources(self):
        """All (normalized) source keys the catalog covers."""
        return list(self._by_source.keys())

    def unverified(self):
        """Rows whose Sigma target is not yet live-verified
        (``sigma_verified.status`` != 'y'). Used to gate a PR / stamp progress."""
        return [r for r in self.rows
                if (r.get("sigma_verified") or {}).get("status") != "y"]


def load(catalog_dir, dimension):
    """Load ``<catalog_dir>/<dimension>.json``. Fails LOUDLY if absent — a
    classifier with no catalog must not silently guess."""
    path = os.path.join(catalog_dir, dimension + ".json")
    if not os.path.exists(path):
        raise FileNotFoundError(
            "coverage catalog missing: %s — the classifier requires a "
            "documentation-grounded catalog for '%s'; refusing to guess."
            % (path, dimension)
        )
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    return Catalog(data, path)


def load_all(catalog_dir):
    """Load every ``*.json`` catalog in ``catalog_dir``, keyed by dimension name."""
    if not os.path.isdir(catalog_dir):
        raise FileNotFoundError("coverage catalog dir missing: %s" % catalog_dir)
    out = {}
    for fn in sorted(os.listdir(catalog_dir)):
        if fn.endswith(".json"):
            out[fn[:-5]] = load(catalog_dir, fn[:-5])
    return out


def default_catalog_dir(script_file):
    """Given a builder's ``__file__`` (in scripts/), return its sibling
    ``refs/catalogs`` dir. Keeps callers from hand-rolling the ``..`` walk."""
    scripts_dir = os.path.dirname(os.path.abspath(script_file))
    return os.path.normpath(os.path.join(scripts_dir, "..", "refs", "catalogs"))
