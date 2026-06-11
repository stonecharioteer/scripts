#!/usr/bin/env bash
set -euo pipefail

WATCH=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--watch)
      WATCH=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: check-pr.sh [-w|--watch]

Summarize the open GitHub pull request for the current git branch.

Options:
  -w, --watch   Refresh every 30 seconds.
  -h, --help    Show this help.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

for cmd in gh jq gum git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required for scripts/devex/check-pr.sh" >&2
    exit 1
  fi
done

color_status() {
  case "${1:-}" in
    COMPLETED|SUCCESS|PASSING|PASSED) gum style --foreground 42 "${1}" ;;
    IN_PROGRESS|PENDING|QUEUED|WAITING|REQUESTED) gum style --foreground 39 "${1}" ;;
    FAILURE|FAILED|ERROR|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE) gum style --foreground 196 "${1}" ;;
    CANCELLED|CANCELED) gum style --foreground 214 "${1}" ;;
    SKIPPED|NEUTRAL|""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

color_review() {
  case "${1:-}" in
    APPROVED) gum style --foreground 42 "${1}" ;;
    CHANGES_REQUESTED) gum style --foreground 196 "${1}" ;;
    REVIEW_REQUIRED) gum style --foreground 214 "${1}" ;;
    ""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

color_merge() {
  case "${1:-}" in
    CLEAN|HAS_HOOKS) gum style --foreground 42 "${1}" ;;
    UNSTABLE|UNKNOWN|BEHIND) gum style --foreground 214 "${1}" ;;
    BLOCKED|DIRTY|DRAFT) gum style --foreground 196 "${1}" ;;
    ""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

color_draft() {
  case "${1:-}" in
    false) gum style --foreground 42 "${1}" ;;
    true) gum style --foreground 214 "${1}" ;;
    ""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

render_once() {
  branch=$(git branch --show-current)
  if [ -z "$branch" ]; then
    gum style --foreground 196 "Could not determine current git branch"
    return 1
  fi

  repo_json=$(gh repo view --json owner,name)
  owner=$(echo "$repo_json" | jq -r '.owner.login')
  repo=$(echo "$repo_json" | jq -r '.name')

  pr_json=$(gh pr list \
    --head "$branch" \
    --state open \
    --json number,title,url,headRefName,baseRefName,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup \
    --limit 1)

  count=$(echo "$pr_json" | jq 'length')
  if [ "$count" -eq 0 ]; then
    gum style --border rounded --padding "0 1" --foreground 214 "No open PR found for $owner/$repo branch: $branch"
    return 1
  fi

  pr=$(echo "$pr_json" | jq '.[0]')
  number=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  url=$(echo "$pr" | jq -r '.url')
  base=$(echo "$pr" | jq -r '.baseRefName')
  head=$(echo "$pr" | jq -r '.headRefName')
  draft=$(echo "$pr" | jq -r '.isDraft')
  review=$(echo "$pr" | jq -r '.reviewDecision // "REVIEW_REQUIRED"')
  merge=$(echo "$pr" | jq -r '.mergeStateStatus // "UNKNOWN"')

  check_rows=$(echo "$pr" | jq -r '
    .statusCheckRollup
    | if length == 0 then
        ["(no checks reported)|-|-"]
      else
        map((.name // .context // "unknown") + "|" + (.status // "-") + "|" + (.conclusion // .state // "-"))
      end
    | .[]
  ')

  threads_json=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){nodes{id,isResolved,isOutdated,comments(first:10){nodes{author{login}path body}}}}}}}' \
    -F owner="$owner" \
    -F repo="$repo" \
    -F number="$number")

  reviews_json=$(gh api "repos/$owner/$repo/pulls/$number/reviews")

  unresolved_threads=$(echo "$threads_json" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]')
  unresolved_thread_count=$(echo "$unresolved_threads" | jq 'length')
  unresolved_comment_count=$(echo "$unresolved_threads" | jq '[.[].comments.nodes[]] | length')
  changes_requested_by=$(echo "$reviews_json" | jq -r '
    map(select(.state == "CHANGES_REQUESTED"))
    | unique_by(.user.login)
    | if length == 0 then empty else .[] | .user.login end
  ')
  changes_requested_count=$(echo "$reviews_json" | jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length')
  changes_requested_reviewer_count=$(echo "$reviews_json" | jq '[.[] | select(.state == "CHANGES_REQUESTED") | .user.login] | unique | length')

  gum style --border rounded --padding "0 1" --margin "1 0" --foreground 212 \
    "$owner/$repo PR #$number · $title"

  gum style "branch  $head → $base"
  printf 'review  %s\n' "$(color_review "$review")"
  printf 'merge   %s\n' "$(color_merge "$merge")"
  printf 'draft   %s\n' "$(color_draft "$draft")"
  gum style "url     $url"

  gum style --margin "1 0 0 0" --bold "Checks"
  echo "$check_rows" | while IFS='|' read -r name status conclusion; do
    gum style "• $name"
    printf '  status: %s\n' "$(color_status "${status:--}")"
    printf '  result: %s\n' "$(color_status "${conclusion:--}")"
  done

  if [ "$review" = "CHANGES_REQUESTED" ]; then
    gum style --margin "1 0 0 0" --bold "Requested changes"
    gum style "reviews   $changes_requested_count"
    gum style "reviewers $changes_requested_reviewer_count"
    gum style "threads   $unresolved_thread_count"
    gum style "comments  $unresolved_comment_count"

    if [ -n "$changes_requested_by" ]; then
      gum style --margin "1 0 0 0" --bold "Requesters"
      printf '%s\n' "$changes_requested_by" | while IFS= read -r reviewer; do
        gum style "• $reviewer"
      done
    fi

    if [ "$unresolved_thread_count" -gt 0 ]; then
      unresolved_rows=$(echo "$unresolved_threads" | jq -r '
        .[]
        | .comments.nodes[0] as $first
        | [
            ($first.author.login // "unknown"),
            ($first.path // "(no path)"),
            (if .isOutdated then "outdated" else "active" end),
            (($first.body // "") | gsub("[\r\n]+"; " ") | gsub("\\|"; "/") | .[0:84])
          ]
        | join("|")
      ')
      gum style --margin "1 0 0 0" --bold "Unresolved threads"
      echo "$unresolved_rows" | while IFS='|' read -r author path thread_state comment; do
        gum style "• $author  [$thread_state]"
        gum style --foreground 244 "  path: $path"
        gum style --foreground 244 "  note: $comment"
      done
    fi
  fi
}

if [ "$WATCH" = true ]; then
  while true; do
    clear
    date '+%Y-%m-%d %H:%M:%S'
    render_once || true
    sleep 30
  done
fi

render_once
