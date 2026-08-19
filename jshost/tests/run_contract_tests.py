#!/usr/bin/env python3
"""Contract-test runner for the headless jshost CLI.

Reuses the fcitx5 test suite's fixtures and expectations: each fcitx5/test
<name>.sh names a fixture engine and greps marker strings out of the host
log. This runner parses those same check lines out of the .sh files and
asserts them against the CLI's JSON-line output, so both platforms stay
locked to a single expectation table (port-analysis risk R12). Tests whose
assertions need the platform session layer stay with fcitx5/test.

Usage:  python3 jshost/tests/run_contract_tests.py [--cli PATH]
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = REPO_ROOT / "runtime"
FIXTURES = REPO_ROOT / "fcitx5" / "test" / "fixtures" / "share" / "fcitx5" / "macishtype"
FIXTURE_ENGINES = FIXTURES / "engines"
FIXTURE_TABLES = FIXTURES / "tables"
SH_DIR = REPO_ROOT / "fcitx5" / "test"

# Both shapes used by the .sh suite:
#   check "desc" "$out" \
#       'expected'
#   check "desc" \
#       "expected"
CHECK_RE = re.compile(
    r'^check "(?P<desc>[^"]+)"(?: "\$out")?\s*\\\s*\n'
    r'\s*(?:\'(?P<single>[^\']*)\'|"(?P<double>[^"]*)")',
    re.M,
)


def parse_checks(sh_name):
    content = (SH_DIR / f"{sh_name}.sh").read_text(encoding="utf-8")
    checks = []
    for match in CHECK_RE.finditer(content):
        expected = match.group("single")
        if expected is None:
            expected = match.group("double")
        checks.append((match.group("desc"), expected))
    if not checks:
        raise RuntimeError(f"no check lines parsed from {sh_name}.sh")
    return checks


def run_cli(cli, fixture, extra_args=(), allow_failure=False):
    """Runs the CLI and returns the joined text of every log event, one per
    line, mirroring the daemon log the .sh suite greps."""
    cmd = [
        str(cli),
        "--runtime", str(RUNTIME_DIR),
        "--load-only", "--activate",
        *extra_args,
        str(FIXTURE_ENGINES / fixture),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True,
                            encoding="utf-8", timeout=120)
    if result.returncode != 0 and not allow_failure:
        raise RuntimeError(
            f"CLI exited {result.returncode} for {fixture}:\n{result.stdout}"
            f"\n{result.stderr}")
    texts = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") == "log":
            texts.append(event.get("text", ""))
    return "\n".join(texts)


class Failures:
    def __init__(self):
        self.count = 0

    def check(self, test, desc, condition, context):
        if condition:
            print(f"PASS: [{test}] {desc}")
        else:
            self.count += 1
            print(f"FAIL: [{test}] {desc}", file=sys.stderr)
            tail = "\n".join(context.splitlines()[-20:])
            print(tail, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=None,
                        help="path to the macishtype-jshost-cli executable")
    args = parser.parse_args()

    cli = args.cli
    if cli is None:
        build = REPO_ROOT / "jshost" / "build"
        candidates = sorted(build.glob("*/macishtype-jshost-cli*"))
        candidates = [c for c in candidates
                      if c.suffix in ("", ".exe") and c.is_file()]
        if not candidates:
            sys.exit("no built macishtype-jshost-cli found under jshost/build; "
                     "pass --cli")
        cli = candidates[0]

    failures = Failures()

    # Suites whose expectations parse straight out of the fcitx5 .sh files.
    parsed_suites = [
        ("textcodec", "textcodecfixture", (), False),
        ("collator", "collatorfixture", (), False),
        ("datetime", "datetimefixture", (), False),
        ("number", "numberfixture", (), False),
        ("plural", "pluralfixture", (), False),
        ("segmenter", "segmenterfixture", (), False),
        ("modules", "modulesfixture",
         ("--tables", str(FIXTURE_TABLES)), False),
        # throwfixture throws at load; the assertions target the failure log.
        ("errorstack", "throwfixture", (), True),
    ]
    for sh_name, fixture, extra, allow_failure in parsed_suites:
        checks = parse_checks(sh_name)
        log_text = run_cli(cli, fixture, extra, allow_failure)
        for desc, expected in checks:
            failures.check(sh_name, desc, expected in log_text, log_text)

    # asyncfetch: the discriminating assertions are log ORDER, hand-ported
    # from asyncfetch.sh (the key-during-load-window assertion needs a
    # session layer the headless CLI does not have; it stays with
    # fcitx5/test).
    log_text = run_cli(cli, "asyncfetchfixture")
    loaded = log_text.find("Engine loaded: asyncfetchfixture")
    parsed = log_text.find("asyncfetch parsed entries=3")
    failures.check("asyncfetch", "the table parse completes in the background",
                   parsed >= 0, log_text)
    failures.check("asyncfetch",
                   "the engine finishes loading before the parse "
                   "(deferred fetch)",
                   0 <= loaded < parsed, log_text)
    failures.check("asyncfetch",
                   "text() rejects invalid UTF-8 after an embedded NUL",
                   "asyncfetch nul-text Error msg=Body is not valid UTF-8"
                   in log_text, log_text)

    log_text = run_cli(cli, "tlafixture")
    tla = log_text.find("tla loaded entries=3")
    tla_loaded = log_text.find("Engine loaded: tlafixture")
    failures.check("asyncfetch", "a top-level-await engine still loads",
                   tla_loaded >= 0, log_text)
    failures.check("asyncfetch",
                   "its awaited fetch settles during load "
                   "(synchronous fallback)",
                   0 <= tla < tla_loaded, log_text)

    # ExampleEngine end-to-end smoke: compose -> candidates -> commit
    # (engines/example has no other automated test).
    commands = "\n".join([
        '{"do":"activate"}',
        '{"do":"wait-quiescent"}',
        '{"do":"key","key":"h","code":"KeyH"}',
        '{"do":"key","key":"i","code":"KeyI"}',
        '{"do":"key","key":" ","code":"Space"}',
        '{"do":"quit"}',
    ]) + "\n"
    result = subprocess.run(
        [str(cli), "--runtime", str(RUNTIME_DIR),
         str(REPO_ROOT / "engines" / "example")],
        input=commands, capture_output=True, text=True, encoding="utf-8",
        timeout=120)
    out = result.stdout
    failures.check("example", "the demo table loads through fetch",
                   "demo.txt loaded, entries: 4" in out, out)
    failures.check("example", "typing composes marked text",
                   '{"event":"action","name":"updateMarkedText","args":["HI",null]}'
                   in out, out)
    failures.check("example", "space commits the top candidate",
                   '"name":"commit","args":[{"candidate":"哈囉"' in out, out)

    if failures.count:
        sys.exit(f"{failures.count} check(s) failed")
    print("All contract checks passed.")


if __name__ == "__main__":
    main()
