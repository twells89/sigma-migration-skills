#!/usr/bin/env python3
"""POST/PUT a Sigma model or workbook and immediately verify its readback."""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402

DERIVATION_FIELDS = {"derivedVia", "partial", "droppedConditions"}


def load_object(path: str) -> dict:
    with Path(path).open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def strip_derivation_fields(value):
    if isinstance(value, dict):
        return {
            key: strip_derivation_fields(item)
            for key, item in value.items()
            if key not in DERIVATION_FIELDS
        }
    if isinstance(value, list):
        return [strip_derivation_fields(item) for item in value]
    return value


def iter_elements(spec: dict, kind: str):
    if kind == "datamodel":
        for page in spec.get("pages") or []:
            yield from page.get("elements") or []
    else:
        document = spec.get("document") or spec
        yield from document.get("elements") or []


def element_key(element: dict) -> str:
    source = element.get("source") or {}
    path = source.get("path") or []
    return str(element.get("name") or (path[-1] if path else element.get("id")))


def column_signature(column: dict) -> str:
    return (
        str(column.get("name") or "").strip()
        or str(column.get("formula") or "").strip()
    )


def census(spec: dict, kind: str) -> dict[str, set[str]]:
    return {
        element_key(element): {
            column_signature(column) for column in element.get("columns") or []
        }
        for element in iter_elements(spec, kind)
        if isinstance(element, dict)
    }


def error_columns(spec: dict, kind: str) -> list[dict]:
    errors = []
    for element in iter_elements(spec, kind):
        for column in element.get("columns") or []:
            if column.get("type") == "error" or column.get("error"):
                errors.append(
                    {
                        "element": element_key(element),
                        "column": column.get("name") or column.get("id"),
                        "error": column.get("error") or column.get("message"),
                    }
                )
    return errors


def verify_census(posted: dict, readback: dict, kind: str) -> dict:
    expected = census(posted, kind)
    actual = census(readback, kind)
    missing_elements = sorted(set(expected) - set(actual))
    dropped = {}
    for name in sorted(set(expected) & set(actual)):
        missing_columns = expected[name] - actual[name]
        if missing_columns:
            dropped[name] = sorted(missing_columns)
    errors = error_columns(readback, kind)
    return {
        "pass": not missing_elements and not dropped and not errors,
        "missing_elements": missing_elements,
        "dropped_columns": dropped,
        "error_columns": errors,
    }


def request_paths(kind: str, object_id: str | None = None) -> tuple[str, str]:
    if kind == "datamodel":
        return (
            f"/v2/dataModels/{object_id}/spec" if object_id else "/v2/dataModels/spec",
            "dataModelId",
        )
    return (
        f"/v2/workbooks/{object_id}/spec" if object_id else "/v2/workbooks/spec",
        "workbookId",
    )


def post_and_readback(
    kind: str,
    spec: dict,
    *,
    update_id: str | None = None,
    api=sigma_rest,
) -> tuple[str, dict, dict, dict]:
    outgoing = strip_derivation_fields(copy.deepcopy(spec))
    path, id_field = request_paths(kind, update_id)
    method = "put" if update_id else "post"
    body = outgoing
    if update_id and kind == "workbook":
        body = {"document": outgoing.get("document") or outgoing}

    if kind == "workbook" and not update_id:
        try:
            api.request(
                "post",
                "/v2/workbooks/spec/verify",
                body=json.dumps(outgoing),
            )
        except Exception as exc:
            raise ValueError(f"workbook spec/verify rejected the draft: {exc}") from exc

    response = api.request(method, path, body=json.dumps(body)) or {}
    object_id = update_id or response.get(id_field) or response.get("id")
    if not object_id:
        raise ValueError(f"{method.upper()} {path} returned no {id_field}")
    read_path, _ = request_paths(kind, object_id)
    readback = api.request("get", read_path)
    if not isinstance(readback, dict):
        raise ValueError(f"GET {read_path} returned no JSON object")
    result = verify_census(outgoing, readback, kind)
    return object_id, response, readback, result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--type", choices=("datamodel", "workbook"), required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--out", required=True, help="ID map JSON")
    parser.add_argument("--workdir")
    parser.add_argument("--update-id")
    parser.add_argument("--name", help="override create name")
    parser.add_argument("--folder-id", help="override create destination folder")
    args = parser.parse_args()
    workdir = Path(args.workdir or Path(args.spec).resolve().parent)
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        draft = load_object(args.spec)
        if args.name:
            draft["name"] = args.name
        if args.folder_id:
            draft["folderId"] = args.folder_id
        object_id, response, readback, result = post_and_readback(
            args.type,
            draft,
            update_id=args.update_id,
        )
        id_field = "dataModelId" if args.type == "datamodel" else "workbookId"
        Path(args.out).write_text(
            json.dumps({id_field: object_id}, indent=2) + "\n",
            encoding="utf-8",
        )
        (workdir / f"{args.type}-post-response.json").write_text(
            json.dumps(response, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (workdir / f"{args.type}-readback.json").write_text(
            json.dumps(readback, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (workdir / f"{args.type}-readback-verdict.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        log = workdir / (
            "posted-datamodels.jsonl"
            if args.type == "datamodel"
            else "posted-workbooks.jsonl"
        )
        with log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({id_field: object_id, "update": bool(args.update_id)}) + "\n")
    except (OSError, ValueError, json.JSONDecodeError, sigma_rest.SigmaError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    if not result["pass"]:
        print(
            f"FAIL: {args.type} readback lost elements/columns or contains errors; "
            f"see {workdir / f'{args.type}-readback-verdict.json'}",
            file=sys.stderr,
        )
        return 2
    print(f"PASS: {args.type} {object_id} posted and read back clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
