#!/usr/bin/env python3
"""Phase 0b (Assess): is this LookML export actually COMPLETE enough to convert?

Why this exists
---------------
A partial LookML export converts "successfully" and looks catastrophic. Every
view an explore joins but that was not exported becomes a
`LOOKER_SCRATCH.<VIEW>` placeholder with a loud warning, so a project missing
most of its views emits hundreds of warnings and reads as "this tool cannot
convert our model." The cause is a missing-file problem, not a capability
problem, and the two must never be confused — one is fixed by asking for the
rest of the repo, the other by engineering work.

This runs BEFORE conversion and answers, in numbers:
  - how many distinct physical views the explore(s) reference vs. how many were
    supplied (LookML `from:` aliasing is resolved first, so N aliases of one
    view count once);
  - how many joins can actually be wired vs. how many point at absent views;
  - whether a `.model.lkml` (i.e. any explore) is present at all;
  - whether the target explore is `extension: required`, meaning it is an
    ABSTRACT base that no one can run directly — the concrete explores that
    extend it live elsewhere.

NEVER SILENT, NEVER ALARMIST: on a complete project this prints a one-line
all-clear and exits 0. It never blocks — an incomplete export is still worth
converting as a slice, and the exit code stays 0 so orchestrators keep going.
Exit 2 only on a usage/IO error.

Dependency-free (stdlib only).

Usage:
    python3 check_input_completeness.py <lookml_dir_or_file> [<more> ...] [--json]
"""

import json
import os
import re
import sys

# `join: name {` at explore-block indentation.
RE_JOIN = re.compile(r'\n\s*join:\s*([A-Za-z_0-9]+)\s*\{')
# `from: other_view` — LookML view aliasing (role-playing).
RE_FROM = re.compile(r'\n\s*from:\s*([A-Za-z_0-9]+)')
RE_VIEW = re.compile(r'\n\s*view:\s*([A-Za-z_0-9]+)\s*\{')
RE_EXPLORE = re.compile(r'\n\s*explore:\s*([A-Za-z_0-9]+)\s*\{')
RE_EXTENSION_REQUIRED = re.compile(r'\n\s*extension:\s*required\b')


def _strip_comments(text):
    """Drop `#` comments (quote-aware, per line).

    Matters for accuracy, not tidiness: a commented-out `join:` block would
    otherwise be counted as a live join and inflate every number this script
    reports. Only strips a `#` that is not inside a single/double-quoted string
    on that line, so colour literals ('#fff') and `#` inside SQL survive.
    """
    out = []
    for line in text.split('\n'):
        in_s = in_d = False
        cut = None
        for i, ch in enumerate(line):
            if ch == "'" and not in_d:
                in_s = not in_s
            elif ch == '"' and not in_s:
                in_d = not in_d
            elif ch == '#' and not in_s and not in_d:
                cut = i
                break
        out.append(line if cut is None else line[:cut])
    return '\n'.join(out)


def _read(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        return _strip_comments(fh.read())


def _lkml_files(targets):
    out = []
    for t in targets:
        if os.path.isdir(t):
            for root, _dirs, files in os.walk(t):
                for f in sorted(files):
                    if f.endswith('.lkml'):
                        out.append(os.path.join(root, f))
        elif os.path.isfile(t):
            out.append(t)
        else:
            print(f"error: no such file or directory: {t}", file=sys.stderr)
            sys.exit(2)
    return out


def _split_join_blocks(text):
    """Yield (alias, body) for each join block, body running to the next join
    or the end. Good enough to find `from:` without a full LookML parse."""
    marks = [(m.start(), m.group(1)) for m in RE_JOIN.finditer(text)]
    for i, (pos, alias) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        yield alias, text[pos:end]


def analyze(targets):
    files = _lkml_files(targets)
    provided_views = set()
    explores = []
    abstract_explores = []
    joins = []            # (alias, physical_view)
    has_model_file = False

    for path in files:
        text = '\n' + _read(path)
        for m in RE_VIEW.finditer(text):
            provided_views.add(m.group(1))
        found_explores = [m.group(1) for m in RE_EXPLORE.finditer(text)]
        if found_explores:
            has_model_file = True
            explores.extend(found_explores)
            if RE_EXTENSION_REQUIRED.search(text):
                abstract_explores.extend(found_explores)
        for alias, body in _split_join_blocks(text):
            frm = RE_FROM.search(body)
            joins.append((alias, frm.group(1) if frm else alias))

    referenced = {phys for _alias, phys in joins}
    missing = sorted(referenced - provided_views)
    resolvable = [j for j in joins if j[1] in provided_views]

    return {
        'files_scanned': len(files),
        'explores': sorted(set(explores)),
        'abstract_explores': sorted(set(abstract_explores)),
        'has_model_file': has_model_file,
        'views_provided': len(provided_views),
        'joins_total': len(joins),
        'joins_resolvable': len(resolvable),
        'physical_views_referenced': len(referenced),
        'physical_views_missing': len(missing),
        'missing_views': missing,
        'aliased_joins': len(joins) - len(referenced),
    }


def report(r):
    missing = r['physical_views_missing']
    complete = missing == 0 and r['has_model_file'] and not r['abstract_explores']

    if complete:
        print(f"✓ LookML input looks complete — {r['views_provided']} view(s), "
              f"{r['joins_total']} join(s), all resolvable.")
        return

    print("LookML INPUT COMPLETENESS — read this before judging the conversion")
    print("=" * 72)
    print(f"  views provided                : {r['views_provided']}")
    print(f"  physical views referenced     : {r['physical_views_referenced']}"
          f"   ({r['aliased_joins']} join(s) are `from:` aliases of another view)")
    print(f"  physical views MISSING        : {missing}")
    print(f"  joins total                   : {r['joins_total']}")
    print(f"  joins resolvable from input   : {r['joins_resolvable']}")

    if not r['has_model_file']:
        print("\n  ⚠ No explore found in the input (no .model.lkml). Joins live in the")
        print("    model file, so NO relationships can be emitted — every view converts")
        print("    as a standalone element. Ask for the model file.")

    if r['abstract_explores']:
        names = ', '.join(r['abstract_explores'])
        print(f"\n  ⚠ Explore(s) marked `extension: required`: {names}")
        print("    These are ABSTRACT base explores — not runnable on their own. The")
        print("    concrete explores that extend them are not in this input; ask which")
        print("    explores extend them and whether those are in scope.")

    if missing:
        pct = 100.0 * r['joins_resolvable'] / r['joins_total'] if r['joins_total'] else 0.0
        print(f"\n  ⚠ INCOMPLETE INPUT — {missing} referenced view(s) were not supplied.")
        print(f"    Only {r['joins_resolvable']} of {r['joins_total']} joins ({pct:.0f}%) can be wired.")
        print("    Each absent view becomes a LOOKER_SCRATCH.<VIEW> placeholder with its")
        print("    own warning, so the conversion will look far worse than it is.")
        print("\n    This is a MISSING-INPUT problem, not an unsupported-feature problem.")
        print("    Do not report it as 'cannot convert'. Ask for the complete LookML")
        print("    project (ideally a git clone: all views + the .model.lkml + manifest),")
        print("    or convert the resolvable subset deliberately as a scoped slice.")
        shown = r['missing_views'][:15]
        print(f"\n    Missing views ({len(r['missing_views'])}), first {len(shown)}:")
        for v in shown:
            print(f"      - {v}")
        if len(r['missing_views']) > len(shown):
            print(f"      … and {len(r['missing_views']) - len(shown)} more")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    as_json = '--json' in argv[1:]
    if not args:
        print(__doc__.strip().split('Usage:')[-1].strip(), file=sys.stderr)
        return 2
    r = analyze(args)
    if as_json:
        print(json.dumps(r, indent=2))
    else:
        report(r)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
