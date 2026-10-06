#!/usr/bin/env python3
"""One-command Streamlit migration orchestrator (dry-run by default)."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(SCRIPTS / "lib"))

from converter import analyze_project, build_data_model, build_workbook  # noqa: E402
import sigma_rest  # noqa: E402


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def source_neutral_env() -> None:
    """Retain the public bootstrap hook while delegating to the shared client."""
    sigma_rest.bootstrap_credentials()


class SigmaAPI:
    def __init__(self) -> None:
        source_neutral_env()
        try:
            self.base_url = sigma_rest.base_url().rstrip("/")
            # Keep the constructor's fail-fast URL check and trailing-slash
            # normalization while the shared client owns all auth decisions.
            sigma_rest.validate_base_url(self.base_url)
            os.environ["SIGMA_BASE_URL"] = self.base_url
            self.token = sigma_rest.auth_token()
        except (sigma_rest.SigmaError, SystemExit) as error:
            raise RuntimeError(
                "Sigma authentication unavailable via a pre-minted token, "
                f"browser login, or client credentials: {error}"
            ) from error

    def request(
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> Any:
        payload = json.dumps(body) if body is not None else None
        try:
            # binary=True keeps response parsing here byte-for-byte compatible
            # (including Sigma's occasional YAML create response) while the
            # shared transport owns token reuse, proactive refresh, and one
            # refresh/retry after a 401.
            content = sigma_rest.request(
                method,
                path,
                body=payload,
                accept="application/json",
                binary=True,
            )
        except sigma_rest.SigmaError as error:
            detail = str(error)
            match = re.search(r" -> (\d+)[^\n]*\n?(.*)", detail, re.DOTALL)
            if match:
                raise RuntimeError(
                    f"{method} {path} failed ({match.group(1)}): {match.group(2)}"
                ) from error
            raise RuntimeError(f"{method} {path} failed: {detail}") from error

        # Preserve the public token attribute for callers that inspect it.
        self.token = os.environ.get("SIGMA_API_TOKEN", self.token)
        if not content:
            return {}
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            try:
                import yaml  # type: ignore

                return yaml.safe_load(content.decode("utf-8"))
            except (ImportError, ValueError):
                # Create responses are shallow YAML maps; preserve ids even
                # when PyYAML is unavailable.
                result = {}
                for line in content.decode("utf-8", errors="replace").splitlines():
                    if ":" not in line or line.startswith((" ", "-")):
                        continue
                    key, value = line.split(":", 1)
                    result[key.strip()] = value.strip().strip("\"'")
                if result:
                    return result
                raise RuntimeError(f"Unable to parse Sigma response from {path}")


def resolve_folder(api: SigmaAPI, requested: str | None) -> str:
    if requested:
        return requested
    who = api.request("GET", "/v2/whoami")
    member = api.request("GET", f"/v2/members/{who['userId']}")
    return member["homeFolderId"]


def data_model_bindings(
    dm_spec: dict[str, Any],
    data_model_id: str,
    queries: list[Any],
) -> dict[str, dict[str, Any]]:
    elements = [
        element
        for page in dm_spec.get("pages", [])
        for element in page.get("elements", [])
    ]
    by_name = {str(item.get("name", "")).lower(): item for item in elements}
    result = {}
    for query in queries:
        function = query.function
        expected = function.replace("_", " ").title()
        element = by_name.get(expected.lower())
        if not element:
            raise RuntimeError(
                f"Data model readback has no element matching query `{function}`"
            )
        available = {
            str(column.get("name", "")).casefold()
            for column in element.get("columns", [])
        }
        missing = [
            column
            for column in query.columns
            if column.casefold() not in available
        ]
        if missing:
            raise RuntimeError(
                f"Data model element `{expected}` is missing columns: {missing}"
            )
        result[query.id] = {
            "dataModelId": data_model_id,
            "elementId": element["id"],
            "name": element.get("name") or expected,
        }
    return result


def validate_layout(workbook: dict[str, Any]) -> None:
    document = workbook["document"]
    element_ids = {item["id"] for item in document.get("elements", [])}
    placed = re.findall(r'\belementId="([^"]+)"', document.get("layout", ""))
    placed_ids = set(placed)
    missing = element_ids - placed_ids
    dangling = placed_ids - element_ids
    duplicates = {item for item in placed if placed.count(item) > 1}
    if missing or dangling or duplicates:
        raise RuntimeError(
            "Workbook layout invalid: "
            f"missing={sorted(missing)}, dangling={sorted(dangling)}, "
            f"duplicates={sorted(duplicates)}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("--connection", required=True)
    parser.add_argument("--folder")
    parser.add_argument("--name")
    parser.add_argument("--out-dir", default="streamlit-migration")
    parser.add_argument("--post", action="store_true")
    parser.add_argument(
        "--reuse-decision",
        choices=("custom-sql", "new-dm", "reuse"),
        help="Required before --post; records the C3 reuse gate decision.",
    )
    parser.add_argument("--dm-id", help="Existing DM id for --reuse-decision reuse")
    parser.add_argument("--allow-blocking-gaps", action="store_true")
    parser.add_argument("--allow-conversion-warnings", action="store_true")
    parser.add_argument("--ack-security", action="store_true")
    args = parser.parse_args()

    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    ir = analyze_project(args.source)
    write_json(out / "streamlit-ir.json", ir.to_dict())
    write_json(out / "gaps.json", [item for item in ir.to_dict()["gaps"]])
    write_json(out / "security.json", [item for item in ir.to_dict()["security"]])

    signature = {
        "source": "streamlit",
        "project": ir.project_name,
        "queries": [
            {
                "function": query.function,
                "columns": query.columns,
                "dynamic": query.dynamic,
                "sql": query.sql,
            }
            for query in ir.queries
        ],
    }
    write_json(out / "source-signature.json", signature)

    if args.post and not args.reuse_decision:
        print(
            "Reuse decision required. Review source-signature.json and run "
            "scripts/find-or-pick-dm.rb, then pass --reuse-decision.",
            file=sys.stderr,
        )
        return 14
    blocking = [gap for gap in ir.gaps if gap.severity == "blocking"]
    if args.post and blocking and not args.allow_blocking_gaps:
        print(
            f"{len(blocking)} blocking gap(s); review gaps.json or pass "
            "--allow-blocking-gaps with an explicit decision.",
            file=sys.stderr,
        )
        return 13
    if args.post and ir.security and not args.ack_security:
        print(
            "Security-sensitive source patterns detected; review security.json "
            "and pass --ack-security.",
            file=sys.stderr,
        )
        return 12

    api = SigmaAPI() if args.post else None
    folder_id = resolve_folder(api, args.folder) if api else args.folder or "<FOLDER_ID>"
    dm_result = build_data_model(
        ir,
        args.connection,
        folder_id,
        f"{args.name} — Streamlit Source" if args.name else None,
    )
    write_json(out / "dm-result.json", dm_result)
    write_json(out / "dm-spec.json", dm_result["dataModel"])
    preflight_wb_result = build_workbook(
        ir,
        args.connection,
        folder_id,
        args.name,
        "custom-sql",
        {},
    )
    conversion_warnings = [
        *dm_result.get("warnings", []),
        *preflight_wb_result.get("warnings", []),
    ]
    write_json(out / "conversion-warnings.json", conversion_warnings)
    if args.post and conversion_warnings and not args.allow_conversion_warnings:
        print(
            f"{len(conversion_warnings)} conversion warning(s) could cause "
            "semantic loss; review conversion-warnings.json or pass "
            "--allow-conversion-warnings with an explicit decision.",
            file=sys.stderr,
        )
        return 11

    bindings: dict[str, dict[str, Any]] = {}
    data_model_id = None
    source_mode = "custom-sql"
    if args.post and args.reuse_decision == "new-dm":
        created = api.request("POST", "/v2/dataModels/spec", dm_result["dataModel"])
        data_model_id = created["dataModelId"]
        readback = api.request("GET", f"/v2/dataModels/{data_model_id}/spec")
        write_json(out / "dm-create-response.json", created)
        write_json(out / "dm-readback.json", readback)
        bindings = data_model_bindings(
            readback,
            data_model_id,
            ir.queries,
        )
        source_mode = "data-model"
    elif args.post and args.reuse_decision == "reuse":
        if not args.dm_id:
            raise RuntimeError("--dm-id is required with --reuse-decision reuse")
        data_model_id = args.dm_id
        readback = api.request("GET", f"/v2/dataModels/{data_model_id}/spec")
        write_json(out / "dm-readback.json", readback)
        bindings = data_model_bindings(
            readback,
            data_model_id,
            ir.queries,
        )
        source_mode = "data-model"

    wb_result = (
        preflight_wb_result
        if source_mode == "custom-sql"
        else build_workbook(
            ir,
            args.connection,
            folder_id,
            args.name,
            source_mode,
            bindings,
        )
    )
    if (
        args.post
        and wb_result.get("warnings")
        and not args.allow_conversion_warnings
    ):
        # This can differ from custom-SQL preflight when a reused DM does not
        # expose the expected columns.
        write_json(out / "conversion-warnings.json", wb_result["warnings"])
        print(
            "Data-model-bound workbook produced conversion warnings; posting stopped.",
            file=sys.stderr,
        )
        return 11
    workbook = wb_result["workbook"]
    validate_layout(workbook)
    write_json(out / "workbook-result.json", wb_result)
    write_json(out / "wb-spec.json", workbook)
    (out / "layout.xml").write_text(
        workbook["document"]["layout"], encoding="utf-8"
    )

    workbook_id = None
    workbook_url = None
    if args.post:
        api.request("POST", "/v2/workbooks/spec/verify", workbook)
        created = api.request("POST", "/v2/workbooks/spec", workbook)
        workbook_id = created["workbookId"]
        readback = api.request("GET", f"/v2/workbooks/{workbook_id}/spec")
        validate_layout(readback)
        write_json(out / "wb-create-response.json", created)
        write_json(out / "wb-readback.json", readback)
        workbook_url = readback.get("url")

    parity = {
        "status": "not-run",
        "hardGate": True,
        "dataModelId": data_model_id,
        "workbookId": workbook_id,
        "required": [
            "source anchors",
            "Sigma element queries",
            "warehouse comparison",
            "control flip tests",
            "page PNG comparison",
        ],
    }
    write_json(out / "parity-final.json", parity)
    write_json(
        out / "mission.json",
        {
            "source": str(Path(args.source).resolve()),
            "reuseDecision": args.reuse_decision or "not-run",
            "posted": args.post,
            "dataModelId": data_model_id,
            "workbookId": workbook_id,
            "completion": "needs-parity",
        },
    )
    print(
        json.dumps(
            {
                "outDir": str(out),
                "posted": args.post,
                "dataModelId": data_model_id,
                "workbookId": workbook_id,
                "workbookUrl": workbook_url,
                "completion": "needs-parity",
                "gaps": len(ir.gaps),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
