#!/usr/bin/env bash
#
# sync.sh - Fetch, fast-forward the default branch, and report divergence

set -euo pipefail

show_sync_help() {
    cat << EOF
Usage: gitx sync [OPTIONS]

Fetch with prune, fast-forward the default branch, then report how the current
branch sits relative to its upstream and to the default branch.

The default branch is updated even while you are on a feature branch, using a
fast-forward-only refspec fetch, so no checkout dance is required. Nothing is
rewritten unless --rebase is passed.

OPTIONS:
    -h, --help          Show this help message
    -r, --rebase        Also rebase the current branch onto the default branch
        --no-fetch      Skip the fetch and report using existing refs
        --no-tags       Do not fetch tags

EXAMPLES:
    gitx sync                   # fetch, fast-forward main, report status
    gitx sync --rebase          # ...and rebase the current branch onto main
    gitx sync --no-fetch        # report only, no network
EOF
}

cmd_sync() {
    local do_fetch=true
    local do_rebase=false
    local fetch_tags=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_sync_help
                return 0
                ;;
            -r | --rebase)
                do_rebase=true
                shift
                ;;
            --no-fetch)
                do_fetch=false
                shift
                ;;
            --no-tags)
                fetch_tags=false
                shift
                ;;
            *)
                error "unknown option for 'sync': $1"
                ;;
        esac
    done

    require_repo

    local remote default branch
    remote="$(gitx_remote)"
    [[ -n "$remote" ]] || error "no remote configured; nothing to sync against"
    default="$(gitx_require_default_branch "$remote")"
    branch="$(gitx_current_branch)"

    if [[ "$do_fetch" == "true" ]]; then
        local -a fetch_args=(--prune "$remote")
        [[ "$fetch_tags" == "true" ]] || fetch_args=(--no-tags "${fetch_args[@]}")

        gitx_spin "Fetching $remote..." git fetch "${fetch_args[@]}" \
            || error "fetch from '$remote' failed"
        success "fetched $remote"
    fi

    git show-ref --verify --quiet "refs/remotes/$remote/$default" \
        || error "'$remote/$default' not found; is '$default' the right default branch?"

    # Fast-forward the default branch, whether or not it is checked out
    if [[ "$branch" == "$default" ]]; then
        if gitx_is_dirty; then
            warn "working tree is dirty; skipping fast-forward of '$default'"
        elif git merge-base --is-ancestor HEAD "$remote/$default"; then
            if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$remote/$default")" ]]; then
                skipped "$default already matches $remote/$default"
            elif git merge --ff-only --quiet "$remote/$default"; then
                success "fast-forwarded $default to $remote/$default"
            else
                warn "could not fast-forward '$default'"
            fi
        else
            warn "local '$default' has commits not on '$remote/$default'; resolve manually"
        fi
    elif ! git show-ref --verify --quiet "refs/heads/$default"; then
        if git fetch --quiet "$remote" "$default:$default"; then
            success "created local $default from $remote/$default"
        else
            warn "could not create local '$default'"
        fi
    elif [[ "$(git rev-parse "$default")" == "$(git rev-parse "$remote/$default")" ]]; then
        skipped "$default already matches $remote/$default"
    elif git fetch --quiet "$remote" "$default:$default" 2>/dev/null; then
        success "fast-forwarded $default to $remote/$default"
    else
        warn "local '$default' has diverged from '$remote/$default'; resolve manually"
    fi

    # Rebase the current branch if asked
    if [[ "$do_rebase" == "true" ]]; then
        if [[ -z "$branch" ]]; then
            error "HEAD is detached; cannot rebase"
        elif [[ "$branch" == "$default" ]]; then
            skipped "already on '$default'; nothing to rebase"
        elif gitx_is_dirty; then
            error "working tree has uncommitted changes; commit or stash before rebasing"
        elif git rebase "$remote/$default"; then
            success "rebased $branch onto $remote/$default"
        else
            error "rebase onto '$remote/$default' failed; resolve conflicts or run 'git rebase --abort'"
        fi
    fi

    printf '\n'
    cmd_status
}
