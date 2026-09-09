#!/usr/bin/env python3
"""mb-bulk-split.py — companion to discover-metabase.sh's bulk fast path.

Production finding (7k-card / 1.5k-dashboard Metabase Cloud estate): the old
per-item sequential walk took >1 hour; `GET /api/card` returns EVERY card with
its full definition in one response (~110MB for 7k cards). Stream that to disk,
then split it locally — the whole discovery drops to ~1 minute.

Subcommands (all local-file only; the shell script does the HTTP):
  split-cards        --bulk cards.bulk.json --collections collections.json --out DIR
                     [--include-personal]
        → DIR/specs/{id}.card.json (skip-if-exists), appends DIR/.artifacts.jsonl,
          writes DIR/databases.txt (distinct database ids, for metadata fetches)
  list-dashboards    --list dashboards.list.json --collections collections.json --out DIR
                     [--include-personal] [--max N]
        → prints dashboard ids to fetch (one per line), already-downloaded ids skipped
  collect-cards      --collections collections.json --out DIR [--include-personal]
        → rebuilds artifact records + databases.txt from DIR/specs/*.card.json
          (resume path — avoids re-downloading the bulk payload)
  collect-dashboards --collections collections.json --out DIR
        → appends artifact records for every DIR/specs/*.dashboard.json on disk

Stdlib only. Read-only with respect to Metabase (never talks to the network).
"""
import argparse
import json
import os
import sys
from glob import glob


def load_collections(path):
    """collection id → name; plus the set of personal-collection ids."""
    names = {None: 'Our analytics', 'root': 'Our analytics'}
    personal = set()
    try:
        with open(path) as f:
            colls = json.load(f)
    except (OSError, ValueError):
        return names, personal
    for c in colls if isinstance(colls, list) else []:
        cid = c.get('id')
        names[cid] = c.get('name') or str(cid)
        if c.get('personal_owner_id') is not None or c.get('is_personal'):
            personal.add(cid)
    return names, personal


def artifact_type(card):
    if card.get('type') == 'model' or card.get('dataset') is True:
        return 'model'
    if card.get('type') == 'metric':
        return 'metric'
    return 'card'


def split_cards(args):
    names, personal = load_collections(args.collections)
    with open(args.bulk) as f:
        cards = json.load(f)
    if not isinstance(cards, list):
        sys.exit('split-cards: bulk file is not a JSON array — is this really GET /api/card?')
    specs = os.path.join(args.out, 'specs')
    os.makedirs(specs, exist_ok=True)
    dbs, n_written, n_skipped, n_personal = set(), 0, 0, 0
    art = open(os.path.join(args.out, '.artifacts.jsonl'), 'a')
    for c in cards:
        cid = c.get('id')
        if cid is None or c.get('archived'):
            continue
        coll_id = c.get('collection_id')
        if coll_id in personal and not args.include_personal:
            n_personal += 1
            continue
        path = os.path.join(specs, f'{cid}.card.json')
        if os.path.exists(path) and os.path.getsize(path) > 0:
            n_skipped += 1
        else:
            tmp = path + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(c, f)
            os.replace(tmp, path)
            n_written += 1
        db = c.get('database_id') or (c.get('dataset_query') or {}).get('database')
        if db:
            dbs.add(db)
        art.write(json.dumps({
            'id': cid, 'type': artifact_type(c), 'name': c.get('name'),
            'collection': names.get(coll_id, str(coll_id)),
            'view_count': c.get('view_count'),
            'specFile': f'specs/{cid}.card.json',
        }) + '\n')
    art.close()
    with open(os.path.join(args.out, 'databases.txt'), 'w') as f:
        for db in sorted(dbs):
            f.write(f'{db}\n')
    print(f'split-cards: {n_written} written, {n_skipped} already on disk, '
          f'{n_personal} personal-collection cards skipped, {len(dbs)} databases referenced',
          file=sys.stderr)


def list_dashboards(args):
    _, personal = load_collections(args.collections)
    with open(args.list) as f:
        dashes = json.load(f)
    if isinstance(dashes, dict):  # some versions wrap in {data:[…]}
        dashes = dashes.get('data', [])
    specs = os.path.join(args.out, 'specs')
    out = []
    for d in dashes if isinstance(dashes, list) else []:
        did = d.get('id')
        if did is None or d.get('archived'):
            continue
        if d.get('collection_id') in personal and not args.include_personal:
            continue
        p = os.path.join(specs, f'{did}.dashboard.json')
        if os.path.exists(p) and os.path.getsize(p) > 0:
            continue  # resumable: already downloaded
        out.append(did)
    if args.max is not None:
        out = out[:args.max]
    for did in out:
        print(did)


def collect_cards(args):
    names, personal = load_collections(args.collections)
    specs = os.path.join(args.out, 'specs')
    art = open(os.path.join(args.out, '.artifacts.jsonl'), 'a')
    dbs, n = set(), 0
    for p in sorted(glob(os.path.join(specs, '*.card.json'))):
        try:
            with open(p) as f:
                c = json.load(f)
        except (OSError, ValueError):
            continue
        if c.get('collection_id') in personal and not args.include_personal:
            continue
        art.write(json.dumps({
            'id': c.get('id'), 'type': artifact_type(c), 'name': c.get('name'),
            'collection': names.get(c.get('collection_id'), str(c.get('collection_id'))),
            'view_count': c.get('view_count'),
            'specFile': f"specs/{os.path.basename(p)}",
        }) + '\n')
        db = c.get('database_id') or (c.get('dataset_query') or {}).get('database')
        if db:
            dbs.add(db)
        n += 1
    art.close()
    with open(os.path.join(args.out, 'databases.txt'), 'w') as f:
        for db in sorted(dbs):
            f.write(f'{db}\n')
    print(f'collect-cards: {n} cards recorded from disk', file=sys.stderr)


def collect_dashboards(args):
    names, _ = load_collections(args.collections)
    specs = os.path.join(args.out, 'specs')
    art = open(os.path.join(args.out, '.artifacts.jsonl'), 'a')
    n = 0
    for p in sorted(glob(os.path.join(specs, '*.dashboard.json'))):
        try:
            with open(p) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        art.write(json.dumps({
            'id': d.get('id'), 'type': 'dashboard', 'name': d.get('name'),
            'collection': names.get(d.get('collection_id'), str(d.get('collection_id'))),
            'view_count': d.get('view_count'),
            'specFile': f"specs/{os.path.basename(p)}",
        }) + '\n')
        n += 1
    art.close()
    print(f'collect-dashboards: {n} dashboards recorded', file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    s1 = sub.add_parser('split-cards')
    s1.add_argument('--bulk', required=True)
    s1.add_argument('--collections', required=True)
    s1.add_argument('--out', required=True)
    s1.add_argument('--include-personal', action='store_true')
    s2 = sub.add_parser('list-dashboards')
    s2.add_argument('--list', required=True)
    s2.add_argument('--collections', required=True)
    s2.add_argument('--out', required=True)
    s2.add_argument('--include-personal', action='store_true')
    s2.add_argument('--max', type=int, default=None)
    s3 = sub.add_parser('collect-dashboards')
    s3.add_argument('--collections', required=True)
    s3.add_argument('--out', required=True)
    s4 = sub.add_parser('collect-cards')
    s4.add_argument('--collections', required=True)
    s4.add_argument('--out', required=True)
    s4.add_argument('--include-personal', action='store_true')
    args = ap.parse_args()
    {'split-cards': split_cards, 'list-dashboards': list_dashboards,
     'collect-dashboards': collect_dashboards, 'collect-cards': collect_cards}[args.cmd](args)


if __name__ == '__main__':
    main()
