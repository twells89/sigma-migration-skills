# Privacy — sisense-assessment

This skill is **read-only** and operates on **metadata**, not row data.

**What it reads** (over the Sisense REST API, with the credentials you provide):
- Data model inventory: titles, dataset/table/column names and types, relations.
- Dashboard inventory: titles, datasource names, widget types, and the JAQL
  panel definitions (dimension/measure field references and formulas).

**What it does NOT do:**
- It does **not** run warehouse queries or read row-level/customer data.
- It does **not** write to, modify, or delete anything in Sisense.
- It does **not** send anything to Sigma.
- It does **not** transmit your data to third parties. All output stays in the
  local `--out` directory.

**Credentials.** The bearer token / login is used only to call the read
endpoints listed above and is stored locally in `~/.sigma-migration/sisense.env`
(mode 600). Revoke it in Sisense at any time.

Surface this document to the customer before running the assessment.
