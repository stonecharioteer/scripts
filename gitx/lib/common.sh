#!/usr/bin/env bash
#
# common.sh - Shared helpers for gitx: colors, logging, and git repository queries

set -euo pipefail

# Guard against double sourcing
if [[ -n "${GITX_COMMON_SOURCED:-}" ]]; then
    return 0
fi
GITX_COMMON_SOURCED=1

# Colors are initialized once at source time and can be re-initialized after
# global option parsing (for example when --no-color is passed).
gitx_init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[1;33m'
        CYAN=$'\033[0;36m'
        DIM=$'\033[2m'
        BOLD=$'\033[1m'
        NC=$'\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        # shellcheck disable=SC2034  # CYAN is consumed by the sibling lib modules
        CYAN=''
        DIM=''
        BOLD=''
        NC=''
    fi
}

gitx_init_colors

error() {
    printf '%sError:%s %s\n' "$RED" "$NC" "$*" >&2
    exit 1
}

warn() {
    printf '%sWarning:%s %s\n' "$YELLOW" "$NC" "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

success() {
    printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"
}

skipped() {
    printf '%s-%s %s\n' "$DIM" "$NC" "$*"
}

heading() {
    printf '%s%s%s\n' "$BOLD" "$*" "$NC"
}

# Print an aligned "Label  value" row used by status-style output
field() {
    printf '%s%-11s%s %s\n' "$DIM" "$1" "$NC" "$2"
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "'$command_name' is required but not installed"
    fi
}

require_repo() {
    require_command git

    if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
        error "not inside a git working tree (cwd: $PWD)"
    fi
}

# Resolve the remote to work against: GITX_REMOTE, else origin, else the first
# configured remote. Prints an empty string for repositories with no remotes.
gitx_remote() {
    if [[ -n "${GITX_REMOTE:-}" ]]; then
        printf '%s' "$GITX_REMOTE"
        return 0
    fi

    if git remote get-url origin >/dev/null 2>&1; then
        printf 'origin'
        return 0
    fi

    git remote | head -n 1
}

# Resolve the default branch name without hitting the network:
# GITX_DEFAULT_BRANCH, then the remote's HEAD symref, then common names as they
# exist on the remote, then as local branches. Returns 1 when nothing matches.
gitx_default_branch() {
    local remote="${1:-}"
    local ref candidate

    if [[ -n "${GITX_DEFAULT_BRANCH:-}" ]]; then
        printf '%s' "$GITX_DEFAULT_BRANCH"
        return 0
    fi

    if [[ -z "$remote" ]]; then
        remote="$(gitx_remote)"
    fi

    if [[ -n "$remote" ]] && ref=$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null); then
        printf '%s' "${ref#refs/remotes/"$remote"/}"
        return 0
    fi

    if [[ -n "$remote" ]]; then
        for candidate in main master trunk develop; do
            if git show-ref --verify --quiet "refs/remotes/$remote/$candidate"; then
                printf '%s' "$candidate"
                return 0
            fi
        done
    fi

    for candidate in main master trunk develop; do
        if git show-ref --verify --quiet "refs/heads/$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

# Same as gitx_default_branch but exits with actionable advice on failure
gitx_require_default_branch() {
    local default
    if ! default=$(gitx_default_branch "${1:-}"); then
        error "could not determine the default branch; pass --default-branch NAME or set GITX_DEFAULT_BRANCH"
    fi
    printf '%s' "$default"
}

# Prefer the remote-tracking ref for a branch, since it is usually fresher than
# the local copy. Falls back to the local branch name.
gitx_tracking_ref() {
    local branch="$1"
    local remote="${2:-}"

    if [[ -z "$remote" ]]; then
        remote="$(gitx_remote)"
    fi

    if [[ -n "$remote" ]] && git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
        printf '%s/%s' "$remote" "$branch"
        return 0
    fi

    printf '%s' "$branch"
}

# Current branch name, or empty when HEAD is detached
gitx_current_branch() {
    git symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# Human label for HEAD, falling back to a short sha when detached
gitx_head_label() {
    local branch
    branch="$(gitx_current_branch)"

    if [[ -n "$branch" ]]; then
        printf '%s' "$branch"
    else
        printf 'detached at %s' "$(git rev-parse --short HEAD)"
    fi
}

# Prints "<ahead> <behind>" for HEAD-ish $2 relative to base $1
gitx_ahead_behind() {
    git rev-list --left-right --count "$1...$2" 2>/dev/null | awk '{print $2, $1}'
}

# Prints "<staged> <unstaged> <untracked>"
gitx_worktree_counts() {
    local staged unstaged untracked

    staged=$(git diff --cached --name-only | wc -l | tr -d '[:space:]')
    unstaged=$(git diff --name-only | wc -l | tr -d '[:space:]')
    untracked=$(git ls-files --others --exclude-standard | wc -l | tr -d '[:space:]')

    printf '%s %s %s' "$staged" "$unstaged" "$untracked"
}

gitx_is_dirty() {
    [[ -n "$(git status --porcelain --untracked-files=no)" ]]
}

# True when $1 is fully contained in $2
gitx_is_merged() {
    git merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

# Detect squash merges: replay the branch tree as a single commit on top of the
# merge base and ask whether an equivalent patch already exists in the base.
# This is how squash-merged PRs are recognized, since they share no commits.
gitx_is_squash_merged() {
    local branch="$1"
    local base="$2"
    local merge_base tree probe

    merge_base=$(git merge-base "$base" "$branch" 2>/dev/null) || return 1
    tree=$(git rev-parse "$branch^{tree}" 2>/dev/null) || return 1

    # Requires a committer identity; treat a failure as "not squash-merged"
    probe=$(git commit-tree "$tree" -p "$merge_base" -m 'gitx squash-merge probe' 2>/dev/null) || return 1

    [[ "$(git cherry "$base" "$probe" 2>/dev/null)" == "-"* ]]
}

# --- Interactive helpers (gum for prompts, fzf for pickers) -------------------

gitx_has_gum() {
    command -v gum >/dev/null 2>&1
}

gitx_has_fzf() {
    command -v fzf >/dev/null 2>&1
}

gitx_interactive() {
    [[ -t 0 && -t 1 ]]
}

# fzf and gum draw on /dev/tty rather than stdout, so a picker still works with
# stdout piped ('gitx changed -i --name-only | xargs ...'). What they cannot do
# without a controlling terminal is read keys, so that is what we test for.
gitx_has_tty() {
    [[ -c /dev/tty ]] && { true > /dev/tty; } 2>/dev/null
}

# Section title: styled through gum when we have a terminal, plain otherwise
gitx_header() {
    if gitx_has_gum && gitx_interactive; then
        gum style --foreground 212 --bold "$*"
    else
        heading "$*"
    fi
}

# Run a command behind a gum spinner, falling back to a plain progress line.
# Usage: gitx_spin "Fetching origin..." git fetch --prune origin
gitx_spin() {
    local title="$1"
    shift

    if gitx_has_gum && gitx_interactive; then
        gum spin --spinner dot --title "$title" --show-error -- "$@"
    else
        info "$title"
        "$@"
    fi
}

# Confirmation prompt. Honors ASSUME_YES, declines when non-interactive.
gitx_confirm() {
    local prompt="$1"
    local reply

    if [[ "${ASSUME_YES:-false}" == "true" ]]; then
        return 0
    fi

    if ! gitx_interactive; then
        warn "not running interactively; refusing to continue without --yes"
        return 1
    fi

    if gitx_has_gum; then
        gum confirm "$prompt"
        return $?
    fi

    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# Pick one local branch, most recently committed first. fzf previews the
# branch's recent history; gum filter is the fallback. Returns 1 if cancelled
# or if neither tool is installed.
gitx_pick_branch() {
    local prompt="${1:-Select a branch}"
    local branches

    gitx_has_tty || return 1

    branches=$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/)
    [[ -n "$branches" ]] || return 1

    if gitx_has_fzf; then
        printf '%s\n' "$branches" | fzf \
            --prompt="$prompt > " \
            --height=60% \
            --reverse \
            --ansi \
            --select-1 \
            --exit-0 \
            --preview='git log --oneline --graph --decorate --color=always -20 {}' \
            --preview-window='right,60%'
    elif gitx_has_gum; then
        printf '%s\n' "$branches" | gum filter --placeholder "$prompt" --height 15
    else
        return 1
    fi
}

# Pick paths from stdin, previewing each one with PREVIEW_COMMAND ('{}' is the
# path). Selected paths go to stdout. Returns 1 if cancelled or unavailable.
gitx_pick_paths() {
    local prompt="$1"
    local preview_command="$2"

    gitx_has_tty || return 1

    if gitx_has_fzf; then
        fzf --multi \
            --ansi \
            --prompt="$prompt > " \
            --height=90% \
            --reverse \
            --exit-0 \
            --preview="$preview_command" \
            --preview-window='right,65%,wrap' \
            --bind='ctrl-/:toggle-preview'
    elif gitx_has_gum; then
        gum filter --no-limit --placeholder "$prompt" --height 20
    else
        return 1
    fi
}
