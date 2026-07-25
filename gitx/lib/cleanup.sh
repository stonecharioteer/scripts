#!/usr/bin/env bash
#
# cleanup.sh - Delete local branches already merged (including squash-merged)

set -euo pipefail

show_cleanup_help() {
    cat << EOF
Usage: gitx cleanup [OPTIONS]

Find local branches whose work has already landed on the default branch and
delete them. Squash-merged branches are detected too, which plain
'git branch --merged' misses entirely.

Dry run is the default: nothing is deleted until --apply is passed.

The default branch, the current branch, main, and master are always protected.
Add more via GITX_PROTECTED_BRANCHES (comma or space separated).

OPTIONS:
    -h, --help          Show this help message
        --apply         Actually delete the branches (prompts once)
        --dry-run       Report only (default)
        --no-squashed   Skip squash-merge detection (faster on big repos)
    -p, --prune         Also prune stale remote-tracking refs
    -y, --yes           Skip the confirmation prompt (implies --apply)

EXAMPLES:
    gitx cleanup                # list what would be deleted
    gitx cleanup --apply        # delete after confirming
    gitx cleanup --apply --yes  # delete without prompting
    gitx cleanup --prune        # also drop stale origin/* refs
EOF
}

cmd_cleanup() {
    local apply=false
    local check_squashed=true
    local do_prune=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_cleanup_help
                return 0
                ;;
            --apply)
                apply=true
                shift
                ;;
            --dry-run)
                apply=false
                shift
                ;;
            --no-squashed)
                check_squashed=false
                shift
                ;;
            -p | --prune)
                do_prune=true
                shift
                ;;
            -y | --yes)
                apply=true
                ASSUME_YES=true
                shift
                ;;
            *)
                error "unknown option for 'cleanup': $1"
                ;;
        esac
    done

    require_repo

    local remote default current base
    remote="$(gitx_remote)"
    default="$(gitx_require_default_branch "$remote")"
    current="$(gitx_current_branch)"
    base="$(gitx_tracking_ref "$default" "$remote")"

    git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
        || error "base ref '$base' does not exist"

    # Protected branches: defaults plus anything the user configured, deduped
    local -a candidates=("$default" "main" "master")
    [[ -z "$current" ]] || candidates+=("$current")
    if [[ -n "${GITX_PROTECTED_BRANCHES:-}" ]]; then
        local -a extra=()
        read -r -a extra <<< "${GITX_PROTECTED_BRANCHES//,/ }"
        [[ ${#extra[@]} -eq 0 ]] || candidates+=("${extra[@]}")
    fi

    local -a protected=()
    local candidate seen entry
    for candidate in "${candidates[@]}"; do
        seen=false
        for entry in "${protected[@]+"${protected[@]}"}"; do
            if [[ "$entry" == "$candidate" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == "true" ]] || protected+=("$candidate")
    done

    field "Base" "$base"
    field "Protected" "$(printf '%s ' "${protected[@]}" | sed 's/ $//')"
    printf '\n'

    local -a doomed_branches=() doomed_reasons=()
    local branch reason

    while IFS= read -r branch; do
        local is_protected=false entry
        for entry in "${protected[@]}"; do
            if [[ "$branch" == "$entry" ]]; then
                is_protected=true
                break
            fi
        done
        [[ "$is_protected" == "false" ]] || continue

        reason=""
        if gitx_is_merged "$branch" "$base"; then
            reason="merged"
        elif [[ "$check_squashed" == "true" ]] && gitx_is_squash_merged "$branch" "$base"; then
            reason="squash-merged"
        fi

        if [[ -n "$reason" ]]; then
            doomed_branches+=("$branch")
            doomed_reasons+=("$reason")
        fi
    done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

    if [[ ${#doomed_branches[@]} -eq 0 ]]; then
        info "No merged branches to clean up."
    else
        local index=0
        for branch in "${doomed_branches[@]}"; do
            reason="${doomed_reasons[$index]}"
            printf '  %s%-40s%s %s%-14s%s %s%s%s\n' \
                "$BOLD" "$branch" "$NC" \
                "$CYAN" "$reason" "$NC" \
                "$DIM" "$(git log -1 --format='%h %cr' "$branch")" "$NC"
            index=$((index + 1))
        done
        printf '\n'

        if [[ "$apply" != "true" ]]; then
            info "${DIM}Dry run: nothing deleted. Re-run with --apply to delete these ${#doomed_branches[@]} branch(es).${NC}"
        else
            # Interactively, let gum narrow the list down; everything is
            # preselected so a bare Enter deletes the lot
            local -a chosen=()
            if [[ "${ASSUME_YES:-false}" == "true" ]] || ! gitx_interactive || ! gitx_has_gum; then
                if gitx_confirm "Delete ${#doomed_branches[@]} branch(es)?"; then
                    chosen=("${doomed_branches[@]}")
                fi
            else
                local selection preselected
                preselected=$(
                    IFS=,
                    printf '%s' "${doomed_branches[*]}"
                )
                selection=$(printf '%s\n' "${doomed_branches[@]}" | gum choose \
                    --no-limit \
                    --selected "$preselected" \
                    --header 'Delete which branches? (space toggles, enter confirms)') || true
                if [[ -n "$selection" ]]; then
                    while IFS= read -r line; do
                        [[ -z "$line" ]] || chosen+=("$line")
                    done <<< "$selection"
                fi
            fi

            if [[ ${#chosen[@]} -eq 0 ]]; then
                info "Nothing selected; no branches deleted."
            else
                for branch in "${chosen[@]}"; do
                    # Recover the reason so merged branches use the safer -d
                    reason="merged"
                    index=0
                    for entry in "${doomed_branches[@]}"; do
                        if [[ "$entry" == "$branch" ]]; then
                            reason="${doomed_reasons[$index]}"
                            break
                        fi
                        index=$((index + 1))
                    done

                    # -d refuses squash-merged branches, so those need -D
                    local -a delete_args=(-d)
                    [[ "$reason" == "merged" ]] || delete_args=(-D)

                    if git branch "${delete_args[@]}" "$branch" >/dev/null 2>&1; then
                        success "deleted $branch ($reason)"
                    else
                        warn "could not delete '$branch'"
                    fi
                done
            fi
        fi
    fi

    if [[ "$do_prune" == "true" ]]; then
        printf '\n'
        if [[ -z "$remote" ]]; then
            warn "no remote configured; skipping prune"
        elif [[ "$apply" != "true" ]]; then
            info "Stale remote-tracking refs that would be pruned:"
            git remote prune --dry-run "$remote" || warn "prune check against '$remote' failed"
        elif git remote prune "$remote"; then
            success "pruned stale remote-tracking refs for $remote"
        else
            warn "prune against '$remote' failed"
        fi
    fi
}
