#!/usr/bin/env bash
#
# pr.sh - Pull request subcommands: status for this branch, and a listing that
# shows who opened each PR and where it is headed

set -euo pipefail

show_pr_help() {
    cat << EOF
Usage: gitx pr [SUBCOMMAND] [OPTIONS]

Pull request helpers.

SUBCOMMANDS:
    check       Merge status of the PR for the current branch (default)
    list, ls    Open PRs with author and destination branch

With no subcommand, 'check' runs, so 'gitx pr' and 'gitx pr check' agree.
Each subcommand has its own help:

    gitx pr check --help
    gitx pr list --help

EXAMPLES:
    gitx pr check
    gitx pr check --concise
    gitx pr list
    gitx pr list --mine
    gitx pr list --base main
EOF
}

show_pr_check_help() {
    cat << EOF
Usage: gitx pr check [OPTIONS] [DIRECTORY]

Show the merge status of the pull request for the current branch: color-coded
blockers, check runs sorted worst-first with a previous-run comparison, reviews,
and bot activity.

Delegates to check-pr.sh, so every option it accepts works here. Run
'gitx pr check --help' for the authoritative list, which currently includes:

    -w, --watch         Refresh on an interval; 'r' refreshes now, 'q' quits
    -i, --interval SECS Watch refresh interval (default: 30)
        --concise       Show only the summary and items needing attention
    -C, --directory DIR Repository directory (defaults to the current one)

EXAMPLES:
    gitx pr check
    gitx pr check --concise
    gitx pr check -w
    gitx pr check ~/code/checkouts/personal/scripts
EOF
}

show_pr_list_help() {
    cat << EOF
Usage: gitx pr list [OPTIONS]

List pull requests with the two things 'gh pr list' leaves out of easy reach:
who opened each one, and which branch it targets. A destination that is not the
default branch is highlighted, since that is usually the interesting case (a
release promotion, or a PR aimed at the wrong branch).

OPTIONS:
    -h, --help          Show this help message
    -s, --state STATE   open, closed, merged, or all (default: open)
    -b, --base REF      Only PRs targeting REF
    -a, --author LOGIN  Only PRs by LOGIN
    -m, --mine          Only your PRs (shorthand for --author @me)
    -H, --head          Also show the source branch
    -L, --limit N       Maximum PRs to list (default: 30)
    -i, --interactive   Pick PRs with fzf; selected numbers go to stdout

EXAMPLES:
    gitx pr list
    gitx pr list --mine
    gitx pr list --base main            # what is queued for the deploy branch
    gitx pr list --state merged -L 10
    gitx pr list -i | xargs -n1 gh pr view
EOF
}

cmd_pr() {
    local wrapper="$GITX_ROOT/check-pr.sh"

    case "${1:-check}" in
        check)
            [[ $# -eq 0 ]] || shift
            [[ -x "$wrapper" ]] || error "check-pr.sh not found or not executable at $wrapper"
            exec "$wrapper" "$@"
            ;;
        list | ls)
            shift
            cmd_pr_list "$@"
            ;;
        -h | --help | --gitx-help)
            show_pr_help
            ;;
        -*)
            # Back-compat: 'gitx pr --concise' still means 'gitx pr check --concise'
            [[ -x "$wrapper" ]] || error "check-pr.sh not found or not executable at $wrapper"
            exec "$wrapper" "$@"
            ;;
        *)
            # check-pr also takes a directory positionally
            if [[ -d "$1" ]]; then
                [[ -x "$wrapper" ]] || error "check-pr.sh not found or not executable at $wrapper"
                exec "$wrapper" "$@"
            fi
            error "unknown 'pr' subcommand: $1 (try 'gitx pr check' or 'gitx pr list')"
            ;;
    esac
}

cmd_pr_list() {
    local state="open"
    local base_filter=""
    local author_filter=""
    local limit=30
    local show_head=false
    local interactive=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_pr_list_help
                return 0
                ;;
            -s | --state)
                [[ $# -ge 2 ]] || error "--state requires a value"
                state="$2"
                shift 2
                ;;
            -b | --base)
                [[ $# -ge 2 ]] || error "--base requires a ref"
                base_filter="$2"
                shift 2
                ;;
            -a | --author)
                [[ $# -ge 2 ]] || error "--author requires a login"
                author_filter="$2"
                shift 2
                ;;
            -m | --mine)
                author_filter="@me"
                shift
                ;;
            -H | --head)
                show_head=true
                shift
                ;;
            -L | --limit)
                [[ $# -ge 2 ]] || error "--limit requires a number"
                limit="$2"
                shift 2
                ;;
            -i | --interactive)
                interactive=true
                shift
                ;;
            *)
                error "unknown option for 'pr list': $1"
                ;;
        esac
    done

    case "$state" in
        open | closed | merged | all) ;;
        *) error "invalid --state '$state' (open, closed, merged, or all)" ;;
    esac
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || error "--limit must be a positive number"

    require_repo
    require_command gh
    require_command jq

    local default
    default="$(gitx_default_branch || true)"

    local -a gh_args=(
        pr list --state "$state" --limit "$limit"
        --json 'number,title,author,baseRefName,headRefName,isDraft,updatedAt,reviewDecision'
    )
    [[ -z "$base_filter" ]] || gh_args+=(--base "$base_filter")
    [[ -z "$author_filter" ]] || gh_args+=(--author "$author_filter")

    local json
    json=$(gitx_spin "Listing $state pull requests..." gh "${gh_args[@]}") \
        || error "'gh pr list' failed"

    # number, author, head, base, marker, review, age seconds, title
    local rows
    rows=$(printf '%s' "$json" | jq -r '
        .[] | [
            (.number | tostring),
            (.author.login // "unknown"),
            .headRefName,
            .baseRefName,
            (if .isDraft then "draft" else "" end),
            (.reviewDecision // ""),
            ((now - (.updatedAt | fromdateiso8601)) | floor | tostring),
            (.title | gsub("[\t\n]"; " "))
        ] | @tsv')

    if [[ -z "$rows" ]]; then
        info "No $state pull requests found."
        return 0
    fi

    local term_width
    term_width=$(tput cols 2>/dev/null || echo 100)

    local table
    table=$(printf '%s\n' "$rows" | awk -F '\t' \
        -v green="$GREEN" -v red="$RED" -v yellow="$YELLOW" -v cyan="$CYAN" \
        -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" \
        -v default_branch="$default" -v show_head="$show_head" -v width="$term_width" '
        function age(seconds) {
            if (seconds < 3600)  { return int(seconds / 60) "m" }
            if (seconds < 86400) { return int(seconds / 3600) "h" }
            if (seconds < 604800) { return int(seconds / 86400) "d" }
            return int(seconds / 604800) "w"
        }
        function shorten(text, limit) {
            if (limit < 4) { limit = 4 }
            return length(text) <= limit ? text : substr(text, 1, limit - 1) "…"
        }
        {
            n++
            number[n] = $1
            author[n] = $2
            head[n] = $3
            base[n] = $4
            draft[n] = $5
            review[n] = $6
            ago[n] = age($7 + 0)
            title[n] = $8

            # A PR aimed somewhere other than the default branch is the one you
            # want to notice
            offbase[n] = (default_branch != "" && $4 != default_branch)
            if (offbase[n]) { offbase_count++ }

            if (draft[n] != "") {
                flag[n] = "draft"
            } else if (review[n] == "CHANGES_REQUESTED") {
                flag[n] = "changes"
            } else if (review[n] == "APPROVED") {
                flag[n] = "approved"
            } else {
                flag[n] = ""
            }

            if (length(number[n]) > w_number) { w_number = length(number[n]) }
            if (length(author[n]) > w_author) { w_author = length(author[n]) }
            if (length(base[n]) > w_base) { w_base = length(base[n]) }
            if (length(flag[n]) > w_flag) { w_flag = length(flag[n]) }
            if (length(ago[n]) > w_age) { w_age = length(ago[n]) }
            if (show_head == "true" && length(head[n]) > w_head) { w_head = length(head[n]) }
        }
        END {
            if (w_head > 28) { w_head = 28 }
            if (w_base > 22) { w_base = 22 }

            # Everything except the title has a known width; the title gets what
            # is left of the terminal
            fixed = 2 + w_number + 2 + w_author + 2 + w_base + 2 + w_flag + 2 + w_age + 2
            if (show_head == "true") { fixed += w_head + 4 }
            title_width = width - fixed
            if (title_width < 24) { title_width = 24 }

            for (i = 1; i <= n; i++) {
                base_style = offbase[i] ? yellow : dim
                if (flag[i] == "changes")      { flag_style = red }
                else if (flag[i] == "approved") { flag_style = green }
                else if (flag[i] == "draft")    { flag_style = dim }
                else                            { flag_style = nc }

                line = sprintf("  %s%*s%s  %s%-*s%s", \
                    bold, w_number, number[i], nc, \
                    cyan, w_author, shorten(author[i], w_author), nc)

                if (show_head == "true") {
                    line = line sprintf("  %s%-*s%s →", dim, w_head, shorten(head[i], w_head), nc)
                }

                line = line sprintf("  %s%-*s%s  %s%-*s%s  %-*s  %s%s%s", \
                    base_style, w_base, shorten(base[i], w_base), nc, \
                    flag_style, w_flag, flag[i], nc, \
                    title_width, shorten(title[i], title_width), \
                    dim, ago[i], nc)

                print line
            }

            printf "\n  %s%d pull request%s", dim, n, (n == 1 ? "" : "s")
            if (offbase_count > 0 && default_branch != "") {
                printf ", %s%d not targeting %s%s", yellow, offbase_count, default_branch, dim
            }
            printf "%s\n", nc
        }')

    if [[ "$interactive" != "true" ]]; then
        printf '%s\n' "$table"
        return 0
    fi

    # Selected PR numbers go to stdout so they compose with gh. fzf substitutes
    # {1} (the number) into the preview itself, so it stays unexpanded here.
    local selection
    selection=$(printf '%s\n' "$rows" | awk -F '\t' '{ printf "%s\t%s\t%s → %s\t%s\n", $1, $2, $3, $4, $8 }' \
        | gitx_pick_paths "pull request" 'gh pr view {1}' \
        | awk -F '\t' '{ print $1 }') || true

    [[ -z "$selection" ]] || printf '%s\n' "$selection"
}
