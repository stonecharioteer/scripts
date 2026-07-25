#!/usr/bin/env bash
#
# pr.sh - Delegate to check-pr.sh for GitHub PR merge status

set -euo pipefail

show_pr_help() {
    cat << EOF
Usage: gitx pr [CHECK_PR_OPTIONS] [DIRECTORY]

Show the merge status of the pull request for the current branch: color-coded
blockers, check runs, reviews, and bot activity.

This delegates to check-pr.sh, so every option it accepts works here. Run
'gitx pr --help' for the full list, which currently includes:

    -w, --watch         Refresh every 30 seconds
        --concise       Show only the summary and items needing attention
    -C, --directory DIR Repository directory (defaults to the current one)

EXAMPLES:
    gitx pr
    gitx pr --concise
    gitx pr -w
    gitx pr ~/code/checkouts/personal/scripts
EOF
}

cmd_pr() {
    local wrapper="$GITX_ROOT/check-pr.sh"

    [[ -x "$wrapper" ]] || error "check-pr.sh not found or not executable at $wrapper"

    # check-pr.sh has its own help, so only intercept the bare 'gitx help pr' path
    if [[ "${1:-}" == "--gitx-help" ]]; then
        show_pr_help
        return 0
    fi

    exec "$wrapper" "$@"
}
