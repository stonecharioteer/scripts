#!/usr/bin/env bash
#
# branch.sh - Create conventionally named feature branches off the default branch

set -euo pipefail

# Conventional-commit style prefixes used for branch names
GITX_BRANCH_TYPES=(feat fix docs chore refactor test perf ci build style)

show_branch_help() {
    cat << EOF
Usage: gitx branch [OPTIONS] [TYPE] [DESCRIPTION...]
       gitx branch [OPTIONS] TYPE/NAME

Create a branch named TYPE/description-slug off an up-to-date default branch,
then switch to it. The description is slugified: lowercased, spaces and
punctuation collapsed to hyphens.

TYPE is one of: ${GITX_BRANCH_TYPES[*]}
An argument containing '/' is used verbatim. With no arguments, gum prompts
for the type and description when available.

OPTIONS:
    -h, --help          Show this help message
    -f, --from REF      Branch off REF instead of the default branch
    -t, --type TYPE     Branch type when DESCRIPTION is given on its own
    -n, --dry-run       Print the branch name that would be created
        --no-fetch      Do not refresh the base ref from the remote

EXAMPLES:
    gitx branch feat add git tools          # -> feat/add-git-tools
    gitx branch fix "PR status colours"     # -> fix/pr-status-colours
    gitx branch docs/gitx-usage             # -> docs/gitx-usage (verbatim)
    gitx branch --from v1.2.0 fix backport  # branch off a tag
    gitx branch -n feat try something       # print the name, create nothing
EOF
}

# Lowercase, collapse anything outside [a-z0-9._-] into single hyphens, trim
gitx_slugify() {
    printf '%s' "$*" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9._-' '-' \
        | sed -e 's/^-*//' -e 's/-*$//'
}

gitx_is_branch_type() {
    local candidate="$1" entry
    for entry in "${GITX_BRANCH_TYPES[@]}"; do
        [[ "$candidate" != "$entry" ]] || return 0
    done
    return 1
}

cmd_branch() {
    local from_ref=""
    local type_option=""
    local dry_run=false
    local do_fetch=true
    local -a words=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_branch_help
                return 0
                ;;
            -f | --from)
                [[ $# -ge 2 ]] || error "--from requires a ref"
                from_ref="$2"
                shift 2
                ;;
            -t | --type)
                [[ $# -ge 2 ]] || error "--type requires a value"
                type_option="$2"
                shift 2
                ;;
            -n | --dry-run)
                dry_run=true
                shift
                ;;
            --no-fetch)
                do_fetch=false
                shift
                ;;
            --)
                shift
                words+=("$@")
                break
                ;;
            -*)
                error "unknown option for 'branch': $1"
                ;;
            *)
                words+=("$1")
                shift
                ;;
        esac
    done

    require_repo

    local remote default
    remote="$(gitx_remote)"

    # Interactive fallback when nothing was supplied
    if [[ ${#words[@]} -eq 0 && -z "$type_option" ]]; then
        if command -v gum >/dev/null 2>&1 && [[ -t 0 ]]; then
            type_option=$(gum choose --header 'Branch type' "${GITX_BRANCH_TYPES[@]}") \
                || error "no branch type selected"
            local description
            description=$(gum input --placeholder 'short description' --header "Branch description") \
                || error "no description entered"
            [[ -n "$description" ]] || error "description cannot be empty"
            words=("$description")
        else
            show_branch_help
            error "nothing to do; pass a TYPE and DESCRIPTION"
        fi
    fi

    # Work out the branch name
    local name=""
    if [[ ${#words[@]} -eq 1 && "${words[0]}" == */* ]]; then
        name="${words[0]}"
    else
        local branch_type="$type_option"
        local -a description_words=()
        [[ ${#words[@]} -eq 0 ]] || description_words=("${words[@]}")

        if [[ -z "$branch_type" && ${#description_words[@]} -gt 0 ]] \
            && gitx_is_branch_type "${description_words[0]}"; then
            branch_type="${description_words[0]}"
            description_words=("${description_words[@]:1}")
        fi

        [[ -n "$branch_type" ]] || error "no branch type given; use 'gitx branch TYPE DESCRIPTION' or --type"
        [[ ${#description_words[@]} -gt 0 ]] || error "no description given for '$branch_type' branch"

        local slug
        slug="$(gitx_slugify "${description_words[*]}")"
        [[ -n "$slug" ]] || error "description slugified to an empty string"
        name="$branch_type/$slug"
    fi

    git check-ref-format --branch "$name" >/dev/null 2>&1 \
        || error "'$name' is not a valid branch name"

    if [[ "$dry_run" == "true" ]]; then
        printf '%s\n' "$name"
        return 0
    fi

    if git show-ref --verify --quiet "refs/heads/$name"; then
        error "branch '$name' already exists"
    fi

    # Resolve the start point
    local start_point
    if [[ -n "$from_ref" ]]; then
        start_point="$from_ref"
    else
        default="$(gitx_require_default_branch "$remote")"
        if [[ "$do_fetch" == "true" && -n "$remote" ]]; then
            gitx_spin "Fetching $remote/$default..." git fetch --quiet "$remote" "$default" \
                || warn "fetch from '$remote' failed; using local refs"
        fi
        start_point="$(gitx_tracking_ref "$default" "$remote")"
    fi

    git rev-parse --verify --quiet "$start_point^{commit}" >/dev/null \
        || error "start point '$start_point' does not exist"

    if gitx_is_dirty; then
        warn "uncommitted changes will carry over to the new branch"
    fi

    git checkout -b "$name" "$start_point" >/dev/null 2>&1 \
        || error "could not create branch '$name' from '$start_point'"

    success "created $name from $start_point"
}
