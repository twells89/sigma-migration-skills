# Public Spotfire fixture staging

The committed regression corpus uses a synthetic authoritative manifest. It
does not redistribute a DXP because raw package internals are not the converter
contract and the customer-side exporter output cannot be generated here
without a licensed Spotfire runtime.

For first live exporter validation, use TIBCO's BSD-3-Clause BPME sample:

- repository: `https://github.com/TIBCOSoftware/bpme-samples`
- license: `https://github.com/TIBCOSoftware/bpme-samples/blob/master/LICENSE.md`
- DXP: `https://raw.githubusercontent.com/TIBCOSoftware/bpme-samples/master/analytics/BPME_Analytics.dxp`
- pinned SHA-256: `99942943d609263f2d10d46f7f4ccd25dc139df6c4bbd2f1fef1f1b9ffa3e6c2`
- pinned byte size: `4368243`

Download and verify outside the repository:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/TIBCOSoftware/bpme-samples/master/analytics/BPME_Analytics.dxp \
  -o /tmp/BPME_Analytics.dxp
printf '%s  %s\n' \
  99942943d609263f2d10d46f7f4ccd25dc139df6c4bbd2f1fef1f1b9ffa3e6c2 \
  /tmp/BPME_Analytics.dxp | sha256sum -c -
```

Open the file in a version-compatible Spotfire Analyst runtime, run
`scripts/export_spotfire_manifest.py`, and keep the resulting manifest and
screenshots in license-review staging until customer and security review is
complete. Do not make a converter golden directly from the DXP ZIP/XML.
