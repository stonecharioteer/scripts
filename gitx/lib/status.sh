#!/usr/bin/env bash
#
# status.sh - Compact working tree, upstream, and default-branch summary

set -euo pipefail

show_status_help() {
    cat << EOF
Usage: gitx status [OPTIONS]

Compact repository summary: current branch, upstream divergence, position
relative to the default branch, working tree state, stashes, and last commit.

Unlike 'git status', this answers "where am I relative to everything else"
in a handful of lines.

OPTIONS:
    -h, --help          Show this help message
    -f, --fetch         Fetch from the remote first so counts are current

EXAMPLES:
    gitx status
    gitx status --fetch
EOF
}

cmd_status() {
    local do_fetch=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_status_help
                return 0
                ;;
            -f | --fetch)
                do_fetch=true
                shift
                ;;
            *)
                error "unknown option for 'status': $1"
                ;;
        esac
    done

    require_repo

    local remote branch default toplevel
    remote="$(gitx_remote)"
    branch="$(gitx_current_branch)"
    toplevel="$(git rev-parse --show-toplevel)"

    if [[ "$do_fetch" == "true" ]]; then
        if [[ -z "$remote" ]]; then
            warn "no remote configured; skipping fetch"
        else
            gitx_spin "Fetching $remote..." git fetch --quiet --prune "$remote" \
                || warn "fetch from '$remote' failed"
        fi
    fi

    field "Repository" "$(basename "$toplevel") $DIM($toplevel)$NC"
    field "Branch" "${BOLD}$(gitx_head_label)${NC}"

    # Upstream divergence
    local upstream
    if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
        local counts ahead behind detail
        counts="$(gitx_ahead_behind "$upstream" HEAD)"
        ahead="${counts% *}"
        behind="${counts#* }"

        if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
            detail="${GREEN}in sync${NC}"
        else
            detail="${YELLOW}ahead $ahead, behind $behind${NC}"
        fi
        field "Upstream" "$upstream $detail"
    else
        field "Upstream" "${DIM}none (unpublished branch)${NC}"
    fi

    # Position relative to the default branch
    if default=$(gitx_default_branch "$remote"); then
        local base counts ahead behind detail
        base="$(gitx_tracking_ref "$default" "$remote")"
        field "Default" "$default $DIM(tracking $base)$NC"

        if [[ "$branch" == "$default" ]]; then
            field "Position" "${DIM}on the default branch${NC}"
        else
            counts="$(gitx_ahead_behind "$base" HEAD)"
            ahead="${counts% *}"
            behind="${counts#* }"
            detail="ahead $ahead, behind $behind vs $base"
            if [[ "$behind" != "0" ]]; then
                detail="$detail ${YELLOW}(rebase or merge to catch up)${NC}"
            fi
            field "Position" "$detail"
        fi
    else
        field "Default" "${DIM}unknown${NC}"
    fi

    # Working tree
    local counts staged unstaged untracked
    counts="$(gitx_worktree_counts)"
    staged="$(printf '%s' "$counts" | cut -d' ' -f1)"
    unstaged="$(printf '%s' "$counts" | cut -d' ' -f2)"
    untracked="$(printf '%s' "$counts" | cut -d' ' -f3)"

    if [[ "$staged" == "0" && "$unstaged" == "0" && "$untracked" == "0" ]]; then
        field "Worktree" "${GREEN}clean${NC}"
    else
        field "Worktree" "$(printf '%s%d staged%s, %s%d unstaged%s, %s%d untracked%s' \
            "$GREEN" "$staged" "$NC" "$YELLOW" "$unstaged" "$NC" "$DIM" "$untracked" "$NC")"
    fi

    # Stashes
    local stashes
    stashes=$(git stash list | wc -l | tr -d '[:space:]')
    if [[ "$stashes" == "0" ]]; then
        field "Stashes" "${DIM}none${NC}"
    else
        field "Stashes" "$stashes"
    fi

    # Last commit
    if git rev-parse --verify --quiet HEAD >/dev/null; then
        field "Last commit" "$(git log -1 --format='%C(auto)%h%C(reset) %s %C(dim)(%cr)%C(reset)')"
    else
        field "Last commit" "${DIM}no commits yet${NC}"
    fi
}
