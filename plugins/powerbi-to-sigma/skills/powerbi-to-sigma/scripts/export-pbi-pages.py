#!/usr/bin/env python3
"""export-pbi-pages.py — download the SOURCE Power BI report's rendered pages
for the Phase 5e visual compare.

Uses the ExportToFile API. PNG export is commonly DISABLED at tenant level
("Export report to image is disabled") — PDF almost never is, and a per-page
PDF is fine for the compare (the agent Reads PDFs/PNGs the same way). When
pypdf is importable the PDF is split into one file per page; otherwise the
single multi-page PDF is kept (Read it with the `pages` parameter).

Requires the report's workspace to be on capacity (Fabric trial/premium).

Usage:
  python3 export-pbi-pages.py --report <reportId> --out-dir ./visual-qa
"""
import truststore; truststore.inject_into_ssl()
import argparse, os, sys, time
import msal, requests

CACHE = os.environ.get("PBI_TOKEN_CACHE", "/tmp/pbiauth/cache.bin")
CLIENT = "ea0616ba-638b-4df5-95b9-636659ae5121"


def token():
    cache = msal.SerializableTokenCache()
    if os.path.exists(CACHE):
        cache.deserialize(open(CACHE).read())
    app = msal.PublicClientApplication(
        CLIENT, authority="https://login.microsoftonline.com/organizations", token_cache=cache)
    for a in app.get_accounts():
        r = app.acquire_token_silent(["https://analysis.windows.net/powerbi/api/.default"], account=a)
        if r and "access_token" in r:
            return r["access_token"]
    flow = app.initiate_device_flow(scopes=["https://analysis.windows.net/powerbi/api/.default"])
    print(">>> " + flow["verification_uri"] + " code " + flow["user_code"], file=sys.stderr)
    return app.acquire_token_by_device_flow(flow)["access_token"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--workspace", default=None, help="group id; omit for My workspace")
    ap.add_argument("--out-dir", default="./visual-qa")
    a = ap.parse_args()
    tok = token()
    H = {"Authorization": f"Bearer {tok}"}
    base = ("https://api.powerbi.com/v1.0/myorg" if not a.workspace
            else f"https://api.powerbi.com/v1.0/myorg/groups/{a.workspace}")
    os.makedirs(a.out_dir, exist_ok=True)

    fmt_order = ["PNG", "PDF"]  # PNG preferred; tenant-disabled falls through to PDF
    for fmt in fmt_order:
        r = requests.post(f"{base}/reports/{a.report}/ExportTo",
                          headers={**H, "Content-Type": "application/json"}, json={"format": fmt})
        if r.status_code == 403 and "disabled" in r.text:
            print(f"[export] {fmt} disabled at tenant level — trying next format", file=sys.stderr)
            continue
        r.raise_for_status()
        eid = r.json()["id"]
        st = {}
        for _ in range(80):
            st = requests.get(f"{base}/reports/{a.report}/exports/{eid}", headers=H).json()
            if st.get("status") in ("Succeeded", "Failed"):
                break
            time.sleep(5)
        if st.get("status") != "Succeeded":
            sys.exit(f"export failed: {st}")
        data = requests.get(f"{base}/reports/{a.report}/exports/{eid}/file", headers=H).content
        if data[:2] == b"PK":  # PNG multi-page comes back zipped
            import io, zipfile
            zipfile.ZipFile(io.BytesIO(data)).extractall(a.out_dir)
            print(f"[export] unzipped page PNGs -> {a.out_dir}", file=sys.stderr)
        elif fmt == "PDF":
            pdf = os.path.join(a.out_dir, "powerbi-report.pdf")
            open(pdf, "wb").write(data)
            try:
                from pypdf import PdfReader, PdfWriter
                rd = PdfReader(pdf)
                for i, pg in enumerate(rd.pages, 1):
                    w = PdfWriter(); w.add_page(pg)
                    with open(os.path.join(a.out_dir, f"powerbi-page{i}.pdf"), "wb") as f:
                        w.write(f)
                print(f"[export] {len(rd.pages)} page PDFs -> {a.out_dir}", file=sys.stderr)
            except ImportError:
                print(f"[export] wrote {pdf} (pypdf not installed — Read it with pages=N)", file=sys.stderr)
        else:
            open(os.path.join(a.out_dir, "powerbi-report.png"), "wb").write(data)
        print(os.listdir(a.out_dir))
        return
    sys.exit("all export formats disabled for this tenant")


if __name__ == "__main__":
    main()
