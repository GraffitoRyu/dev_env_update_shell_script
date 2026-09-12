#!/usr/bin/env python3
"""Run with python3 tests/cask-audit.py; Homebrew and app discovery are mocked."""
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / "check-available-migration-cask.sh"
REPORTS = (
    "apps-raw.txt", "apps-normalized.txt", "installed-casks.txt",
    "installed-cask-names.txt", "apps-audit.csv", "unmanaged-apps.txt",
)
APP_NAME = 'Say "Hello", C:\\tools'
MOCK = r'''
import json, os, pathlib, sys
mode = os.environ["AUDIT_TEST_MODE"]
if pathlib.Path(sys.argv[0]).name == "find":
    roots = sys.argv[1:sys.argv.index("-maxdepth")]
    if mode == "collection_failure" or any(not pathlib.Path(p).is_dir() for p in roots):
        print("mock app collection failed", file=sys.stderr)
        sys.exit(2)
    for app in json.loads(os.environ["AUDIT_TEST_APPS"]):
        print("/Applications/" + app + ".app")
elif sys.argv[1] == "list":
    if mode == "list_failure":
        print("mock cask list failed", file=sys.stderr)
        sys.exit(2)
    if mode in ("info_failure", "managed"):
        print("installed-tool")
elif sys.argv[1] == "info":
    if mode == "info_failure":
        print("mock cask info failed", file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"casks": [{"token": "installed-tool", "name": ["Installed Tool"]}]}))
elif sys.argv[1] == "search":
    if mode in ("search_failure", "alias_search_failure") or (mode == "late_search_failure" and sys.argv[-1] == "Second App"):
        print("mock cask search failed", file=sys.stderr)
        sys.exit(2)
    print("==> Casks")
    if mode == "many_candidates":
        for number in range(2000):
            print(f"tool-{number:04}: " + "description " * 20)
    elif mode != "empty":
        print('hello-tool: A "quoted" description, C:\\tools')
else:
    sys.exit("unexpected mock brew arguments: " + repr(sys.argv))
'''


def check(mode, optional_folder=True):
    with tempfile.TemporaryDirectory(prefix="cask-audit-test-") as directory:
        root = Path(directory).resolve()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for command in ("brew", "find"):
            executable = bin_dir / command
            executable.write_text(f"#!{sys.executable}\n" + MOCK)
            executable.chmod(0o755)
        test_home = root / "home"
        test_home.mkdir()
        if optional_folder:
            (test_home / "Applications").mkdir()
        report_dir = root / "brew-app-audit"
        report_dir.mkdir()
        original = {name: ("previous " + name + "\n").encode() for name in REPORTS}
        for name, content in original.items():
            (report_dir / name).write_bytes(content)
        apps = ["Installed Tool"] if mode == "managed" else [APP_NAME]
        if mode == "alias_search_failure":
            apps = ["iTerm"]
        elif mode == "late_search_failure":
            apps = [APP_NAME, "Second App"]
        env = dict(os.environ, PATH=f"{bin_dir}:/usr/bin:/bin", HOME=str(test_home),
                   AUDIT_TEST_MODE=mode, AUDIT_TEST_APPS=json.dumps(apps))
        result = subprocess.run(["zsh", str(SCRIPT)], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30)
        assert not list(report_dir.glob(".audit.*")), (mode, "staging directory leaked", result.returncode, result.stdout, result.stderr)
        if mode.endswith("failure"):
            assert result.returncode != 0, (mode, result.stdout, result.stderr)
            assert "Done:" not in result.stdout, (mode, result.stdout)
            assert "mock" in result.stderr, (mode, result.stderr)
            assert {name: (report_dir / name).read_bytes() for name in REPORTS} == original, mode
        else:
            assert result.returncode == 0, (mode, result.stdout, result.stderr)
            assert f"- CSV: {report_dir / 'apps-audit.csv'}" in result.stdout
            with (report_dir / "apps-audit.csv").open(newline="") as stream:
                rows = list(csv.DictReader(stream, strict=True))
            if optional_folder or Path("/Applications").is_dir():
                assert len(rows) == 1 and rows[0]["app_name"] == apps[0], rows
                row = rows[0]
                assert row["is_brew_managed"] == ("yes" if mode == "managed" else "no"), row
                if mode in ("empty", "managed"):
                    assert row["cask_candidates"] == "", row
                elif mode == "many_candidates":
                    assert len(row["cask_candidates"].split(";")) == 12, row
                else:
                    assert row["cask_candidates"] == 'hello-tool: A "quoted" description, C:\\tools', row
                if mode != "managed":
                    assert (report_dir / "unmanaged-apps.txt").read_text() == APP_NAME + "\n"
        print(f"PASS: {mode}" + (" without ~/Applications" if not optional_folder else ""))


if __name__ == "__main__":
    for scenario in ("collection_failure", "list_failure", "info_failure", "search_failure",
                     "alias_search_failure", "late_search_failure", "success", "empty", "managed", "many_candidates"):
        check(scenario)
    check("success", optional_folder=False)
