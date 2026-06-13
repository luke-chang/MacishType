#!/bin/sh
# HandleExternalResources.sh — manage external resources pinned in HandleExternalResources.lock.
#
# Modes:
#   --check    Verify every output listed in lock exists on disk (default; used by Xcode).
#   --prepare  Incrementally download every entry; skip ones already produced
#              from the same source URL + processor + processor-version, otherwise
#              verbatim copy or invoke the processor. Offline-capable once a prior
#              prepare has populated the state dir.
#   --update   Bump each upstream (github.com only) to its current default-branch HEAD
#              by sed-replacing the SHA in lock, then auto-runs --prepare.
#   --clean    Remove every output listed in lock and the state dir; rmdir parent
#              dirs only if empty.
#
# State dir (.HandleExternalResources/ at REPO_ROOT, gitignored):
#   downloads/<sha1-of-url>   Persistent raw downloads, one per unique source URL.
#   stamp                     "<output-path><TAB><key-hash>" per produced output.
# key-hash keys the skip decision on the INPUT SPEC, never on output bytes (some
# processors emit machine-dependent output). For a processor entry it folds in the
# processor script's own content hash, so editing a processor regenerates its
# outputs; for a verbatim entry it is just the URL (which embeds the upstream SHA).
#
# Env overrides (testing):
#   LOCK                 Path to lock file (default: $SCRIPT_DIR/HandleExternalResources.lock)
#   REPO_ROOT            Root that output paths resolve from (default: $SCRIPT_DIR/..)
#   RESOURCE_STATE_DIR   State dir (default: $REPO_ROOT/.HandleExternalResources)
#   STAMP                Stamp file (default: $RESOURCE_STATE_DIR/stamp)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK="${LOCK:-$SCRIPT_DIR/HandleExternalResources.lock}"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR/..}"

# Persistent state lives under REPO_ROOT so tests overriding REPO_ROOT get an
# isolated cache + stamp. Gitignored; survives across runs (do NOT put in trap).
RESOURCE_STATE_DIR="${RESOURCE_STATE_DIR:-$REPO_ROOT/.HandleExternalResources}"
DOWNLOADS_DIR="$RESOURCE_STATE_DIR/downloads"
STAMP="${STAMP:-$RESOURCE_STATE_DIR/stamp}"

if ! test -f "$LOCK"; then
    echo "✗ Lock file not found: $LOCK" >&2
    exit 1
fi

filtered=$(mktemp)
parents_file=$(mktemp)
upstreams_file=$(mktemp)
lock_before=$(mktemp)
# stamp_tmp accumulates the next stamp so it can be installed atomically.
stamp_tmp=$(mktemp)
trap 'rm -f "$filtered" "$parents_file" "$upstreams_file" "$lock_before" "$stamp_tmp"' EXIT

print_help() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  --check       Verify every output listed in lock exists on disk.
                Exit 0 if all present; exit 1 with reminder if any missing.
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
EOF
}

# sha1 of stdin -> bare hex (drop shasum's trailing filename column).
sha1_stdin() {
    shasum | cut -d' ' -f1
}

# sha1 of a file's content -> bare hex.
sha1_file() {
    shasum "$1" | cut -d' ' -f1
}

# Per-entry key-hash. The skip decision keys on this, never on output bytes.
#   verbatim ("-"): sha1(url) — url embeds the upstream SHA, i.e. its version.
#   processor:      sha1(url <US> proc <US> section <US> sha1(processor script)).
# The 0x1f Unit Separator can't appear in a URL, filename, or section token, so
# it prevents field-boundary collisions; folding in the processor's content hash
# makes "edit a processor -> regenerate its outputs" automatic.
key_hash() {
    if [ "$2" = "-" ]; then
        printf '%s' "$1" | sha1_stdin
    else
        proc_hash=$(sha1_file "$SCRIPT_DIR/$2")
        printf '%s\037%s\037%s\037%s' "$1" "$2" "$3" "$proc_hash" | sha1_stdin
    fi
}

# Print the stored key-hash for an exact output path, or return 1 if absent.
# Compares the whole tab-delimited path field by equality (no regex/prefix match,
# so paths sharing a prefix like Array30 vs ArraySymbol never collide).
stamp_lookup() {
    [ -f "$STAMP" ] || return 1
    while IFS="$(printf '\t')" read -r stamped_path stamped_hash; do
        if [ "$stamped_path" = "$1" ]; then
            printf '%s' "$stamped_hash"
            return 0
        fi
    done < "$STAMP"
    return 1
}

# Delete cached downloads whose URL is no longer referenced by the lock, plus any
# leftover partial *.tmp* files. Keeps the cache from growing across SHA bumps.
prune_downloads() {
    [ -d "$DOWNLOADS_DIR" ] || return 0
    valid=$(mktemp)
    while read -r _out url _proc _section; do
        printf '%s' "$url" | sha1_stdin
    done < "$filtered" | sort -u > "$valid"
    for cached in "$DOWNLOADS_DIR"/*; do
        [ -e "$cached" ] || continue
        base=$(basename "$cached")
        case "$base" in
            *.tmp*) rm -f "$cached"; continue ;;
        esac
        if ! grep -qx "$base" "$valid"; then
            rm -f "$cached"
        fi
    done
    rm -f "$valid"
}

# Strip comments and blank lines once; subsequent loops read from this filtered file
# (avoids the `while read | pipe` subshell variable-loss trap).
grep -v '^[[:space:]]*#' "$LOCK" | grep -v '^[[:space:]]*$' > "$filtered"

mode="${1:-}"

case "$mode" in
    -h|--help|help|"")
        print_help
        exit 0
        ;;

    --check|check)
        missing=0
        while read -r out _url _proc _section; do
            if ! test -f "$REPO_ROOT/$out"; then
                if [ "$missing" -eq 0 ]; then
                    echo "✗ External resources are missing:" >&2
                    missing=1
                fi
                echo "    $REPO_ROOT/$out" >&2
            fi
        done < "$filtered"
        if [ "$missing" -eq 1 ]; then
            echo "  Run \`make prepare\` to download them." >&2
            exit 1
        fi
        ;;

    --prepare)
        mkdir -p "$DOWNLOADS_DIR"
        : > "$stamp_tmp"
        touch "$STAMP"

        # Early validation: every referenced processor must exist and be executable.
        while read -r _out _url proc _section; do
            [ "$proc" = "-" ] && continue
            if ! test -x "$SCRIPT_DIR/$proc"; then
                echo "✗ Processor not executable: Scripts/$proc" >&2
                echo "  Did you forget chmod +x?" >&2
                exit 1
            fi
        done < "$filtered"

        # Output paths and URLs must be whitespace-free; the lock is whitespace-
        # delimited and an absent 4th column yields an empty section.
        while read -r out url proc section; do
            out_full="$REPO_ROOT/$out"
            kh=$(key_hash "$url" "$proc" "$section")

            # Skip when the output is present AND was produced from this exact
            # key. Must be `if`, not a bare `&&` chain: under `set -e` only the
            # non-final commands of an AND-OR list are exempt, so a failing final
            # comparison (the common "processor changed -> hash differs" path)
            # would abort the script instead of falling through to regenerate.
            # An `if` condition list is exempt in full.
            if [ -f "$out_full" ] && recorded=$(stamp_lookup "$out") && [ "$recorded" = "$kh" ]; then
                echo "  = $out"
                printf '%s\t%s\n' "$out" "$kh" >> "$stamp_tmp"
                continue
            fi

            mkdir -p "$(dirname "$out_full")"
            # One persistent cached download per unique URL, keyed by a hash of it.
            url_hash=$(printf '%s' "$url" | sha1_stdin)
            cached="$DOWNLOADS_DIR/$url_hash"
            if [ -f "$cached" ]; then
                echo "  ↺ $out"
            else
                echo "  ↓ $out"
                # $$-suffixed tmp keeps concurrent runs from clobbering each other.
                if ! curl -fsSL "$url" -o "$cached.tmp.$$"; then
                    rm -f "$cached.tmp.$$"
                    echo "✗ Failed to download $url" >&2
                    echo "  Check your network connection and retry \`make prepare\`." >&2
                    exit 1
                fi
                mv "$cached.tmp.$$" "$cached"
            fi
            if [ "$proc" = "-" ]; then
                # Tempfile next to target → same-fs atomic rename even when the
                # repo lives on an external volume, disk image, or network mount.
                tmp_out="$out_full.download.$$"
                cp "$cached" "$tmp_out"
                mv "$tmp_out" "$out_full"
            elif [ -n "$section" ]; then
                # A 4th lock column passes an extra argument to the processor
                # (e.g. which section of a multi-section source to extract).
                "$SCRIPT_DIR/$proc" "$cached" "$out_full" "$url" "$section"
            else
                "$SCRIPT_DIR/$proc" "$cached" "$out_full" "$url"
            fi
            printf '%s\t%s\n' "$out" "$kh" >> "$stamp_tmp"
        done < "$filtered"

        # Install the new stamp atomically (only current-lock entries), then drop
        # cached downloads no longer referenced by the lock.
        mv "$stamp_tmp" "$STAMP"
        prune_downloads
        echo "✓ External resources ready"
        ;;

    --update)
        cp "$LOCK" "$lock_before"

        # Extract unique <owner>/<repo> from raw.githubusercontent.com URLs.
        # Other forge hosts (gitlab, bitbucket, ...) aren't supported yet—they
        # don't appear in this pattern and silently get skipped.
        sed -nE 's|.*raw\.githubusercontent\.com/([^/]+/[^/]+)/.*|\1|p' "$filtered" \
            | sort -u > "$upstreams_file"

        if ! [ -s "$upstreams_file" ]; then
            echo "No github.com upstreams found in lock; nothing to update." >&2
            exit 0
        fi

        while read -r ownerrepo; do
            new_sha=$(git ls-remote "https://github.com/$ownerrepo" HEAD 2>/dev/null | head -1 | cut -f1)
            if [ -z "$new_sha" ]; then
                echo "✗ Failed to resolve HEAD of $ownerrepo" >&2
                echo "  (Network issue, or repo no longer exists?)" >&2
                exit 1
            fi
            # Any current SHA pinned for this owner/repo (could be multiple
            # entries; we display one as the "from" — sed replaces all).
            old_sha=$(grep -oE "$ownerrepo/[0-9a-f]{40}" "$LOCK" | head -1 | sed "s|$ownerrepo/||")
            if [ "$old_sha" = "$new_sha" ]; then
                echo "  ✓ $ownerrepo: already at $new_sha"
            else
                echo "  ↑ $ownerrepo: $old_sha → $new_sha"
                sed -i.bak "s|$ownerrepo/[0-9a-f]\\{40\\}|$ownerrepo/$new_sha|g" "$LOCK"
                rm "$LOCK.bak"
            fi
        done < "$upstreams_file"

        if cmp -s "$lock_before" "$LOCK"; then
            echo "✓ Lock already up to date"
        else
            echo ""
            echo "→ Running --prepare to apply updates..."
            "$0" --prepare
        fi
        ;;

    --clean)
        while read -r out _url _proc _section; do
            rm -f "$REPO_ROOT/$out"
            parent=$(dirname "$REPO_ROOT/$out")
            if [ "$parent" != "$REPO_ROOT" ]; then
                echo "$parent" >> "$parents_file"
            fi
        done < "$filtered"
        # rmdir each unique parent — succeeds only on empty dirs, so unrelated
        # files (e.g. random.txt a user dropped in there) are preserved.
        sort -u "$parents_file" | while read -r d; do
            rmdir "$d" 2>/dev/null || true
        done
        # Wipe the cache + stamp so the next --prepare re-downloads/regenerates
        # everything. Guard against an explicitly-empty override.
        [ -n "$RESOURCE_STATE_DIR" ] && rm -rf "$RESOURCE_STATE_DIR"
        echo "✓ External resources cleaned"
        ;;

    *)
        echo "Unknown command: $mode" >&2
        echo "" >&2
        print_help >&2
        exit 2
        ;;
esac
