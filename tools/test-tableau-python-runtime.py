#!/usr/bin/env python3
"""Cross-platform, credentials-free smoke test for Tableau's Python runtime."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "plugins" / "tableau-to-sigma" / "skills" / "tableau-to-sigma"
SCRIPTS = SKILL / "scripts"
TWB = (
    ROOT
    / "corpus"
    / "tableau"
    / "logical-model-objectgraph"
    / "workbook-content.twb"
)
ORIGINAL_PATH = os.environ.get("PATH", "")
SECRET_KEYS = {
    "SIGMA_API_TOKEN",
    "SIGMA_CLIENT_ID",
    "SIGMA_CLIENT_SECRET",
    "TABLEAU_PAT_NAME",
    "TABLEAU_PAT_SECRET",
    "TABLEAU_TOKEN",
}


def executable(name: str) -> Path:
    found = shutil.which(name, path=ORIGINAL_PATH)
    if not found:
        raise AssertionError(f"required executable is unavailable: {name}")
    return Path(found).resolve()


def ruby_free_path(root: Path) -> tuple[str, Path]:
    """Expose only the tools used by this smoke test, never a Ruby directory."""
    bash = executable("bash")
    node = executable("node")
    git = executable("git")
    if os.name == "nt":
        directories = {
            Path(sys.executable).resolve().parent,
            Path(sys.executable).resolve().parent / "Scripts",
            bash.parent,
            bash.parent.parent / "usr" / "bin",
            node.parent,
            git.parent,
            Path(os.environ["SystemRoot"]) / "System32",
        }
        path = os.pathsep.join(str(item) for item in directories if item.is_dir())
        return path, bash

    tool_bin = root / "bin"
    tool_bin.mkdir()
    tools = {
        "bash": bash,
        "python": Path(sys.executable).resolve(),
        "python3": Path(sys.executable).resolve(),
        "node": node,
        "git": git,
    }
    for name in (
        "cut",
        "date",
        "dirname",
        "grep",
        "head",
        "mkdir",
        "sed",
        "tr",
        "uname",
    ):
        tools[name] = executable(name)
    for name, source in tools.items():
        (tool_bin / name).symlink_to(source)
    return str(tool_bin), bash


def clean_environment(path: str, home: Path) -> dict[str, str]:
    environment = {
        key: value for key, value in os.environ.items() if key not in SECRET_KEYS
    }
    environment.update(
        {
            "PATH": path,
            "HOME": str(home),
            "SIGMA_BASE_URL": "https://example.invalid",
            "SIGMA_CLIENT_ID": "ci-offline-placeholder",
            "SIGMA_CLIENT_SECRET": "ci-offline-placeholder",
            "SIGMA_RUNTIME_PROFILE": "python",
            "SIGMA_SKIP_CRED_SMOKE": "1",
            "SIGMA_SKIP_VERSION_CHECK": "1",
        }
    )
    return environment


def run(
    label: str,
    command: list[str | Path],
    environment: dict[str, str],
    *,
    cwd: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    rendered = [str(item) for item in command]
    completed = subprocess.run(
        rendered,
        cwd=cwd,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
        timeout=120,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"{label} failed ({completed.returncode})\n"
            f"command: {rendered!r}\nstdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    print(f"PASS {label}")
    return completed


def read_json(path: Path):
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path: Path, value) -> None:
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    if not TWB.is_file():
        raise AssertionError(f"missing source fixture: {TWB}")
    with tempfile.TemporaryDirectory(prefix="tableau-python-cold-") as temporary:
        root = Path(temporary)
        path, bash = ruby_free_path(root)
        environment = clean_environment(path, root / "home")

        ruby = shutil.which("ruby", path=environment["PATH"])
        print(f"Ruby command resolution after quarantine: {ruby!r}")
        if ruby is not None:
            raise AssertionError(f"ruby must not be executable in this job: {ruby}")

        profile = json.loads(
            run(
                "runtime profile resolution",
                [
                    sys.executable,
                    SCRIPTS / "runtime_profile.py",
                    "--capabilities",
                    SKILL / "runtime-capabilities.json",
                    "--requested",
                    "python",
                    "--allow-preview",
                    "--runtime",
                    "ruby=false",
                    "--runtime",
                    "python=true",
                    "--runtime",
                    "node=true",
                    "--runtime",
                    "bash=true",
                ],
                environment,
            ).stdout
        )
        assert profile["pass"] is True
        assert profile["selectedProfile"] == "python"
        assert profile["observedRuntimes"]["ruby"] is False
        assert "ruby" not in profile["requiredRuntimes"]

        workdir = root / "work"
        doctor = run(
            "doctor contract",
            [
                bash,
                SCRIPTS / "doctor.sh",
                "--runtime-profile",
                "python",
                "--allow-preview-runtime",
                "--workdir",
                workdir,
            ],
            environment,
            cwd=SKILL,
        )
        assert "ruby not found" in doctor.stdout
        doctor_json = read_json(workdir / "doctor.json")
        assert doctor_json["pass"] is True
        assert doctor_json["runtimes"]["ruby"] is False
        assert doctor_json["runtime_profile"]["selected"] == "python"
        write_json(
            workdir / "bootstrap.json",
            {
                "doctor_pass": True,
                "runtime_profile": doctor_json["runtime_profile"],
            },
        )
        run(
            "doctor hard gate",
            [
                sys.executable,
                SCRIPTS / "assert-doctor-ran.py",
                "--workdir",
                workdir,
                "--runtime-profile",
                "python",
            ],
            environment,
        )

        source = workdir / "tableau-source.json"
        run(
            "Tableau source classification",
            [sys.executable, SCRIPTS / "tableau_source.py", "--twb", TWB, "--out", source],
            environment,
        )
        assert read_json(source)["classification"] == "live-warehouse"

        layout = workdir / "dashboard-layout.json"
        run(
            "Tableau layout parse",
            [sys.executable, SCRIPTS / "parse-twb-layout.py", TWB, layout],
            environment,
        )
        assert read_json(layout)

        gaps_report = workdir / "gaps.md"
        run(
            "Tableau gap scan",
            [sys.executable, SCRIPTS / "scan-workbook-gaps.py", TWB, gaps_report],
            environment,
        )
        gaps = read_json(workdir / "gaps.json")
        assert isinstance(gaps["detected_features"], list)
        assert gaps["formula_audit"] == read_json(workdir / "formula-audit.json")

        conversion = workdir / "conversion"
        run(
            "Tableau conversion",
            [
                sys.executable,
                SCRIPTS / "convert-tableau.py",
                "--twb",
                TWB,
                "--connection",
                "offline-connection",
                "--database",
                "OFFLINE_DB",
                "--schema",
                "OFFLINE_SCHEMA",
                "--out",
                conversion,
            ],
            environment,
        )
        assert read_json(conversion / "dm-raw.json")["pages"]

        builder_layout = workdir / "builder-layout.json"
        builder_meta = workdir / "builder-meta.json"
        write_json(
            builder_layout,
            [
                {
                    "dashboard": "Cold Runtime",
                    "emit_page": True,
                    "zones": [
                        {
                            "id": "sales",
                            "kind": "chart",
                            "chart_kind": "bar",
                            "caption": "Sales by Region",
                            "x_pct": 0,
                            "y_pct": 0,
                            "w_pct": 100,
                            "h_pct": 100,
                            "rows_shelf": {
                                "fields": [
                                    {
                                        "guid": "SALES",
                                        "role": "measure",
                                        "derivation": "sum",
                                    }
                                ]
                            },
                            "cols_shelf": {
                                "fields": [
                                    {
                                        "guid": "REGION",
                                        "role": "dim",
                                        "derivation": "none",
                                    }
                                ]
                            },
                            "filters": [],
                        }
                    ],
                }
            ],
        )
        write_json(
            builder_meta,
            {
                "columns_by_guid": {
                    "SALES": {"caption": "Sales", "datatype": "real"},
                    "REGION": {"caption": "Region", "datatype": "string"},
                }
            },
        )
        workbook = workdir / "wb-spec.json"
        run(
            "Sigma workbook build",
            [
                sys.executable,
                SCRIPTS / "build-workbook-from-signals.py",
                "--layout",
                builder_layout,
                "--meta",
                builder_meta,
                "--formula-audit",
                workdir / "formula-audit.json",
                "--data-model-id",
                "offline-dm",
                "--element-id",
                "offline-fact",
                "--data-model-element-name",
                "LMOG_FACT_WIDE",
                "--folder-id",
                "offline-folder",
                "--out",
                workbook,
            ],
            environment,
        )
        document = read_json(workbook)["document"]
        assert document["elements"]
        assert list(document)[-1] == "layout"

        plan = workdir / "parity-plan.json"
        expected = workdir / "expected.json"
        write_json(
            plan,
            {"charts": [{"chart": "LMOG Customer Revenue", "expected": [["A", 1]]}]},
        )
        run(
            "parity plan transform",
            [
                sys.executable,
                SCRIPTS / "parity-plan-to-expected.py",
                "--plan",
                plan,
                "--out",
                expected,
            ],
            environment,
        )
        assert read_json(expected) == {"LMOG Customer Revenue": [["A", 1]]}

        run(
            "completion result gate",
            [
                sys.executable,
                SCRIPTS / "test_verify_complete.py",
                "VerifyCompleteTest.test_green_requires_every_gate",
            ],
            environment,
        )
        run(
            "consolidated completion gate",
            [
                sys.executable,
                SCRIPTS / "test_assert_phase6_ran.py",
                "AssertPhase6RanTest.test_all_gates_pass_and_write_hash_bound_success_marker",
            ],
            environment,
        )

    print("ALL PASS: Tableau Python runtime is cold-start safe without Ruby")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
