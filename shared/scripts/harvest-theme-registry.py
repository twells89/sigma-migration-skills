#!/usr/bin/env python3
"""harvest-theme-registry.py — build a persistent per-org theme registry.

Themes have no list API (unlike plugins, which now have GET /v2/plugins). The
only place a theme id appears is a workbook spec's `document.settings.theme.name`
(live since 2026-08; the old top-level `themeName` no longer appears on GET). So
we harvest: list every workbook, GET each spec, collect the distinct theme name
values (built-in names + org-theme UUIDs) and how many workbooks use each.

Persists to ~/.sigma-migration/theme-registry.yaml keyed by org host, so the
authoring skill can offer known themes instead of asking the user to supply a
UUID blind. Also dumps GET /v2/plugins (the plugin registry) for free.

Usage:
  python3 harvest-theme-registry.py --env ~/.sigma-migration/env [--workers 10] [--limit N]

Env file must export SIGMA_BASE_URL and any settings needed by the shared
browser-first Sigma token provider.
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

REGISTRY = os.path.expanduser("~/.sigma-migration/theme-registry.yaml")

_HERE = os.path.dirname(os.path.abspath(__file__))
for _lib in (os.path.join(_HERE, "lib"), os.path.join(_HERE, "..", "lib")):
    if os.path.isdir(_lib):
        sys.path.insert(0, _lib)
import sigma_rest


def parse_env(path):
    env = {}
    for line in open(os.path.expanduser(path)):
        m = re.match(r"\s*(?:export\s+)?(\w+)\s*=\s*['\"]?([^'\"\n]+)", line)
        if m:
            env[m.group(1)] = m.group(2)
    return env


def api(base, path, accept_json=True, retries=5):
    # Sigma sits behind Cloudflare and returns 429 (CF error 1015) when spec GETs
    # are fired too fast — back off and retry so a full harvest doesn't silently
    # drop workbooks. Honors Retry-After when present.
    delay = 1.0
    rate_retries = 0
    auth_retried = False
    while True:
        req = urllib.request.Request(base + path)
        req.add_header("Authorization", f"Bearer {sigma_rest.auth_token()}")
        req.add_header("Accept", "application/json")  # spec GET returns YAML without this
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 401 and not auth_retried:
                sigma_rest.refresh_token()
                auth_retried = True
                continue
            if e.code == 429 and rate_retries < retries:
                ra = e.headers.get("Retry-After")
                time.sleep(float(ra) if ra and ra.isdigit() else delay)
                delay = min(delay * 2, 16)
                rate_retries += 1
                continue
            raise


def get_token(env):
    os.environ.update(env)
    return sigma_rest.refresh_token()


def list_workbooks(base, cap=None):
    ids, page = [], None
    while True:
        q = "limit=1000" + (f"&page={urllib.parse.quote(page)}" if page else "")
        d = api(base, f"/v2/workbooks?{q}")
        ids += [w["workbookId"] for w in d.get("entries", [])]
        if cap and len(ids) >= cap:
            return ids[:cap]
        if not d.get("hasMore") or not d.get("nextPage"):
            return ids
        page = d["nextPage"]


def theme_of(base, wb):
    try:
        spec = api(base, f"/v2/workbooks/{wb}/spec")
        # Live GET nests under `document`; tolerate a legacy flat artifact too.
        doc = spec.get("document", spec) if isinstance(spec, dict) else {}
        return (doc.get("settings") or {}).get("theme", {}).get("name")  # None if no theme set
    except Exception as e:
        return ("__error__", str(e)[:40])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--limit", type=int, default=None, help="cap workbooks scanned (benchmark)")
    a = ap.parse_args()

    env = parse_env(a.env)
    base = env["SIGMA_BASE_URL"]
    host = urllib.parse.urlparse(base).netloc
    t0 = time.time()
    get_token(env)
    plugins = api(base, "/v2/plugins?pageSize=1000").get("entries", [])
    wbs = list_workbooks(base, a.limit)
    t_list = time.time() - t0

    themes, errors = {}, 0
    t1 = time.time()
    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        futs = {ex.submit(theme_of, base, wb): wb for wb in wbs}
        for f in as_completed(futs):
            r = f.result()
            if isinstance(r, tuple):
                errors += 1
            elif r:
                themes[r] = themes.get(r, 0) + 1
    t_specs = time.time() - t1
    total = time.time() - t0

    def is_uuid(s):
        return bool(re.fullmatch(r"[0-9a-f-]{36}", s or ""))
    org_themes = {k: v for k, v in themes.items() if is_uuid(k)}
    builtins = {k: v for k, v in themes.items() if not is_uuid(k)}

    print(f"\n=== {host} ===")
    print(f"  workbooks scanned : {len(wbs)}  (errors {errors})")
    print(f"  plugins (GET /v2/plugins): {len(plugins)}")
    print(f"  distinct themes in use   : {len(themes)}  "
          f"({len(org_themes)} org-UUID, {len(builtins)} built-in)")
    for k, v in sorted(themes.items(), key=lambda x: -x[1]):
        print(f"     {v:4d} wb  {k}")
    rate = len(wbs) / t_specs if t_specs else 0
    print(f"  timing: token+list {t_list:.1f}s | {len(wbs)} specs {t_specs:.1f}s "
          f"({rate:.1f} specs/s, {a.workers}w) | total {total:.1f}s")

    # merge into the shared registry
    reg = {}
    if os.path.exists(REGISTRY):
        try:
            import yaml
            reg = yaml.safe_load(open(REGISTRY)) or {}
        except Exception:
            reg = {}
    reg.setdefault(host, {})
    reg[host]["themes"] = {k: {"workbooks": v, "kind": "org" if is_uuid(k) else "builtin"}
                           for k, v in themes.items()}
    reg[host]["plugins"] = {p["pluginId"]: p.get("name") for p in plugins}
    reg[host]["scanned_workbooks"] = len(wbs)
    try:
        import yaml
        with open(REGISTRY, "w") as f:
            yaml.safe_dump(reg, f, sort_keys=True)
        print(f"  registry → {REGISTRY}")
    except Exception as e:
        print(f"  registry write skipped: {e}")
    return rate


if __name__ == "__main__":
    main()
