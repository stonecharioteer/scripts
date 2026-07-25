#!/usr/bin/env bash
#
# changed.sh - List files a branch changes relative to the default branch

set -euo pipefail

show_changed_help() {
    cat << EOF
Usage: gitx changed [OPTIONS] [BRANCH]

List the files BRANCH changes relative to the default branch, with per-file
added/removed line counts. Defaults to the current branch.

The comparison uses the merge base, so commits that landed on the default
branch after BRANCH was created are never reported as changes.

OPTIONS:
    -h, --help          Show this help message
    -b, --base REF      Compare against REF instead of the default branch
    -d, --dirty         Include uncommitted working tree changes
    -i, --interactive   Pick the branch with fzf, then browse the changed files
                        with a live diff preview; selected paths go to stdout
        --name-only     Print only paths, one per line (script friendly)
        --stat          Defer to git's own --stat rendering

EXAMPLES:
    gitx changed                        # current branch vs default branch
    gitx changed feat/git-tools         # a specific branch vs default branch
    gitx changed --dirty                # include uncommitted work
    gitx changed --base release/1.2     # compare against another base
    gitx changed -i                     # fzf browser with diff preview
    gitx changed -i --name-only | xargs \$EDITOR
    gitx changed --name-only | xargs shellcheck
EOF
}

cmd_changed() {
    local head_ref=""
    local base_override=""
    local mode="table"
    local include_dirty=false
    local interactive=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_changed_help
                return 0
                ;;
            -b | --base)
                [[ $# -ge 2 ]] || error "--base requires a ref"
                base_override="$2"
                shift 2
                ;;
            -d | --dirty | --worktree)
                include_dirty=true
                shift
                ;;
            -i | --interactive)
                interactive=true
                shift
                ;;
            --name-only)
                mode="names"
                shift
                ;;
            --stat)
                mode="stat"
                shift
                ;;
            -*)
                error "unknown option for 'changed': $1"
                ;;
            *)
                [[ -z "$head_ref" ]] || error "unexpected argument: $1"
                head_ref="$1"
                shift
                ;;
        esac
    done

    require_repo

    # With -i and no explicit branch, choose one with fzf. The current branch
    # sorts near the top, so Enter usually accepts what you wanted anyway.
    if [[ "$interactive" == "true" && -z "$head_ref" && "$include_dirty" == "false" ]] \
        && gitx_has_tty && { gitx_has_fzf || gitx_has_gum; }; then
        local picked
        picked=$(gitx_pick_branch "Compare branch") || error "no branch selected"
        [[ -n "$picked" ]] || error "no branch selected"
        head_ref="$picked"
    fi

    local base
    if [[ -n "$base_override" ]]; then
        base="$base_override"
    else
        local default
        default="$(gitx_require_default_branch)"
        base="$(gitx_tracking_ref "$default")"
    fi

    git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
        || error "base ref '$base' does not exist"

    local head_rev head_label
    if [[ -n "$head_ref" ]]; then
        git rev-parse --verify --quiet "$head_ref^{commit}" >/dev/null \
            || error "ref '$head_ref' does not exist"
        head_rev="$head_ref"
        head_label="$head_ref"
    else
        head_rev="HEAD"
        head_label="$(gitx_head_label)"
    fi

    if [[ "$include_dirty" == "true" && -n "$head_ref" ]]; then
        error "--dirty compares the working tree, so it cannot be combined with a branch argument"
    fi

    local merge_base
    merge_base=$(git merge-base "$base" "$head_rev") \
        || error "'$base' and '$head_label' have no common ancestor"

    local -a diff_args
    if [[ "$include_dirty" == "true" ]]; then
        diff_args=("$merge_base" "--")
    else
        diff_args=("$merge_base" "$head_rev" "--")
    fi

    # Preview command for the fzf browser; refs never contain spaces
    local preview_range="$merge_base"
    [[ "$include_dirty" == "true" ]] || preview_range="$merge_base $head_rev"

    if [[ "$mode" == "names" ]]; then
        if [[ "$interactive" == "true" ]]; then
            git diff --name-only "${diff_args[@]}" \
                | gitx_pick_paths "changed" "git diff --color=always $preview_range -- {}" || true
        else
            git diff --name-only "${diff_args[@]}"
        fi
        return 0
    fi

    local commits
    commits=$(git rev-list --count "$merge_base..$head_rev")

    local head_detail="$commits commit"
    [[ "$commits" == "1" ]] || head_detail="$commits commits"
    if [[ "$include_dirty" == "true" ]]; then
        head_detail="$head_detail + working tree"
    fi

    field "Base" "$(printf '%s%s%s %s(merge base %s)%s' "$CYAN" "$base" "$NC" "$DIM" "$(git rev-parse --short "$merge_base")" "$NC")"
    field "Head" "$(printf '%s%s%s %s(%s)%s' "$CYAN" "$head_label" "$NC" "$DIM" "$head_detail" "$NC")"
    printf '\n'

    if [[ "$mode" == "stat" ]]; then
        git diff --stat "${diff_args[@]}"
        return 0
    fi

    local numstat
    numstat=$(git diff --numstat "${diff_args[@]}")

    if [[ -z "$numstat" ]]; then
        info "  No file changes."
        return 0
    fi

    printf '%s\n' "$numstat" | awk \
        -v green="$GREEN" -v red="$RED" -v dim="$DIM" -v nc="$NC" '
        BEGIN { FS = "\t"; n = 0; wa = 0; wr = 0; total_added = 0; total_removed = 0; binaries = 0 }
        {
            n++
            added[n] = $1
            removed[n] = $2
            path[n] = $3
            if ($1 == "-") {
                binaries++
            } else {
                total_added += $1
                total_removed += $2
            }
            if (length($1) > wa) { wa = length($1) }
            if (length($2) > wr) { wr = length($2) }
        }
        END {
            for (i = 1; i <= n; i++) {
                if (added[i] == "-") {
                    printf "  %s%*s  %*s  %s (binary)%s\n", dim, wa + 1, "-", wr + 1, "-", path[i], nc
                } else {
                    printf "  %s%*s%s  %s%*s%s  %s\n", \
                        green, wa + 1, "+" added[i], nc, \
                        red, wr + 1, "-" removed[i], nc, \
                        path[i]
                }
            }
            printf "\n  %d file%s changed, %s+%d%s, %s-%d%s", \
                n, (n == 1 ? "" : "s"), green, total_added, nc, red, total_removed, nc
            if (binaries > 0) {
                printf ", %d binary", binaries
            }
            printf "\n"
        }'

    # Browse the same files with a live diff preview; selections go to stdout so
    # they can be piped into an editor or a linter
    if [[ "$interactive" == "true" ]]; then
        local selection
        selection=$(git diff --name-only "${diff_args[@]}" \
            | gitx_pick_paths "changed" "git diff --color=always $preview_range -- {}") || true
        if [[ -n "$selection" ]]; then
            printf '\n'
            printf '%s\n' "$selection"
        fi
    fi
}
