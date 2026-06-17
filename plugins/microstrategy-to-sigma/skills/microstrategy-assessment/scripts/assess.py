#!/usr/bin/env python3
"""
assess.py — read-only MicroStrategy (Strategy One) estate inventory.

GET-only against the MicroStrategy REST API. Produces:
  <out>/inventory.json   — machine-readable estate inventory
  <out>/readout.md       — human-readable migration-readiness readout

Surveyed per project:
  - report + document/dossier counts (quick-search API)
  - per-dossier structure: chapters / pages / visualizations, walking
    panelStacks[].panels[] RECURSIVELY (panels nest further panelStacks)
    and counting free-form `fields` (images / text boxes)
  - visualization-type histogram, classified against the converter's
    viz-type lookup (see ../microstrategy-to-sigma/refs/viz-type-mapping.md)
  - instance datasource inventory (database types)
  - per-dossier complexity flags + migrate-first / moderate / needs-review tag

Usage:
  python3 assess.py [--project <id>] [--out /tmp/mstr-assessment] [--max-dossiers 100]

Credentials: MSTR_BASE_URL / MSTR_USERNAME / MSTR_PASSWORD env vars (or
~/.sigma-migration/env) — see ../../microstrategy-to-sigma/scripts/mstr.py.
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', 'microstrategy-to-sigma', 'scripts'))
import mstr  # noqa: E402

# Sigma-analog lookup, mirroring the converter (flagged-table fallback).
# Keep in sync with refs/viz-type-mapping.md in the converter skill.
# Types with a real Sigma mapping (see ../microstrategy-to-sigma/refs/
# viz-type-mapping.md, demo-sweep-validated). Others = flagged-table fallback;
# custom/marketplace vizzes (HC*/D3*/Vitara*/EChart*/Arria*…) are never mapped.
VIZ_MAPPED = {
    'grid', 'compound_grid', 'kpi', 'multi_metric_kpi', 'comparison_kpi',
    'bar_chart', 'line_chart', 'combo_chart', 'area_chart',
    'pie_chart', 'ring_chart', 'bubble_chart',
    'geospatial_service', 'google_map', 'esri_map',
}
# MicroStrategy object types (quick-search `type` param)
TYPE_REPORT = 3
TYPE_DOCUMENT = 55  # documents AND dossiers


def search(s, obj_type, limit=500):
    """Quick-search for objects of a type in the session's project."""
    out, offset = [], 0
    while True:
        r = s.get(f'/searches/results?type={obj_type}'
                  f'&offset={offset}&limit={limit}')
        items = r.get('result', [])
        out.extend(items)
        offset += len(items)
        if offset >= r.get('totalItems', 0) or not items:
            return out


def walk_container(node, hist, flags):
    """Recursively walk a page/panel: visualizations + panelStacks[].panels[]
    (+ free-form `fields` — images / text boxes)."""
    for v in node.get('visualizations') or []:
        hist[v.get('visualizationType', 'unknown')] += 1
    for _f in node.get('fields') or []:
        flags['free_form_fields'] += 1
    if node.get('selectors'):
        flags['selectors'] += len(node['selectors'])
    for ps in node.get('panelStacks') or []:
        flags['panel_stacks'] += 1
        for p in ps.get('panels') or []:
            walk_container(p, hist, flags)


def assess_dossier(s, doc):
    """Fetch /v2/dossiers/{id}/definition; None if not a dossier."""
    try:
        d = s.get(f"/v2/dossiers/{doc['id']}/definition")
    except RuntimeError:
        return None
    hist = collections.Counter()
    flags = collections.Counter()
    n_pages = 0
    for ch in d.get('chapters') or []:
        for pg in ch.get('pages') or []:
            n_pages += 1
            walk_container(pg, hist, flags)
    unmapped = sorted(t for t in hist if t not in VIZ_MAPPED)
    if flags['panel_stacks'] or unmapped:
        tag = 'needs-review'
    elif flags['free_form_fields'] or flags['selectors'] or len(hist) > 2:
        tag = 'moderate'
    else:
        tag = 'migrate-first'
    # dataset names (the dossier's source cubes/reports) — used as the
    # duplicate-detector `sources` signal; fall back to id when unnamed.
    dataset_names = [ds.get('name') or ds.get('id')
                     for ds in d.get('datasets') or [] if ds.get('name') or ds.get('id')]
    return {
        'id': doc['id'],
        'name': d.get('name', doc.get('name')),
        'chapters': len(d.get('chapters') or []),
        'pages': n_pages,
        'datasets': len(d.get('datasets') or []),
        'dataset_names': dataset_names,
        'visualizations': sum(hist.values()),
        'viz_types': dict(hist),
        'unmapped_viz_types': unmapped,
        'flags': dict(flags),
        'tag': tag,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--project', default=None,
                    help='project id (default: MSTR_PROJECT_ID, else first project)')
    ap.add_argument('--out', default='/tmp/mstr-assessment')
    ap.add_argument('--max-dossiers', type=int, default=100,
                    help='cap on per-dossier definition fetches')
    args = ap.parse_args()

    s = mstr.Session(project_id=args.project)
    projects = s.get('/projects')
    if not s.project_id:
        s.project_id = projects[0]['id']
    project = next((p for p in projects if p['id'] == s.project_id), None)

    # instance-level datasources (db types)
    try:
        ds = s.get('/datasources').get('datasources', [])
    except RuntimeError:
        ds = []
    ds_types = collections.Counter(
        (d.get('database') or {}).get('type', 'unknown') for d in ds)

    reports = search(s, TYPE_REPORT)
    documents = search(s, TYPE_DOCUMENT)

    dossiers, plain_documents = [], []
    viz_hist = collections.Counter()
    for doc in documents[: args.max_dossiers]:
        a = assess_dossier(s, doc)
        if a is None:
            plain_documents.append({'id': doc['id'], 'name': doc.get('name')})
        else:
            dossiers.append(a)
            viz_hist.update(a['viz_types'])

    # Duplicate / consolidation candidates — flag dossiers that are the same
    # report rebuilt (shared dataset + overlapping viz set + near-identical
    # name) so the estate migrates ONCE instead of N times. Shared, tool-neutral
    # detector; hyphenated filename → load via importlib. Only present signals
    # are passed (sources = dataset names, viz = per-dossier viz-type keys);
    # MicroStrategy's quick-search exposes no per-dossier field list or hit
    # count, so `fields`/`usage` are intentionally omitted (flag-not-fake).
    import importlib.util
    _dd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            'dup-dashboards.py')
    _spec = importlib.util.spec_from_file_location('dup_dashboards', _dd_path)
    _dd = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_dd)
    duplicate_dashboards = _dd.detect([
        {'id': d['id'], 'name': d['name'],
         'sources': d.get('dataset_names') or [],
         'viz': list((d.get('viz_types') or {}).keys())}
        for d in dossiers])

    inventory = {
        'project': {'id': s.project_id,
                    'name': project['name'] if project else None},
        'projects_available': [{'id': p['id'], 'name': p['name']}
                               for p in projects],
        'counts': {
            'reports': len(reports),
            'documents': len(documents),
            'dossiers': len(dossiers),
            'plain_documents': len(plain_documents),
            'datasources': len(ds),
        },
        'datasource_types': dict(ds_types),
        'viz_type_histogram': dict(viz_hist),
        'unmapped_viz_types': sorted(t for t in viz_hist if t not in VIZ_MAPPED),
        'dossiers': dossiers,
        'plain_documents': plain_documents,
        'reports': [{'id': r['id'], 'name': r.get('name')} for r in reports],
        'duplicate_dashboards': duplicate_dashboards,
    }

    os.makedirs(args.out, exist_ok=True)
    inv_path = os.path.join(args.out, 'inventory.json')
    json.dump(inventory, open(inv_path, 'w'), indent=1)

    # ---- readout
    L = ['# MicroStrategy estate — migration readout', '',
         f"Project: **{inventory['project']['name']}** (`{s.project_id}`)", '',
         '## Counts', '',
         f"- Reports: {len(reports)}",
         f"- Documents: {len(documents)} ({len(dossiers)} dossiers, "
         f"{len(plain_documents)} non-dossier documents)",
         f"- Datasources: {len(ds)} "
         f"({', '.join(f'{k}: {v}' for k, v in ds_types.items()) or 'n/a'})",
         '', '## Visualization types (all dossiers, incl. panel stacks)', '',
         '| Type | Count | Converter |', '|---|---|---|']
    for t, n in viz_hist.most_common():
        L.append(f"| {t} | {n} | "
                 f"{'mapped' if t in VIZ_MAPPED else 'FLAGGED (table fallback)'} |")
    L += ['', '## Dossiers', '',
          '| Dossier | Chapters | Pages | Vizzes | Flags | Tag |', '|---|---|---|---|---|---|']
    for d in sorted(dossiers, key=lambda x: x['tag']):
        fl = ', '.join(f'{k}={v}' for k, v in d['flags'].items()) or '—'
        if d['unmapped_viz_types']:
            fl += f"; unmapped: {', '.join(d['unmapped_viz_types'])}"
        L.append(f"| {d['name']} | {d['chapters']} | {d['pages']} | "
                 f"{d['visualizations']} | {fl} | **{d['tag']}** |")
    L += ['', '_Tags: migrate-first = grid/kpi-only, no panel stacks; '
          'moderate = selectors / free-form fields / chart mix; '
          'needs-review = panel stacks or unmapped viz types._', '']
    # Consolidation section (shared duplicate-dashboard detector).
    L += ['', _dd.render_md(duplicate_dashboards).rstrip(), '']
    md_path = os.path.join(args.out, 'readout.md')
    open(md_path, 'w').write('\n'.join(L))

    print(f"project: {inventory['project']['name']}")
    print(f"reports={len(reports)} documents={len(documents)} "
          f"dossiers={len(dossiers)} datasources={len(ds)}")
    print(f"viz histogram: {dict(viz_hist)}")
    _ds = duplicate_dashboards['summary']
    if _ds['duplicate_groups']:
        print(f"duplicate/consolidation: {_ds['duplicate_groups']} group(s) across "
              f"{_ds['dashboards_in_groups']} dossiers — avoids "
              f"{_ds['conversions_avoided']} redundant migration(s)")
    print(f"wrote {inv_path} and {md_path}")


if __name__ == '__main__':
    main()
