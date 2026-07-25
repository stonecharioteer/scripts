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

Use --vs to also compare against another branch, which is what you want when
the default branch is not the branch you deploy from. Repeat it for more, or
set GITX_STATUS_COMPARE once per repo.

OPTIONS:
    -h, --help          Show this help message
    -f, --fetch         Fetch from the remote first so counts are current
        --vs REF        Also report ahead/behind against REF (repeatable)

ENVIRONMENT:
    GITX_STATUS_COMPARE Default --vs refs, comma or space separated

EXAMPLES:
    gitx status
    gitx status --fetch
    gitx status --vs main               # e.g. development is default, main deploys
    gitx status --vs main --vs staging
    GITX_STATUS_COMPARE=main gitx status
EOF
}

cmd_status() {
    local do_fetch=false
    local -a compare_refs=()

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
            --vs | --against)
                [[ $# -ge 2 ]] || error "--vs requires a ref"
                compare_refs+=("$2")
                shift 2
                ;;
            *)
                error "unknown option for 'status': $1"
                ;;
        esac
    done

    if [[ ${#compare_refs[@]} -eq 0 && -n "${GITX_STATUS_COMPARE:-}" ]]; then
        read -r -a compare_refs <<< "${GITX_STATUS_COMPARE//,/ }"
    fi

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

    # Extra comparisons, for repos where the deploy branch is not the default
    local compare_ref resolved counts ahead behind detail
    for compare_ref in "${compare_refs[@]+"${compare_refs[@]}"}"; do
        resolved="$(gitx_tracking_ref "$compare_ref" "$remote")"
        if ! git rev-parse --verify --quiet "$resolved^{commit}" > /dev/null; then
            field "Compare" "${YELLOW}$compare_ref not found${NC}"
            continue
        fi
        counts="$(gitx_ahead_behind "$resolved" HEAD)"
        ahead="${counts% *}"
        behind="${counts#* }"
        detail="ahead $ahead, behind $behind vs $resolved"
        if [[ "$ahead" == "0" ]]; then
            detail="$detail ${DIM}(fully contained)${NC}"
        fi
        field "Compare" "$detail"
    done

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
