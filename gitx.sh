#!/usr/bin/env bash
#
# gitx.sh - Git and GitHub workflow helpers behind one dispatcher
# Wraps check-pr.sh and gi-select.sh alongside branch, sync, cleanup, status,
# and changed-file subcommands.

set -euo pipefail

GITX_VERSION="1.0.0"
GITX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITX_LIB_DIR="$GITX_ROOT/gitx/lib"

# shellcheck source=gitx/lib/common.sh
source "$GITX_LIB_DIR/common.sh"
# shellcheck source=gitx/lib/status.sh
source "$GITX_LIB_DIR/status.sh"
# shellcheck source=gitx/lib/changed.sh
source "$GITX_LIB_DIR/changed.sh"
# shellcheck source=gitx/lib/sync.sh
source "$GITX_LIB_DIR/sync.sh"
# shellcheck source=gitx/lib/cleanup.sh
source "$GITX_LIB_DIR/cleanup.sh"
# shellcheck source=gitx/lib/branch.sh
source "$GITX_LIB_DIR/branch.sh"
# shellcheck source=gitx/lib/pr.sh
source "$GITX_LIB_DIR/pr.sh"
# shellcheck source=gitx/lib/gitignore.sh
source "$GITX_LIB_DIR/gitignore.sh"

show_help() {
    cat << EOF
Usage: $(basename "$0") [GLOBAL_OPTIONS] COMMAND [COMMAND_OPTIONS]

Git and GitHub workflow helpers for the everyday feature-branch loop: start a
branch, see what it changed, check the PR, keep up with the default branch, and
clean up afterwards.

COMMANDS:
    status, st          Branch, upstream, default-branch, worktree, and stash summary
    changed, files      Files a branch changed vs the default branch, with +/- counts
    branch, new         Create a TYPE/description branch off an up-to-date default branch
    sync, update        Fetch, fast-forward the default branch, report divergence
    cleanup, tidy       Delete local branches already merged or squash-merged
    pr check            PR merge status, checks, reviews, bots (wraps check-pr.sh)
    pr list             Open PRs with author and destination branch
    gitignore, gi       Append GitHub gitignore templates (wraps gi-select.sh)
    help [COMMAND]      Show help for a command

GLOBAL OPTIONS:
    -h, --help              Show this help message
    -V, --version           Show the gitx version
    -C, --directory DIR     Run as if gitx started in DIR
        --remote NAME       Remote to use (default: origin, else the first remote)
        --default-branch B  Override default branch detection
        --no-color          Disable colored output

ENVIRONMENT:
    GITX_REMOTE             Default remote name
    GITX_DEFAULT_BRANCH     Default branch name, skipping detection
    GITX_PROTECTED_BRANCHES Extra branches cleanup must never delete
    GITX_STATUS_COMPARE     Default --vs refs for status
    NO_COLOR                Disable colored output

EXAMPLES:
    $(basename "$0") status
    $(basename "$0") status --vs main           # also compare against a deploy branch
    $(basename "$0") changed                    # what this branch touches vs main
    $(basename "$0") changed feat/other-work
    $(basename "$0") branch feat add git tools  # -> feat/add-git-tools
    $(basename "$0") sync --rebase
    $(basename "$0") cleanup --apply
    $(basename "$0") pr check --concise
    $(basename "$0") pr list --mine
    $(basename "$0") -C ~/code/other-repo status
EOF
}

cmd_help() {
    case "${1:-}" in
        "")
            show_help
            ;;
        status | st)
            show_status_help
            ;;
        changed | files)
            show_changed_help
            ;;
        branch | new)
            show_branch_help
            ;;
        sync | update)
            show_sync_help
            ;;
        cleanup | tidy)
            show_cleanup_help
            ;;
        pr)
            case "${2:-}" in
                check) show_pr_check_help ;;
                list | ls) show_pr_list_help ;;
                *) show_pr_help ;;
            esac
            ;;
        gitignore | gi)
            show_gitignore_help
            ;;
        *)
            error "no help topic for '$1'; run '$(basename "$0") --help'"
            ;;
    esac
}

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_help
                return 0
                ;;
            -V | --version)
                printf 'gitx %s\n' "$GITX_VERSION"
                return 0
                ;;
            -C | --directory)
                [[ $# -ge 2 ]] || error "-C requires a directory"
                cd "$2" || error "cannot change directory to '$2'"
                shift 2
                ;;
            --remote)
                [[ $# -ge 2 ]] || error "--remote requires a name"
                GITX_REMOTE="$2"
                shift 2
                ;;
            --default-branch)
                [[ $# -ge 2 ]] || error "--default-branch requires a name"
                GITX_DEFAULT_BRANCH="$2"
                shift 2
                ;;
            --no-color)
                NO_COLOR=1
                gitx_init_colors
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "unknown global option: $1 (run '$(basename "$0") --help')"
                ;;
            *)
                command="$1"
                shift
                break
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        show_help
        return 0
    fi

    case "$command" in
        status | st)
            cmd_status "$@"
            ;;
        changed | files)
            cmd_changed "$@"
            ;;
        branch | new)
            cmd_branch "$@"
            ;;
        sync | update)
            cmd_sync "$@"
            ;;
        cleanup | tidy)
            cmd_cleanup "$@"
            ;;
        pr)
            cmd_pr "$@"
            ;;
        gitignore | gi)
            cmd_gitignore "$@"
            ;;
        help)
            cmd_help "$@"
            ;;
        *)
            error "unknown command: $command (run '$(basename "$0") --help')"
            ;;
    esac
}

main "$@"
