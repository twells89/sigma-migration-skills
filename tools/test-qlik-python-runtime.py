#!/usr/bin/env python3
"""Cross-platform, credentials-free smoke test for Qlik's Python runtime."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "plugins" / "qlik-to-sigma" / "skills" / "qlik-to-sigma"
SCRIPTS = SKILL / "scripts"
RETAIL = SKILL / "fixtures" / "retail-orders"
CORECTL = SKILL / "fixtures" / "corectl-country-unbuild"
CONNECTION = "00000000-0000-0000-0000-000000000000"
ORIGINAL_PATH = os.environ.get("PATH", "")
SECRET_PREFIXES = ("QLIK_", "SIGMA_")
SECRET_KEYS = {
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
    """Expose only smoke-test tools, never a directory containing Ruby."""
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
        key: value
        for key, value in os.environ.items()
        if key not in SECRET_KEYS
        and not any(key.startswith(prefix) for prefix in SECRET_PREFIXES)
    }
    environment.update(
        {
            "PATH": path,
            "HOME": str(home),
            "SIGMA_OFFLINE_DRY_RUN": "1",
            "SIGMA_RUNTIME_PROFILE": "python",
            "SIGMA_SKIP_VERSION_CHECK": "1",
            "PYTHONHASHSEED": "0",
        }
    )
    return environment


def run_raw(
    command: list[str | Path],
    environment: dict[str, str],
    *,
    cwd: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(item) for item in command],
        cwd=cwd,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
        timeout=180,
    )


def run(
    label: str,
    command: list[str | Path],
    environment: dict[str, str],
    *,
    cwd: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    completed = run_raw(command, environment, cwd=cwd)
    if completed.returncode != 0:
        raise AssertionError(
            f"{label} failed ({completed.returncode})\n"
            f"command: {[str(item) for item in command]!r}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    print(f"PASS {label}")
    return completed


def read_json(path: Path):
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def assert_ruby_absent(environment: dict[str, str]) -> None:
    ruby = shutil.which("ruby", path=environment["PATH"])
    if ruby is not None:
        raise AssertionError(f"ruby must not resolve in the certified path: {ruby}")


def install_doctor_evidence(workdir: Path, doctor: dict) -> None:
    workdir.mkdir(parents=True, exist_ok=True)
    write_json(workdir / "doctor.json", doctor)
    write_json(
        workdir / "bootstrap.json",
        {
            "doctor_pass": True,
            "runtime_profile": doctor["runtime_profile"],
        },
    )


def migration_command(discovery: Path, workdir: Path, database: str, schema: str):
    return [
        sys.executable,
        SCRIPTS / "migrate-qlik.py",
        "--from-discovery",
        discovery,
        "--connection",
        CONNECTION,
        "--database",
        database,
        "--schema",
        schema,
        "--dry-run",
        "--yes",
        "--out",
        workdir,
    ]


def workbook_elements(document: dict) -> list:
    direct = document.get("elements")
    if isinstance(direct, list):
        return direct
    elements = []
    for page in document.get("pages") or []:
        if isinstance(page, dict):
            elements.extend(page.get("elements") or [])
    return elements


def assert_artifacts(
    label: str,
    workdir: Path,
    output: str,
    *,
    minimum_visuals: int,
    require_source_controls: bool,
) -> None:
    required = (
        "dm-spec.json",
        "wb-spec.json",
        "layout.xml",
        "element-map.json",
        "control-scope.json",
        "workbook-coverage.json",
        "formula-mapping.json",
        "security.json",
    )
    missing = [name for name in required if not (workdir / name).is_file()]
    if missing:
        raise AssertionError(f"{label}: missing production artifacts: {missing}")

    dm = read_json(workdir / "dm-spec.json")
    dm_elements = [
        element
        for page in dm.get("pages") or []
        if isinstance(page, dict)
        for element in page.get("elements") or []
    ]
    if len(dm_elements) < 2:
        raise AssertionError(f"{label}: data model is not meaningful: {len(dm_elements)} elements")

    workbook = read_json(workdir / "wb-spec.json")
    document = workbook.get("document") or workbook
    pages = document.get("pages") or []
    elements = workbook_elements(document)
    if not pages or len(elements) < minimum_visuals:
        raise AssertionError(
            f"{label}: workbook is not meaningful: pages={len(pages)} "
            f"elements={len(elements)}"
        )

    element_map = read_json(workdir / "element-map.json")
    if not isinstance(element_map, list) or len(element_map) < minimum_visuals:
        raise AssertionError(f"{label}: element-map has only {len(element_map)} entries")

    coverage = read_json(workdir / "workbook-coverage.json")
    if (
        coverage.get("status") != "PASS"
        or coverage.get("sourceVisuals", 0) < minimum_visuals
        or coverage.get("queryableElements", 0) < minimum_visuals
        or coverage.get("unbuiltSourceVisualIds")
    ):
        raise AssertionError(f"{label}: source coverage is incomplete: {coverage}")

    scope = read_json(workdir / "control-scope.json")
    if require_source_controls and (
        scope.get("sourceFilterSignals", 0) < 1 or not scope.get("controls")
    ):
        raise AssertionError(f"{label}: source controls were not rebuilt: {scope}")

    formula_mapping = read_json(workdir / "formula-mapping.json")
    if not isinstance(formula_mapping, (dict, list)):
        raise AssertionError(f"{label}: formula-mapping.json has an invalid shape")

    layout = (workdir / "layout.xml").read_text(encoding="utf-8-sig")
    if "<Page" not in layout:
        raise AssertionError(f"{label}: layout.xml has no page layout")

    lowered = output.lower()
    if "dry" not in lowered or not any(
        marker in lowered for marker in ("phase", "convert", "workbook")
    ):
        raise AssertionError(f"{label}: migration output lacks useful phase/dry-run evidence")


def main() -> int:
    for fixture in (RETAIL, CORECTL):
        if not fixture.is_dir():
            raise AssertionError(f"missing source fixture: {fixture}")
    if not (SCRIPTS / "migrate-qlik.py").is_file():
        raise AssertionError("certified entrypoint is missing: scripts/migrate-qlik.py")

    with tempfile.TemporaryDirectory(prefix="qlik-python-cold-") as temporary:
        root = Path(temporary)
        path, bash = ruby_free_path(root)
        environment = clean_environment(path, root / "home")
        assert_ruby_absent(environment)
        print("Ruby command resolution after quarantine: None")

        profile_args = [
            SCRIPTS / "runtime_profile.py",
            "--capabilities",
            SKILL / "runtime-capabilities.json",
            "--runtime",
            "ruby=false",
            "--runtime",
            "python=true",
            "--runtime",
            "node=true",
            "--runtime",
            "bash=true",
        ]
        explicit = json.loads(
            run(
                "explicit Python profile resolution",
                [sys.executable, *profile_args, "--requested", "python"],
                environment,
            ).stdout
        )
        assert explicit["pass"] is True
        assert explicit["selectedProfile"] == "python"
        assert explicit["requiredRuntimes"] == ["python", "node"]
        assert explicit["observedRuntimes"]["ruby"] is False

        automatic = json.loads(
            run(
                "automatic no-Ruby fallback",
                [sys.executable, *profile_args, "--requested", "auto"],
                environment,
            ).stdout
        )
        assert automatic["pass"] is True
        assert automatic["selectedProfile"] == "python"
        assert "ruby" in (automatic["fallbackReason"] or "").lower()

        doctor_work = root / "doctor"
        doctor_result = run(
            "doctor contract",
            [
                bash,
                SCRIPTS / "doctor.sh",
                "--runtime-profile",
                "python",
                "--workdir",
                doctor_work,
            ],
            environment,
            cwd=SKILL,
        )
        if "ruby not found" not in doctor_result.stdout.lower():
            raise AssertionError("doctor did not report quarantined Ruby")
        doctor = read_json(doctor_work / "doctor.json")
        assert doctor["pass"] is True
        assert doctor["runtimes"]["ruby"] is False
        assert doctor["runtime_profile"]["selected"] == "python"
        assert doctor["runtime_profile"]["required_runtimes"] == ["python", "node"]

        if os.name == "nt":
            powershell = executable("powershell")
            powershell_work = root / "doctor-powershell"
            run(
                "PowerShell Python-profile doctor contract",
                [
                    powershell,
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    SCRIPTS / "doctor.ps1",
                    "-RuntimeProfile",
                    "python",
                    "-WorkDir",
                    powershell_work,
                ],
                environment,
                cwd=SKILL,
            )
            powershell_doctor = read_json(powershell_work / "doctor.json")
            assert powershell_doctor["pass"] is True
            assert powershell_doctor["runtimes"]["ruby"] is False
            assert powershell_doctor["runtime_profile"]["selected"] == "python"
        else:
            fake_bin = root / "fake-ruby-bin"
            fake_bin.mkdir()
            ruby_probe = root / "ruby-was-executed"
            fake_ruby = fake_bin / "ruby"
            fake_ruby.write_text(
                "#!/bin/sh\n"
                f": > {ruby_probe}\n"
                "exit 99\n",
                encoding="utf-8",
            )
            fake_ruby.chmod(0o755)
            optional_ruby_environment = dict(environment)
            optional_ruby_environment["PATH"] = (
                str(fake_bin) + os.pathsep + environment["PATH"]
            )
            run(
                "Python doctor ignores optional broken Ruby",
                [
                    bash,
                    SCRIPTS / "doctor.sh",
                    "--runtime-profile",
                    "python",
                    "--workdir",
                    root / "optional-ruby-doctor",
                ],
                optional_ruby_environment,
                cwd=SKILL,
            )
            if ruby_probe.exists():
                raise AssertionError("Python runtime doctor executed optional Ruby")

        # The production front door must refuse a green doctor without the
        # bootstrap sentinel. This exercises its hard gate, not a test double.
        gate_work = root / "missing-bootstrap"
        gate_work.mkdir()
        write_json(gate_work / "doctor.json", doctor)
        blocked = run_raw(
            migration_command(RETAIL, gate_work, "DEMO_DB", "DEMO"),
            environment,
            cwd=SKILL,
        )
        blocked_text = f"{blocked.stdout}\n{blocked.stderr}".lower()
        if blocked.returncode == 0 or "bootstrap" not in blocked_text:
            raise AssertionError(
                "doctor hard gate did not reject a missing bootstrap sentinel\n"
                f"exit={blocked.returncode}\n{blocked_text}"
            )
        if (gate_work / "dm-spec.json").exists() or (gate_work / "wb-spec.json").exists():
            raise AssertionError("doctor hard gate allowed build artifacts before bootstrap")
        print("PASS doctor hard gate")

        retail_work = root / "retail"
        install_doctor_evidence(retail_work, doctor)
        retail_result = run(
            "retail discovery fixture through Python front door",
            migration_command(RETAIL, retail_work, "DEMO_DB", "DEMO"),
            environment,
            cwd=SKILL,
        )
        assert_artifacts(
            "retail fixture",
            retail_work,
            f"{retail_result.stdout}\n{retail_result.stderr}",
            minimum_visuals=5,
            require_source_controls=True,
        )
        assert_ruby_absent(environment)

        core_discovery = root / "corectl-discovery"
        run(
            "corectl fixture normalization",
            [
                sys.executable,
                SCRIPTS / "qlik-unbuild-discover.py",
                "--unbuild",
                CORECTL,
                "--out",
                core_discovery,
            ],
            environment,
            cwd=SKILL,
        )
        core_work = root / "corectl"
        install_doctor_evidence(core_work, doctor)
        core_result = run(
            "corectl fixture through Python --from-discovery front door",
            migration_command(core_discovery, core_work, "ANALYTICS", "PUBLIC"),
            environment,
            cwd=SKILL,
        )
        assert_artifacts(
            "corectl fixture",
            core_work,
            f"{core_result.stdout}\n{core_result.stderr}",
            minimum_visuals=2,
            require_source_controls=False,
        )
        assert_ruby_absent(environment)

    print("ALL PASS: Qlik Python runtime is cold-start safe without Ruby")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
