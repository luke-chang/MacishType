#!/usr/bin/env python3
"""Contract-test runner for the headless jshost CLI.

Reuses the fcitx5 test suite's fixtures and expectations: each fcitx5/test
<name>.sh names a fixture engine and greps marker strings out of the host
log. This runner parses those same check lines out of the .sh files and
asserts them against the CLI's JSON-line output, so both platforms stay
locked to a single expectation table (port-analysis risk R12). Tests whose
assertions need the platform session layer stay with fcitx5/test.

Usage:  python3 jshost/tests/RunContractTests.py [--cli PATH]
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# The shared runtime scripts now live beside their owning libraries, so the
# CLI takes a search path rather than one directory.
RUNTIME_DIRS = [REPO_ROOT / "shared" / "js", REPO_ROOT / "jshost" / "js"]
RUNTIME_ARGS = [arg for d in RUNTIME_DIRS for arg in ("--runtime", str(d))]
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
# Call sites CHECK_RE must account for. Shapes it does not cover (expected on
# the first line, a log variable other than $out, desc alone on the first line)
# would otherwise be skipped or capture the wrong field silently.
CHECK_CALL_RE = re.compile(r'^[ \t]*check[ \t]', re.M)
CHECK_ABSENT_CALL_RE = re.compile(r'^[ \t]*check_absent[ \t]', re.M)


def parse_checks(sh_name):
    content = (SH_DIR / f"{sh_name}.sh").read_text(encoding="utf-8")
    checks = []
    for match in CHECK_RE.finditer(content):
        expected = match.group("single")
        if expected is None:
            expected = match.group("double")
        if expected.startswith("$"):
            raise RuntimeError(
                f"{sh_name}.sh: check {match.group('desc')!r} parsed "
                f"{expected!r} as its expected string; the shell variable "
                f"holding the log belongs on the check's first line")
        checks.append((match.group("desc"), expected))
    if not checks:
        raise RuntimeError(f"no check lines parsed from {sh_name}.sh")
    calls = len(CHECK_CALL_RE.findall(content))
    if len(checks) != calls:
        raise RuntimeError(
            f"{sh_name}.sh has {calls} check call(s) but {len(checks)} "
            f"parsed; CHECK_RE misses a line shape used in this file")
    absent = len(CHECK_ABSENT_CALL_RE.findall(content))
    if absent:
        raise RuntimeError(
            f"{sh_name}.sh has {absent} check_absent call(s), which this "
            f"runner does not port; assert them here by hand")
    return checks


def run_cli(cli, fixture, extra_args=(), allow_failure=False):
    """Runs the CLI and returns the joined text of every log event, one per
    line, mirroring the daemon log the .sh suite greps."""
    cmd = [
        str(cli),
        *RUNTIME_ARGS,
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
        if len(candidates) > 1:
            listed = "\n  ".join(str(path.relative_to(REPO_ROOT))
                                 for path in candidates)
            sys.exit("multiple macishtype-jshost-cli builds under jshost/build; "
                     f"pass --cli to choose one:\n  {listed}")
        cli = candidates[0]

    failures = Failures()

    # Suites whose expectations parse straight out of the fcitx5 .sh files.
    parsed_suites = [
        ("TextCodec", "textcodecfixture", (), False),
        ("Collator", "collatorfixture", (), False),
        ("DateTime", "datetimefixture", (), False),
        ("Number", "numberfixture", (), False),
        ("Plural", "pluralfixture", (), False),
        ("Segmenter", "segmenterfixture", (), False),
        ("Modules", "modulesfixture",
         ("--tables", str(FIXTURE_TABLES)), False),
        ("MenuBad", "menubadfixture", (), False),
        # throwfixture throws at load; the assertions target the failure log.
        ("ErrorStack", "throwfixture", (), True),
        # Contract.sh pins LANGUAGE=zh_TW:en_US; jshost expands the
        # region->base chain itself, so the two tags reproduce it.
        ("Contract", "contractfixture", ("--languages", "zh-TW,en-US"), False),
    ]
    for sh_name, fixture, extra, allow_failure in parsed_suites:
        checks = parse_checks(sh_name)
        log_text = run_cli(cli, fixture, extra, allow_failure)
        for desc, expected in checks:
            failures.check(sh_name, desc, expected in log_text, log_text)

    # asyncfetch: the discriminating assertions are log ORDER, hand-ported
    # from AsyncFetch.sh (the key-during-load-window assertion needs a
    # session layer the headless CLI does not have; it stays with
    # fcitx5/test).
    log_text = run_cli(cli, "asyncfetchfixture")
    loaded = log_text.find("Engine loaded: asyncfetchfixture")
    parsed = log_text.find("asyncfetch parsed entries=3")
    failures.check("AsyncFetch", "the table parse completes in the background",
                   parsed >= 0, log_text)
    failures.check("AsyncFetch",
                   "the engine finishes loading before the parse "
                   "(deferred fetch)",
                   0 <= loaded < parsed, log_text)
    failures.check("AsyncFetch",
                   "text() rejects invalid UTF-8 after an embedded NUL",
                   "asyncfetch nul-text Error msg=Body is not valid UTF-8"
                   in log_text, log_text)

    log_text = run_cli(cli, "tlafixture")
    tla = log_text.find("tla loaded entries=3")
    tla_loaded = log_text.find("Engine loaded: tlafixture")
    failures.check("AsyncFetch", "a top-level-await engine still loads",
                   tla_loaded >= 0, log_text)
    failures.check("AsyncFetch",
                   "its awaited fetch settles during load "
                   "(synchronous fallback)",
                   0 <= tla < tla_loaded, log_text)

    # menu: the CLI half of the manifest-menu contract, hand-written because
    # its assertions need stdin verbs, counting, and a second run (the
    # daemon half — fcitx actions, TriggerProperty — lives in
    # fcitx5/test/Menu.sh and MenuUi.sh).
    menu_store = Path(tempfile.mkdtemp()) / "menu-store.txt"

    def run_menu_verbs(commands, extra_args=()):
        result = subprocess.run(
            [str(cli), *RUNTIME_ARGS, *extra_args,
             str(FIXTURE_ENGINES / "menufixture")],
            input="\n".join(commands) + "\n", capture_output=True, text=True,
            encoding="utf-8", timeout=120)
        if result.returncode != 0:
            raise RuntimeError(
                f"CLI exited {result.returncode} for menufixture:\n"
                f"{result.stdout}\n{result.stderr}")
        return result.stdout

    out = run_menu_verbs([
        '{"do":"activate"}',
        '{"do":"menu"}',
        '{"do":"menu-flip","key":"verboseHints"}',
        '{"do":"key","key":"a","code":"KeyA"}',
        '{"do":"menu-flip","key":"verboseHints"}',
        '{"do":"menu-flip","key":"undeclared"}',
        '{"do":"menu"}',
        '{"do":"quit"}',
    ], ("--menu-store", str(menu_store)))
    failures.check(
        "Menu", "declared keys read their defaults in declaration order",
        'menufx eval keys=[\\"strictMode\\",\\"verboseHints\\",\\"extraPanel\\"]'
        " strict=false verbose=true extra=false undeclared=undefined" in out,
        out)
    failures.check(
        "Menu", "the resolved menu keeps declaration order and dividers",
        '{"event":"menu","items":['
        '{"key":"strictMode","label":"Strict matching","value":false,"disabled":false},'
        '{"divider":true},'
        '{"key":"verboseHints","label":"Verbose hints","value":true,"disabled":false},'
        '{"divider":true},'
        '{"key":"extraPanel","label":"Extra panel","value":false,"disabled":false}]}'
        in out, out)
    failures.check(
        "Menu", "a host flip reports the change",
        '{"event":"menu-flip","changed":true}' in out, out)
    failures.check(
        "Menu", "the host flip dispatches menuchange with no key",
        "menufx menuchange key=undefined strict=false verbose=false"
        " extra=false" in out, out)
    failures.check(
        "Menu", "exactly one menuchange fires (self-write does not echo)",
        out.count("menufx menuchange") == 1, out)
    failures.check(
        "Menu", "a JS self-write acts immediately",
        "menufx self-write strict=true" in out, out)
    failures.check(
        "Menu", "a flip on a disabled item is refused",
        out.count('{"event":"menu-flip","changed":false}') == 2, out)
    failures.check(
        "Menu", "an undeclared-key flip is ignored with a notice",
        "menu flip ignored, undeclared key: undeclared" in out, out)
    failures.check(
        "Menu", "the final resolved menu reflects values and disabling",
        '{"key":"verboseHints","label":"Verbose hints","value":false,"disabled":true}'
        in out, out)

    failures.check(
        "Menu", "the store holds every declared value after the run",
        menu_store.read_text(encoding="utf-8")
        == "strictMode=true\nverboseHints=false\nextraPanel=false\n",
        menu_store.read_text(encoding="utf-8"))
    out = run_menu_verbs(['{"do":"quit"}'],
                         ("--menu-store", str(menu_store), "--activate"))
    failures.check(
        "Menu", "persisted values survive into the next session",
        'menufx eval keys=[\\"strictMode\\",\\"verboseHints\\",\\"extraPanel\\"]'
        " strict=true verbose=false extra=false undeclared=undefined" in out,
        out)

    out = run_menu_verbs([
        '{"do":"activate"}',
        '{"do":"menu"}',
        '{"do":"quit"}',
    ], ("--settings", '{"hideExtras":true}'))
    failures.check(
        "Menu", "hiddenWhen via settings drops the item and its divider",
        '{"event":"menu","items":['
        '{"key":"strictMode","label":"Strict matching","value":false,"disabled":false},'
        '{"divider":true},'
        '{"key":"verboseHints","label":"Verbose hints","value":true,"disabled":false}]}'
        in out, out)
    failures.check(
        "Menu", "hidden items still list among the declared keys",
        'keys=[\\"strictMode\\",\\"verboseHints\\",\\"extraPanel\\"]' in out,
        out)

    # Condition grammar: every operator form decides one conditionfixture
    # item's visibility, so the resolved menu is the whole assertion. Only
    # exercised here — the daemon suites cover the equals leaf.
    result = subprocess.run(
        [str(cli), *RUNTIME_ARGS,
         "--settings", '{"shape":{"a":1,"b":2},"list":[1,2,3]}',
         str(FIXTURE_ENGINES / "conditionfixture")],
        input='{"do":"activate"}\n{"do":"menu"}\n{"do":"quit"}\n',
        capture_output=True, text=True, encoding="utf-8", timeout=120)
    out = result.stdout
    visible = []
    disabled = []
    for line in out.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") == "menu":
            visible = [item["key"] for item in event["items"]]
            disabled = [item["key"] for item in event["items"]
                        if item["disabled"]]
    failures.check(
        "Condition", "every declared item is a key regardless of visibility",
        'condfx eval keys=[\\"base\\",\\"missingNotEquals\\",'
        '\\"missingEqualsNull\\",\\"inList\\",\\"notInList\\",'
        '\\"anyOfHidden\\",\\"allOfShown\\",\\"notShown\\",'
        '\\"implicitAllOf\\",\\"deepObject\\",\\"deepArray\\",'
        '\\"disabledByDeep\\"]' in out, out)
    # notEquals/equals-null against an absent key exercise the missing-key
    # -> null rule; in/notIn, anyOf/allOf/not and the bare-array implicit
    # allOf each gate one item; the deep pair compares an object with its
    # keys in the other order and an array element-wise.
    failures.check(
        "Condition", "each operator form resolves to the expected visibility",
        visible == ["base", "notInList", "allOfShown", "notShown",
                    "disabledByDeep"], f"{visible}\n{out}")
    failures.check(
        "Condition", "disabledWhen marks without hiding",
        disabled == ["disabledByDeep"], f"{disabled}\n{out}")

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
        [str(cli), *RUNTIME_ARGS,
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
