#!/usr/bin/env python3
"""Validate every .bim fixture in this directory.

Checks each file is valid JSON and follows the TMSL shape of model_clean.bim:
- top-level `model` (`compatibilityLevel` is optional for converter fixtures)
- `model.tables` is a non-empty list
- every measure has a `name` + `expression`; every calculated column has a
  `type == "calculated"` + `expression`
- every calculated-table partition has an expression

Prints a per-fixture count of explicit measures, calculated columns, and
calculated tables, then a total. Exits non-zero if any fixture fails a
structural assertion.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def validate(path: Path):
    """Return DAX object counts. Raises AssertionError on bad shape."""
    with path.open() as fh:
        model = json.load(fh)  # raises JSONDecodeError if not valid JSON

    assert "model" in model, "missing top-level 'model'"
    tables = model["model"].get("tables")
    assert isinstance(tables, list) and tables, "model.tables must be a non-empty list"

    n_measures = 0
    n_calc_cols = 0
    n_calc_tables = 0

    for t in tables:
        assert "name" in t, "table missing name"
        # partitions are required for a real TMSL table
        assert t.get("partitions"), f"table {t['name']} missing partitions"
        for partition in t["partitions"]:
            source = partition.get("source") or {}
            if source.get("type") == "calculated":
                assert source.get("expression"), (
                    f"calculated-table partition {t['name']} missing expression"
                )
                n_calc_tables += 1

        for m in t.get("measures", []) or []:
            assert m.get("name"), f"measure missing name in table {t['name']}"
            assert m.get("expression"), f"measure {m.get('name')} missing expression"
            n_measures += 1

        for c in t.get("columns", []) or []:
            if c.get("type") == "calculated":
                assert c.get("expression"), (
                    f"calc column {c.get('name')} missing expression"
                )
                n_calc_cols += 1

    return n_measures, n_calc_cols, n_calc_tables


def main():
    bims = sorted(HERE.glob("*.bim"))
    assert bims, "no .bim fixtures found"

    total_m = total_c = total_t = 0
    failures = []
    print(f"Validating {len(bims)} fixture(s) in {HERE}\n")
    for p in bims:
        try:
            nm, nc, nt = validate(p)
        except (AssertionError, json.JSONDecodeError) as e:
            failures.append((p.name, str(e)))
            print(f"  FAIL  {p.name}: {e}")
            continue
        total_m += nm
        total_c += nc
        total_t += nt
        print(f"  PASS  {p.name}: {nm} measures, {nc} calc columns, "
              f"{nt} calc tables")

    print(f"\nTOTAL: {total_m} measures + {total_c} calc columns + "
          f"{total_t} calc tables = {total_m + total_c + total_t} "
          f"DAX expressions across {len(bims)} fixtures")

    if failures:
        print(f"\n{len(failures)} fixture(s) FAILED")
        sys.exit(1)
    print("\nAll fixtures valid.")


if __name__ == "__main__":
    main()
