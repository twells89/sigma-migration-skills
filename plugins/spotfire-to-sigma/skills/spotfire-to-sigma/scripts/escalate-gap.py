#!/usr/bin/env python3
"""escalate-gap — opt-in GitHub-issue filer for gap-scout escalations.

Shared across every migration skill (vendored identically into each plugin's
scripts/). When the gap scout can't find a working Sigma translation for a
source feature, the main agent offers the user the *option* to open a tracking
issue in the appropriate repo. This script is what turns that "yes" into filed
issues — with dedupe, repo routing, converter-repo mirroring, and a cross-linked
bead.

DESIGN: opt-in, never automatic.
  - Default (no --yes): DRY RUN. Prints the drafted issue(s), the target repo(s),
    and any existing open issues/beads that already cover this gap. Files NOTHING.
    This is what the agent shows the user.
  - With --yes: actually files. Skips any repo where dedupe already found a match
    (unless --force).

ROUTING (category -> repos):
  converter  -> twells89/sigma-data-model-manager + twells89/sigma-data-model-mcp
               (a source expression the *converter* failed to translate — the
                browser tool and the MCP must stay in sync, so mirror to both)
  builder    -> twells89/sigma-migration-skills   (workbook/DM spec builder gap)
  skill      -> twells89/sigma-migration-skills   (skill-logic / discovery gap)

Usage (dry-run draft the agent shows the user):
  python3 scout/escalate-gap.py \
    --skill tableau-to-sigma --category converter \
    --feature WINDOW_AVG --description 'moving average over SUM' \
    --source-pattern 'WINDOW_AVG(SUM([...]))' \
    --template-attempted 'MovingAvg(Sum([Master/\\1]), -10, 10)' \
    --test-formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
    --sigma-response '<failing column type / error json>' \
    --example-from 'Sales.twb line 412' \
    --escalation-yaml ~/.tableau-to-sigma/escalations/window_avg.yaml

Then, only if the user says yes, the agent re-runs the same command with --yes.

Requires `gh` on PATH and authed for the target repos. `bd` (beads) optional.
Exit codes: 0 = ok (drafted or filed), 3 = nothing fileable / gh missing on --yes.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

ROUTES = {
    "converter": ["twells89/sigma-data-model-manager", "twells89/sigma-data-model-mcp"],
    "builder":   ["twells89/sigma-migration-skills"],
    "skill":     ["twells89/sigma-migration-skills"],
}
BEADS_DIR = os.path.expanduser("~/.beads-sigma")


def have(cmd):
    return shutil.which(cmd) is not None


def run(args, **kw):
    """Run a command, return (ok, stdout, stderr)."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, **kw)
        return p.returncode == 0, p.stdout.strip(), p.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return False, "", str(e)


def build_issue(a):
    title = f"{a.skill} gap: {a.feature}" + (f" ({a.description})" if a.description else "")
    body = []
    body.append(f"**Skill:** `{a.skill}`")
    body.append(f"**Gap category:** `{a.category}`")
    body.append(f"**Feature:** `{a.feature}`")
    if a.description:
        body.append(f"**Description:** {a.description}")
    if a.source_pattern:
        body.append(f"**Source pattern:** `{a.source_pattern}`")
    if a.template_attempted:
        body.append(f"**Sigma template attempted:** `{a.template_attempted}`")
    if a.test_formula:
        body.append(f"**Test formula POSTed:** `{a.test_formula}`")
    if a.sigma_response:
        body.append(f"**Sigma response:**\n```\n{a.sigma_response}\n```")
    body.append(f"**Example source:** {a.example_from or '(not provided)'}")
    if a.escalation_yaml:
        body.append(f"**Local escalation record:** `{a.escalation_yaml}`")
    body.append("\n_Filed via the gap-scout opt-in escalation flow (`escalate-gap.py`)._")
    return title, "\n\n".join(body)


def labels_for(a):
    return ["gap-scout-escalation", a.skill, f"category:{a.category}"]


def ensure_labels(repo, labels):
    """Best-effort: create labels so `gh issue create --label` won't fail."""
    for lab in labels:
        run(["gh", "label", "create", lab, "--repo", repo, "--force"])


def find_dupes(repo, feature, skill):
    """Return list of {number,title,url} open issues that look like this gap."""
    ok, out, _ = run([
        "gh", "issue", "list", "--repo", repo, "--state", "open",
        "--label", "gap-scout-escalation", "--search", feature,
        "--json", "number,title,url",
    ])
    if not ok or not out:
        return []
    try:
        items = json.loads(out)
    except Exception:  # noqa: BLE001
        return []
    feat = feature.lower()
    return [i for i in items if feat in (i.get("title", "").lower())]


def find_bead_dupe(feature):
    if not (have("bd") and os.path.isdir(BEADS_DIR)):
        return None
    ok, out, _ = run(["bd", "list", "--json"], cwd=BEADS_DIR)
    if not ok or not out:
        return None
    try:
        items = json.loads(out)
    except Exception:  # noqa: BLE001
        return None
    rows = items if isinstance(items, list) else items.get("issues", items.get("beads", []))
    feat = feature.lower()
    for b in rows or []:
        if feat in (str(b.get("title", "")) + str(b.get("summary", ""))).lower():
            return b.get("id") or b.get("bead_id")
    return None


def create_bead(title, body, skill, category):
    if not (have("bd") and os.path.isdir(BEADS_DIR)):
        return None
    labels = f"sigma-converter,{skill},gap-scout-escalation,category:{category}"
    ok, out, _ = run([
        "bd", "create", title, "--priority", "2", "--labels", labels,
        "--description", body, "--silent",
    ], cwd=BEADS_DIR)
    return out.strip() if ok else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", required=True)
    ap.add_argument("--feature", required=True)
    ap.add_argument("--category", default="converter", choices=list(ROUTES))
    ap.add_argument("--description", default="")
    ap.add_argument("--source-pattern", default="")
    ap.add_argument("--template-attempted", default="")
    ap.add_argument("--test-formula", default="")
    ap.add_argument("--sigma-response", default="")
    ap.add_argument("--example-from", default="")
    ap.add_argument("--escalation-yaml", default="")
    ap.add_argument("--extra-repo", action="append", default=[],
                    help="additional target repo(s), repeatable")
    ap.add_argument("--yes", action="store_true",
                    help="actually file. Without it: dry-run, prints the draft only.")
    ap.add_argument("--force", action="store_true",
                    help="file even if a matching open issue already exists")
    ap.add_argument("--no-beads", action="store_true")
    a = ap.parse_args()

    repos = list(dict.fromkeys(ROUTES[a.category] + a.extra_repo))
    title, body = build_issue(a)
    labels = labels_for(a)

    # Dedupe scan (read-only) up front so the agent can show it to the user.
    gh_ok = have("gh")
    dupes = {r: (find_dupes(r, a.feature, a.skill) if gh_ok else []) for r in repos}
    bead_dupe = None if a.no_beads else find_bead_dupe(a.feature)

    if not a.yes:
        # DRY RUN — this is what the agent presents to the user.
        out = {
            "mode": "draft",
            "would_file_in": repos,
            "labels": labels,
            "title": title,
            "body": body,
            "existing_issues": {r: d for r, d in dupes.items() if d},
            "existing_bead": bead_dupe,
            "gh_available": gh_ok,
            "next_step": "re-run with --yes to file (skips repos already covered)",
        }
        print(json.dumps(out, indent=2))
        return 0

    # --yes: actually file.
    if not gh_ok:
        print(json.dumps({"status": "error", "error": "gh not on PATH; cannot file"}))
        return 3

    # Bead first (authoritative tracker), so its id can be embedded in issues.
    bead_id = bead_dupe
    if bead_id is None and not a.no_beads:
        bead_id = create_bead(title, body, a.skill, a.category)
    issue_body = body + (f"\n\n**Bead:** `{bead_id}`" if bead_id else "")

    filed, skipped = [], []
    for repo in repos:
        if dupes.get(repo) and not a.force:
            skipped.append({"repo": repo, "existing": dupes[repo]})
            continue
        ensure_labels(repo, labels)
        ok, out, err = run([
            "gh", "issue", "create", "--repo", repo,
            "--title", title, "--body", issue_body,
            "--label", ",".join(labels),
        ])
        if ok:
            filed.append({"repo": repo, "url": out.strip()})
        else:
            # retry once without labels (in case label creation was denied)
            ok2, out2, err2 = run([
                "gh", "issue", "create", "--repo", repo,
                "--title", title, "--body", issue_body,
            ])
            if ok2:
                filed.append({"repo": repo, "url": out2.strip(), "note": "filed without labels"})
            else:
                filed.append({"repo": repo, "error": err or err2})

    # Cross-link mirrored issues to each other.
    urls = [f["url"] for f in filed if f.get("url")]
    if len(urls) > 1:
        for f in filed:
            if not f.get("url"):
                continue
            others = [u for u in urls if u != f["url"]]
            num = f["url"].rstrip("/").split("/")[-1]
            link_body = issue_body + "\n\n**Mirrored to:** " + ", ".join(others)
            run(["gh", "issue", "edit", num, "--repo", f["repo"], "--body", link_body])

    # Cross-link the bead back to the filed issue urls.
    if bead_id and urls and have("bd"):
        run(["bd", "update", bead_id, "--description",
             issue_body + "\n\nFiled issues: " + ", ".join(urls)], cwd=BEADS_DIR)

    print(json.dumps({
        "status": "filed",
        "filed": filed,
        "skipped_existing": skipped,
        "bead_id": bead_id,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
