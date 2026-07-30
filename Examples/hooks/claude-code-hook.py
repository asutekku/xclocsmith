#!/usr/bin/env python3
"""Claude Code PostToolUse hook: check the file that was just written.

Wire it up in `.claude/settings.json`:

    {
      "hooks": {
        "PostToolUse": [
          {
            "matcher": "Edit|Write",
            "hooks": [
              {
                "type": "command",
                "command": "python3 Examples/hooks/claude-code-hook.py"
              }
            ]
          }
        ]
      }
    }

A `.swift` file is scanned for user-visible strings that reach no catalog. An
`.xcstrings` file is checked for the defects that ship as bugs: format
specifiers that disagree with the source, case-colliding keys that break symbol
generation, glossary terms a translation dropped, and one English string
translated two different ways.

Exit 2 hands the message back to the model, which is the point: it fixes the
string it just wrote instead of hearing about it at review time.

The tool is not being asked about translation coverage here. A string added in
this edit has no Japanese yet and is not supposed to — that is what `check`
across the whole project is for, at a moment when someone means to translate.
"""

import json
import shutil
import subprocess
import sys

BLOCK = 2
PASS = 0
LIMIT = 20


def run(arguments):
    """The tool's JSON report, or None if it could not be produced."""
    executable = shutil.which("xclocsmith")
    if executable is None:
        # Not installed is worth saying, but it is not the model's problem and
        # must not stop it working.
        print("xclocsmith is not on PATH; skipping.", file=sys.stderr)
        return None
    finished = subprocess.run(
        [executable] + arguments + ["--json"],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(finished.stdout)
    except json.JSONDecodeError:
        message = finished.stderr.strip() or "no output"
        print(f"xclocsmith {' '.join(arguments)} failed: {message}", file=sys.stderr)
        return None


def swift_findings(path):
    report = run(["scan", "--files", path])
    if report is None:
        return []
    return [
        f"{f['file']}:{f['line']}  \"{f['value']}\" is in no catalog "
        f"(expected in {f['catalog']})"
        for f in report.get("missingKeys", [])
    ]


def catalog_findings(path):
    report = run(["check", path])
    if report is None:
        return []

    findings = []
    for catalog in report.get("catalogs", []):
        for mismatch in catalog.get("formatMismatches", []):
            findings.append(
                f"[{mismatch['language']}] \"{mismatch['key']}\": {mismatch['problem']}"
            )
        for duplicate in catalog.get("caseDuplicates", []):
            if duplicate.get("breaksSymbolGeneration"):
                keys = " vs ".join(duplicate["keys"])
                findings.append(f"keys collide by case, breaking symbols: {keys}")
        for violation in catalog.get("glossaryViolations", []):
            findings.append(
                f"[{violation['language']}] \"{violation['term']}\" must render as "
                f"\"{violation['expected']}\", got \"{violation['translation']}\""
            )
        for duplicate in catalog.get("duplicateSources", []):
            for divergence in duplicate.get("divergences", []):
                renderings = "  vs  ".join(
                    f"\"{r['value']}\" ({r['key']})" for r in divergence["renderings"]
                )
                findings.append(
                    f"\"{duplicate['text']}\" is translated two ways in "
                    f"[{divergence['language']}]: {renderings}"
                )
    return findings


def main():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return PASS

    path = payload.get("tool_input", {}).get("file_path", "")
    if path.endswith(".swift"):
        findings = swift_findings(path)
    elif path.endswith(".xcstrings"):
        findings = catalog_findings(path)
    else:
        return PASS

    if not findings:
        return PASS

    print(f"xclocsmith found {len(findings)} localization issue(s):", file=sys.stderr)
    for finding in findings[:LIMIT]:
        print(f"  - {finding}", file=sys.stderr)
    if len(findings) > LIMIT:
        print(f"  … and {len(findings) - LIMIT} more", file=sys.stderr)
    return BLOCK


if __name__ == "__main__":
    sys.exit(main())
