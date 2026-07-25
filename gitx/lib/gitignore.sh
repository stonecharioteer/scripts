#!/usr/bin/env bash
#
# gitignore.sh - Delegate to gi-select.sh for interactive .gitignore assembly

set -euo pipefail

show_gitignore_help() {
    cat << EOF
Usage: gitx gitignore

Append one or more of GitHub's gitignore templates to the .gitignore in the
current directory, chosen interactively with gum.

Templates come from a local clone of github/gitignore at
~/code/tools/gitignore, which is created on first use. Requires 'gum'.

EXAMPLES:
    gitx gitignore
    gitx gi
EOF
}

cmd_gitignore() {
    local wrapper="$GITX_ROOT/gi-select.sh"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help | --gitx-help)
                show_gitignore_help
                return 0
                ;;
            *)
                error "unknown option for 'gitignore': $1"
                ;;
        esac
    done

    [[ -x "$wrapper" ]] || error "gi-select.sh not found or not executable at $wrapper"

    exec "$wrapper"
}
