#!/usr/bin/env python3
"""Manage the external resources pinned in external-resources.lock (see
--help for modes). Python-only so every platform runs the same driver.

State dir (.external-resources/ at REPO_ROOT, gitignored):
  downloads/<sha1-of-url>   Persistent raw downloads, one per unique source URL.
  stamp                     "<output-path><TAB><key-hash>" per produced output.
key-hash keys the skip decision on the INPUT SPEC, never on output bytes (some
processors emit machine-dependent output). For a processor entry it folds in
the processor script's own content hash AND, if a sidecar "<proc>.inputs"
lists dependency globs, the content of every matching file — so editing a
processor or any declared input regenerates its outputs. For a verbatim entry
it is just the URL (which embeds the upstream SHA).

Processors live next to this script and run with this same interpreter as
(input, output, url, [section]).
"""

import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCK = os.environ.get("LOCK") or os.path.join(SCRIPT_DIR, "external-resources.lock")
REPO_ROOT = os.environ.get("REPO_ROOT") or os.path.dirname(SCRIPT_DIR)
# Persistent state lives under REPO_ROOT so tests overriding REPO_ROOT get an
# isolated cache + stamp. Gitignored; survives across runs.
RESOURCE_STATE_DIR = os.environ.get("RESOURCE_STATE_DIR") or os.path.join(
    REPO_ROOT, ".external-resources")
DOWNLOADS_DIR = os.path.join(RESOURCE_STATE_DIR, "downloads")
STAMP = os.environ.get("STAMP") or os.path.join(RESOURCE_STATE_DIR, "stamp")

HELP = f"""Usage: {os.path.basename(sys.argv[0])} <command>

Commands:
  --check       Verify every output listed in lock exists on disk and is
                current per the stamp. Exit 0 if all fresh; exit 1 if any is
                missing or out of date.
                (This is what the Xcode build phase runs.)
  --prepare     Incrementally download every entry; verbatim copy or invoke its
                processor. Skips outputs already produced from the same source
                URL + processor + processor-version. Offline once prepared.
  --update      For each github.com upstream referenced in lock, query the
                default-branch HEAD and bump the pinned SHA. Then auto-runs
                --prepare to apply.
  --clean       Remove every output listed in lock and the state dir.
  -h, --help    Print this help.

Env overrides (testing):
  LOCK=<path>                 Override the lock file path.
  REPO_ROOT=<path>            Override the root that output paths resolve from.
  RESOURCE_STATE_DIR=<path>   Override the cache + stamp directory.
  STAMP=<path>                Override the stamp file path.
"""


def fail(*lines):
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def sha1_bytes(data):
    return hashlib.sha1(data).hexdigest()


def out_path(out):
    # Lock output paths always use forward slashes; resolve them portably.
    return os.path.join(REPO_ROOT, *out.split("/"))


def read_lock():
    """Lock entries as (out, url, proc, section); comments/blanks dropped.
    Output paths and URLs must be whitespace-free; the lock is whitespace-
    delimited and an absent 4th column yields an empty section."""
    entries = []
    with open(LOCK, encoding="utf-8") as lock:
        for line in lock:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            out, url, proc = fields[0], fields[1], fields[2]
            section = fields[3] if len(fields) > 3 else ""
            entries.append((out, url, proc, section))
    return entries


def proc_version_hash(proc):
    """Content hash of a processor "version": the script itself, plus — if a
    sidecar "<proc>.inputs" lists dependency globs (one per line, relative to
    the scripts dir; blank / #-comment lines ignored) — the sidecar itself and
    the path + content of every matching file, in sorted order for stability.
    So editing the processor OR any declared input changes the hash."""
    hasher = hashlib.sha1()
    with open(os.path.join(SCRIPT_DIR, proc), "rb") as script:
        hasher.update(script.read())
    inputs = os.path.join(SCRIPT_DIR, proc + ".inputs")
    if os.path.isfile(inputs):
        with open(inputs, "rb") as sidecar:
            hasher.update(sidecar.read())
        deps = set()
        with open(inputs, encoding="utf-8") as sidecar:
            for pattern in sidecar:
                pattern = pattern.strip()
                if not pattern or pattern.startswith("#"):
                    continue
                for dep in glob.glob(os.path.join(SCRIPT_DIR, pattern)):
                    if os.path.isfile(dep):
                        deps.add(dep)
        for dep in sorted(deps):
            # Script-dir-relative so the hash is stable across machines.
            rel = os.path.relpath(dep, SCRIPT_DIR).replace(os.sep, "/")
            hasher.update(rel.encode() + b"\n")
            with open(dep, "rb") as content:
                hasher.update(content.read())
    return hasher.hexdigest()


def key_hash(url, proc, section):
    """Per-entry key-hash. The skip decision keys on this, never on output
    bytes. verbatim ("-"): sha1(url) — the URL embeds the upstream SHA, i.e.
    its version. processor: sha1(url <US> proc <US> section <US>
    proc_version_hash) — 0x1f can't appear in any field, so it prevents
    boundary collisions; folding in the processor's version hash makes "edit a
    processor or its declared inputs -> regenerate its outputs" automatic."""
    if proc == "-":
        return sha1_bytes(url.encode())
    joined = "\x1f".join([url, proc, section, proc_version_hash(proc)])
    return sha1_bytes(joined.encode())


def read_stamp():
    recorded = {}
    if os.path.isfile(STAMP):
        with open(STAMP, encoding="utf-8") as stamp:
            for line in stamp:
                path, _, value = line.rstrip("\n").partition("\t")
                if value:
                    recorded[path] = value
    return recorded


def write_atomically(path, write_payload):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        write_payload(tmp)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def prune_downloads(entries):
    """Delete cached downloads whose URL is no longer referenced by the lock,
    plus any leftover partial *.tmp* files."""
    if not os.path.isdir(DOWNLOADS_DIR):
        return
    valid = {sha1_bytes(url.encode()) for _, url, _, _ in entries}
    for name in os.listdir(DOWNLOADS_DIR):
        if ".tmp" in name or name not in valid:
            os.remove(os.path.join(DOWNLOADS_DIR, name))


def mode_check(entries):
    stale = False
    recorded = read_stamp()
    for out, url, proc, section in entries:
        if not os.path.isfile(out_path(out)):
            reason = "missing"
        elif recorded.get(out) != key_hash(url, proc, section):
            reason = "out of date"
        else:
            continue
        if not stale:
            print("✗ External resources are missing or out of date:",
                  file=sys.stderr)
            stale = True
        print(f"    {out} ({reason})", file=sys.stderr)
    if stale:
        print("  Run `make prepare` to sync them.", file=sys.stderr)
        sys.exit(1)


def mode_prepare(entries):
    os.makedirs(DOWNLOADS_DIR, exist_ok=True)

    # Early validation: every referenced processor must exist.
    for _, _, proc, _ in entries:
        if proc != "-" and not os.path.isfile(os.path.join(SCRIPT_DIR, proc)):
            fail(f"✗ Processor not found: scripts/{proc}")

    recorded = read_stamp()
    new_stamp = []
    for out, url, proc, section in entries:
        kh = key_hash(url, proc, section)
        # Skip when the output is present AND was produced from this exact key.
        if os.path.isfile(out_path(out)) and recorded.get(out) == kh:
            print(f"  = {out}", flush=True)
            new_stamp.append((out, kh))
            continue

        os.makedirs(os.path.dirname(out_path(out)), exist_ok=True)
        cached = os.path.join(DOWNLOADS_DIR, sha1_bytes(url.encode()))
        if os.path.isfile(cached):
            print(f"  ↺ {out}", flush=True)
        else:
            print(f"  ↓ {out}", flush=True)
            try:
                def download(tmp):
                    with urllib.request.urlopen(url, timeout=60) as response, \
                            open(tmp, "wb") as sink:
                        shutil.copyfileobj(response, sink)
                write_atomically(cached, download)
            except (urllib.error.URLError, OSError):
                fail(f"✗ Failed to download {url}",
                     "  Check your network connection and retry"
                     " `make prepare`.")
        if proc == "-":
            write_atomically(out_path(out),
                             lambda tmp: shutil.copyfile(cached, tmp))
        else:
            # A 4th lock column passes an extra argument to the processor
            # (e.g. which section of a multi-section source to extract).
            argv = [sys.executable, os.path.join(SCRIPT_DIR, proc),
                    cached, out_path(out), url]
            if section:
                argv.append(section)
            if subprocess.run(argv).returncode != 0:
                fail(f"✗ Processor failed: scripts/{proc} (for {out})")
        new_stamp.append((out, kh))

    # Install the new stamp atomically (only current-lock entries), then drop
    # cached downloads no longer referenced by the lock.
    def dump_stamp(tmp):
        with open(tmp, "w", encoding="utf-8") as stamp:
            for out, kh in new_stamp:
                stamp.write(f"{out}\t{kh}\n")
    write_atomically(STAMP, dump_stamp)
    prune_downloads(entries)
    print("✓ External resources ready")


def mode_update(entries):
    with open(LOCK, encoding="utf-8") as lock:
        before = lock.read()

    # Unique <owner>/<repo> from raw.githubusercontent.com URLs. Other forge
    # hosts (gitlab, bitbucket, ...) aren't supported yet — they don't appear
    # in this pattern and silently get skipped.
    upstreams = sorted({
        match.group(1)
        for _, url, _, _ in entries
        for match in [re.match(
            r"https://raw\.githubusercontent\.com/([^/]+/[^/]+)/", url)]
        if match})
    if not upstreams:
        print("No github.com upstreams found in lock; nothing to update.",
              file=sys.stderr)
        return

    text = before
    for ownerrepo in upstreams:
        probe = subprocess.run(
            ["git", "ls-remote", f"https://github.com/{ownerrepo}", "HEAD"],
            capture_output=True, text=True)
        new_sha = probe.stdout.split()[0] if probe.stdout.split() else ""
        if probe.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", new_sha):
            fail(f"✗ Failed to resolve HEAD of {ownerrepo}",
                 "  (Network issue, or repo no longer exists?)")
        old = re.search(rf"{re.escape(ownerrepo)}/([0-9a-f]{{40}})", text)
        if old and old.group(1) == new_sha:
            print(f"  ✓ {ownerrepo}: already at {new_sha}")
        else:
            print(f"  ↑ {ownerrepo}: {old.group(1) if old else '?'} → {new_sha}")
            text = re.sub(rf"{re.escape(ownerrepo)}/[0-9a-f]{{40}}",
                          f"{ownerrepo}/{new_sha}", text)

    if text == before:
        print("✓ Lock already up to date")
        return

    def dump_lock(tmp):
        with open(tmp, "w", encoding="utf-8") as lock:
            lock.write(text)
    write_atomically(LOCK, dump_lock)
    print("\n→ Running --prepare to apply updates...")
    mode_prepare(read_lock())


def mode_clean(entries):
    parents = set()
    for out, _, _, _ in entries:
        full = out_path(out)
        if os.path.isfile(full):
            os.remove(full)
        parent = os.path.dirname(full)
        if os.path.abspath(parent) != os.path.abspath(REPO_ROOT):
            parents.add(parent)
    # rmdir each unique parent — succeeds only on empty dirs, so unrelated
    # files (e.g. random.txt a user dropped in there) are preserved.
    for parent in sorted(parents):
        try:
            os.rmdir(parent)
        except OSError:
            pass
    # Wipe the cache + stamp so the next --prepare re-downloads/regenerates.
    if RESOURCE_STATE_DIR:
        shutil.rmtree(RESOURCE_STATE_DIR, ignore_errors=True)
    print("✓ External resources cleaned")


def main():
    # Keep the ✓/✗/arrow output printable on consoles that default to a
    # non-UTF-8 encoding (Windows).
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in ("-h", "--help", "help", ""):
        print(HELP, end="")
        return
    if mode not in ("--check", "check", "--prepare", "--update", "--clean"):
        print(f"Unknown command: {mode}\n", file=sys.stderr)
        print(HELP, end="", file=sys.stderr)
        sys.exit(2)

    if not os.path.isfile(LOCK):
        fail(f"✗ Lock file not found: {LOCK}")
    entries = read_lock()
    if mode in ("--check", "check"):
        mode_check(entries)
    elif mode == "--prepare":
        mode_prepare(entries)
    elif mode == "--update":
        mode_update(entries)
    else:
        mode_clean(entries)


if __name__ == "__main__":
    main()
