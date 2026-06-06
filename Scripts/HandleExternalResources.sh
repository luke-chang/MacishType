#!/bin/sh
# HandleExternalResources.sh — manage external resources pinned in HandleExternalResources.lock.
#
# Modes:
#   --check    Verify every output listed in lock exists on disk (default; used by Xcode).
#   --prepare  Unconditionally download every entry; verbatim copy or invoke its processor.
#   --update   Bump each upstream (github.com only) to its current default-branch HEAD
#              by sed-replacing the SHA in lock, then auto-runs --prepare.
#   --clean    Remove every output listed in lock; rmdir parent dirs only if empty.
#
# Env overrides (testing):
#   LOCK           Path to lock file (default: $SCRIPT_DIR/HandleExternalResources.lock)
#   REPO_ROOT      Root that output paths resolve from (default: $SCRIPT_DIR/..)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK="${LOCK:-$SCRIPT_DIR/HandleExternalResources.lock}"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR/..}"

if ! test -f "$LOCK"; then
    echo "✗ Lock file not found: $LOCK" >&2
    exit 1
fi

filtered=$(mktemp)
parents_file=$(mktemp)
upstreams_file=$(mktemp)
lock_before=$(mktemp)
# Cache directory holds one download per unique source URL within a run, so
# multiple outputs derived from the same upstream are fetched only once.
download_cache=$(mktemp -d)
trap 'rm -rf "$filtered" "$parents_file" "$upstreams_file" "$lock_before" "$download_cache"' EXIT

print_help() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  --check       Verify every output listed in lock exists on disk.
                Exit 0 if all present; exit 1 with reminder if any missing.
                (This is what the Xcode build phase runs.)
  --prepare     Download every entry; verbatim copy or invoke its processor.
                Overwrites existing outputs unconditionally.
  --update      For each github.com upstream referenced in lock, query the
                default-branch HEAD and bump the pinned SHA. Then auto-runs
                --prepare to apply.
  --clean       Remove every output listed in lock.
  -h, --help    Print this help.

Env overrides (testing):
  LOCK=<path>           Override the lock file path.
  REPO_ROOT=<path>      Override the root that output paths resolve from.
EOF
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
        while read -r out _url _proc; do
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
        # Early validation: every referenced processor must exist and be executable.
        while read -r _out _url proc; do
            [ "$proc" = "-" ] && continue
            if ! test -x "$SCRIPT_DIR/$proc"; then
                echo "✗ Processor not executable: Scripts/$proc" >&2
                echo "  Did you forget chmod +x?" >&2
                exit 1
            fi
        done < "$filtered"

        while read -r out url proc; do
            out_full="$REPO_ROOT/$out"
            mkdir -p "$(dirname "$out_full")"
            # One cached download per unique URL, keyed by a hash of the URL.
            url_hash=$(printf '%s' "$url" | shasum | cut -d' ' -f1)
            cached="$download_cache/$url_hash"
            if [ -f "$cached" ]; then
                echo "  ↺ $out"
            else
                echo "  ↓ $out"
                if ! curl -fsSL "$url" -o "$cached.tmp"; then
                    rm -f "$cached.tmp"
                    echo "✗ Failed to download $url" >&2
                    echo "  Check your network connection and retry \`make prepare\`." >&2
                    exit 1
                fi
                mv "$cached.tmp" "$cached"
            fi
            if [ "$proc" = "-" ]; then
                # Tempfile next to target → same-fs atomic rename even when the
                # repo lives on an external volume, disk image, or network mount.
                tmp_out="$out_full.download.$$"
                cp "$cached" "$tmp_out"
                mv "$tmp_out" "$out_full"
            else
                "$SCRIPT_DIR/$proc" "$cached" "$out_full" "$url"
            fi
        done < "$filtered"
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
        while read -r out _url _proc; do
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
        echo "✓ External resources cleaned"
        ;;

    *)
        echo "Unknown command: $mode" >&2
        echo "" >&2
        print_help >&2
        exit 2
        ;;
esac
