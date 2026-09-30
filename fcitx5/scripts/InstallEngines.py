#!/usr/bin/env python3
"""Interactive installer for the repo's engine folders.

Shows what the engine directory fcitx5 reads
($XDG_DATA_HOME/fcitx5/macishtype/engines, ~/.local/share by default) already
holds, lists the engines under <repo>/engines/, and installs the picked ones
as copies or as symlinks. No root needed; an engine keeps its source folder
name, which is its identity to the addon.

An engine that ships a setup.py has it run first, so generated data tables are
in place; re-picking symlink for an engine already linked runs it too, which
is how a link gets updated. The installed listing marks this repo's engines
that are out of date without changing anything: one whose setup.py --check
finds its generated data stale, or a copy that no longer matches its source
folder. _storage/, where the JS storage API persists a user-layer engine's
data, belongs to the installed form: a copy owns its own and keeps it across a
reinstall, while a symlink's lives in the source folder and is never touched
here.

With --uninstall it lists the same directory, engines from elsewhere too, and
removes the picked entries from this layer only: a symlink goes alone, leaving
its source folder, while a copy takes its _storage/ along, which the
confirmation spells out.
"""

import filecmp
import json
import os
import re
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
SOURCE_DIR = os.path.join(REPO_ROOT, "engines")
# Engine identity is the folder name; the addon skips anything else.
ENGINE_ID = re.compile(r"^[A-Za-z0-9_-]+$")
# Engine-private storage, kept across a reinstall.
STORAGE_DIR = "_storage"
# Never travels into a copy: dev leftovers, and the storage directory, which
# is carried over from the existing install instead.
SKIP_PATTERNS = ("__pycache__", ".git*", STORAGE_DIR)


def engines_dir():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    return os.path.join(data_home, "fcitx5", "macishtype", "engines")


def display_name(manifest_path):
    """The manifest's `name`, which is either a string or a locale map."""
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            name = json.load(handle).get("name")
    except (OSError, ValueError):
        return ""
    if isinstance(name, str):
        return name
    if isinstance(name, dict):
        for locale in ("en", *sorted(name)):
            if isinstance(name.get(locale), str):
                return name[locale]
    return ""


def discover():
    """Installable engine folders, in the order they are listed."""
    found = []
    for entry in sorted(os.listdir(SOURCE_DIR)):
        source = os.path.join(SOURCE_DIR, entry)
        manifest = os.path.join(source, "manifest.json")
        if not ENGINE_ID.match(entry) or not os.path.isfile(manifest):
            continue
        found.append({"id": entry, "source": source,
                      "name": display_name(manifest)})
    return found


def setup_is_current(engine):
    """Whether the engine's setup.py --check finds its generated data current;
    an engine without a setup.py has none."""
    if not os.path.isfile(os.path.join(engine["source"], "setup.py")):
        return True
    return subprocess.run([sys.executable, "setup.py", "--check"],
                          cwd=engine["source"],
                          capture_output=True).returncode == 0


def copied_files(root):
    """Relative path -> path of every file a copy of `root` would carry."""
    skip = shutil.ignore_patterns(*SKIP_PATTERNS)
    found = {}
    for directory, subdirectories, files in os.walk(root):
        skipped = skip(directory, subdirectories + files)
        subdirectories[:] = [name for name in subdirectories
                             if name not in skipped]
        for name in files:
            if name not in skipped:
                path = os.path.join(directory, name)
                found[os.path.relpath(path, root)] = path
    return found


def copy_differs(copy, source):
    installed, current = copied_files(copy), copied_files(source)
    return installed.keys() != current.keys() or any(
        not filecmp.cmp(installed[name], current[name], shallow=False)
        for name in current)


def staleness(path, engine):
    """Why the installed `path` of this repo's `engine` is out of date, or ""
    when it is current or not this repo's to judge."""
    if engine is None:
        return ""
    if os.path.islink(path):
        if os.path.realpath(path) != os.path.realpath(engine["source"]):
            return ""
        return "" if setup_is_current(engine) else "data tables outdated"
    if os.path.isdir(path) and (not setup_is_current(engine)
                                or copy_differs(path, engine["source"])):
        return "outdated"
    return ""


def show_installed(destination_root, engines):
    """Everything the destination already serves, engines from elsewhere too."""
    try:
        entries = sorted(os.listdir(destination_root))
    except OSError:
        entries = []
    print(f"Installed in {destination_root}:\n")
    if not entries:
        print("  (nothing yet)\n")
        return
    by_id = {engine["id"]: engine for engine in engines}
    width = max(len(entry) for entry in entries)
    any_outdated = False
    for entry in entries:
        path = os.path.join(destination_root, entry)
        kind = (f"symlink -> {os.path.realpath(path)}"
                if os.path.islink(path) else "copy")
        reason = staleness(path, by_id.get(entry))
        if reason:
            kind += f"  ({reason})"
            any_outdated = True
        print(f"  {entry:<{width}}  {kind}")
    print()
    if any_outdated:
        print("Reinstall an outdated engine below to update it.\n")


def installed_form(engine, destination_root):
    """How this engine itself is installed: "copy", "symlink", or not."""
    target = os.path.join(destination_root, engine["id"])
    if os.path.islink(target):
        return "symlink"
    if os.path.isdir(target):
        return "copy"
    return ""


def prompt_selection(items, heading, verb):
    """Numbered pick from `items`, each shown as its id, name and note."""
    width = max(len(item["id"]) for item in items)
    print(f"{heading}:\n")
    for index, item in enumerate(items, 1):
        columns = [f"  {index}) {item['id']:<{width}}", item["name"],
                   item["note"]]
        print("  ".join(column for column in columns if column))
    print()
    while True:
        answer = input(f'{verb} which? '
                       '(numbers, "all", empty to cancel): ').strip()
        if not answer:
            return []
        if answer.lower() in ("all", "a"):
            return list(items)
        chosen = []
        for token in answer.replace(",", " ").split():
            if not token.isdigit() or not 1 <= int(token) <= len(items):
                print(f'  "{token}" is not one of the numbers above.')
                chosen = None
                break
            item = items[int(token) - 1]
            if item not in chosen:
                chosen.append(item)
        if chosen:
            return chosen


def prompt_mode():
    """Copy (self-contained) or symlink (source edits reach fcitx5 live)."""
    while True:
        answer = input("Install as [c]opy or [s]ymlink? "
                       "(default copy): ").strip().lower()
        if answer in ("", "c", "copy"):
            return "copy"
        if answer in ("s", "symlink", "link"):
            return "symlink"
        print('  Answer "c" or "s".')


def confirm_reinstall(engine, destination_root):
    """Asked before the install form, so declining costs one answer."""
    target = os.path.join(destination_root, engine["id"])
    print(f"  {engine['id']} is already installed as a"
          f" {engine['installed']}:\n  {target}")
    return input("  Reinstall? [y/N] ").strip().lower() in ("y", "yes")


def confirm_storage_loss():
    """A copy owns its storage; the symlink replacing it has nowhere for it."""
    print(f"  Replacing the copy with a symlink discards its {STORAGE_DIR}/,"
          " the engine's own data.")
    return input("  Continue? [y/N] ").strip().lower() in ("y", "yes")


def remove(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def run_setup(engine):
    """Runs the engine's setup.py, if it ships one. Returns whether it
    succeeded."""
    if not os.path.isfile(os.path.join(engine["source"], "setup.py")):
        return True
    print("  running setup.py...", flush=True)
    return subprocess.run([sys.executable, "setup.py"],
                          cwd=engine["source"]).returncode == 0


def install(engine, destination_root, mode):
    """Installs one engine folder. Returns whether it landed."""
    target = os.path.join(destination_root, engine["id"])
    if mode == "symlink":
        if os.path.islink(target) and \
                os.path.realpath(target) == os.path.realpath(engine["source"]):
            # The link serves the source folder, so setup is the whole update.
            if run_setup(engine):
                print("  already links to the source folder")
            else:
                print("  setup.py failed", file=sys.stderr)
            return False
        if not os.path.islink(target) \
                and os.path.isdir(os.path.join(target, STORAGE_DIR)) \
                and not confirm_storage_loss():
            print("  skipped")
            return False
    elif os.path.islink(target):
        print("  replacing the symlink with a copy: later source edits stop"
              " reaching fcitx5")
    if not run_setup(engine):
        print("  setup.py failed; engine not installed", file=sys.stderr)
        return False
    if mode == "symlink":
        remove(target)
        os.symlink(engine["source"], target)
        print(f"  ✓ {target} -> {engine['source']}")
        return True
    # Stage beside the target so nothing is removed until the new tree is
    # complete, then swap it in with a rename.
    staging = os.path.join(destination_root, f".{engine['id']}.new")
    shutil.rmtree(staging, ignore_errors=True)
    try:
        shutil.copytree(engine["source"], staging,
                        ignore=shutil.ignore_patterns(*SKIP_PATTERNS))
        # Only a previous copy's storage is this install's to carry; behind
        # a symlink it belongs to the source folder and stays there.
        storage = os.path.join(target, STORAGE_DIR)
        if not os.path.islink(target) and os.path.isdir(storage):
            shutil.copytree(storage, os.path.join(staging, STORAGE_DIR))
        remove(target)
        os.replace(staging, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(f"  ✓ {target}")
    return True


def installed_entries(destination_root):
    """Everything the destination serves, as items to pick from."""
    try:
        names = sorted(os.listdir(destination_root))
    except OSError:
        names = []
    entries = []
    for name in names:
        path = os.path.join(destination_root, name)
        note = (f"symlink -> {os.path.realpath(path)}"
                if os.path.islink(path) else "copy")
        entries.append({"id": name, "path": path, "note": note,
                        "name": display_name(
                            os.path.join(path, "manifest.json"))})
    return entries


def system_install(engine_id):
    """A system-layer folder that still serves `engine_id`, or None."""
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    for data_dir in data_dirs.split(":"):
        path = os.path.join(data_dir, "fcitx5", "macishtype", "engines",
                            engine_id)
        if data_dir and os.path.isdir(path):
            return path
    return None


def uninstall(destination_root):
    entries = installed_entries(destination_root)
    if not entries:
        print(f"Nothing installed in {destination_root}")
        return
    selected = prompt_selection(entries, f"Installed in {destination_root}",
                                "Uninstall")
    if not selected:
        print("Nothing selected.")
        return
    print("\nThis removes:")
    for entry in selected:
        if os.path.islink(entry["path"]):
            what = "the symlink only; its source folder stays"
        elif os.path.isdir(os.path.join(entry["path"], STORAGE_DIR)):
            what = (f"the copy, with its {STORAGE_DIR}/ (the engine's own"
                    " data)")
        else:
            what = "the copy"
        print(f"  {entry['id']}: {what}")
    if input("Continue? [y/N] ").strip().lower() not in ("y", "yes"):
        print("Nothing removed.")
        return
    gone = False
    for entry in selected:
        remove(entry["path"])
        print(f"  ✓ removed {entry['path']}")
        system = system_install(entry["id"])
        if system:
            print(f"    still served by the system install at {system}")
        else:
            gone = True
    if gone:
        print("\nfcitx5 keeps a removed engine's input method listed until"
              " it restarts.")


def main():
    uninstalling = sys.argv[1:] == ["--uninstall"]
    if sys.argv[1:] and not uninstalling:
        print("Usage: InstallEngines.py [--uninstall]", file=sys.stderr)
        sys.exit(2)
    verb = "uninstall" if uninstalling else "install"
    if not sys.stdin.isatty():
        sys.exit(f"{verb}-engines needs a terminal to ask what to {verb}.")
    destination_root = engines_dir()
    if uninstalling:
        uninstall(destination_root)
        return
    engines = discover()
    if not engines:
        sys.exit(f"No engine folder with a manifest.json in {SOURCE_DIR}")
    os.makedirs(destination_root, exist_ok=True)
    show_installed(destination_root, engines)
    for engine in engines:
        engine["installed"] = installed_form(engine, destination_root)
        engine["note"] = (f"installed ({engine['installed']})"
                          if engine["installed"] else "")
    selected = prompt_selection(engines, f"Engines in {SOURCE_DIR}", "Install")
    if not selected:
        print("Nothing selected.")
        return
    selected = [engine for engine in selected
                if not engine["installed"]
                or confirm_reinstall(engine, destination_root)]
    if not selected:
        print("Nothing to install.")
        return
    mode = prompt_mode()
    installed = 0
    for engine in selected:
        print(f"\n{engine['id']}:")
        if install(engine, destination_root, mode):
            installed += 1
    if installed:
        print("\nNewly added folders are picked up on demand: open"
              " fcitx5-configtool →\nInput Method → Add to select them.")


if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        # Ctrl-C / Ctrl-D at any prompt is always safe: an install removes
        # nothing until its replacement is staged, an uninstall nothing until
        # its last answer.
        sys.exit("\nCancelled.")
