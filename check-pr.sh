#!/usr/bin/env bash
set -euo pipefail

WATCH=false
CONCISE=false
TARGET_DIR=$PWD
DIR_SET=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--watch)
      WATCH=true
      shift
      ;;
    --concise)
      CONCISE=true
      shift
      ;;
    -C|--directory)
      if [ "$#" -lt 2 ]; then
        echo "Missing directory for $1" >&2
        exit 2
      fi
      TARGET_DIR=$2
      DIR_SET=true
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: check-pr.sh [-w|--watch] [--concise] [-C|--directory DIR] [DIR]

Summarize the open GitHub pull request for a git branch.
Defaults to the current working directory.

Options:
  -C, --directory DIR  Run against this repository directory.
  -w, --watch          Refresh every 30 seconds.
  --concise            Hide URL/path and passing checks; show only what needs attention.
  -h, --help           Show this help.
EOF
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
    *)
      if [ "$DIR_SET" = true ]; then
        echo "Only one directory can be specified" >&2
        exit 2
      fi
      TARGET_DIR=$1
      DIR_SET=true
      shift
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  if [ "$DIR_SET" = true ] || [ "$#" -gt 1 ]; then
    echo "Only one directory can be specified" >&2
    exit 2
  fi
  TARGET_DIR=$1
fi

for cmd in gh jq gum git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required for check-pr.sh" >&2
    exit 1
  fi
done

if ! cd "$TARGET_DIR"; then
  echo "Could not enter directory: $TARGET_DIR" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Directory is not inside a git repository: $TARGET_DIR" >&2
  exit 1
fi
TARGET_DIR=$(pwd -P)

color_status() {
  case "${1:-}" in
    COMPLETED|SUCCESS|PASSING|PASSED|CLEAN|MERGEABLE) gum style --foreground 42 "${1}" ;;
    IN_PROGRESS|PENDING|QUEUED|WAITING|REQUESTED|BEHIND|NONE|COMMENTED|WARNING) gum style --foreground 214 "${1}" ;;
    FAILURE|FAILED|FAILING|ERROR|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|BLOCKED|DIRTY) gum style --foreground 196 "${1}" ;;
    DRAFT) gum style --foreground 244 "${1}" ;;
    CANCELLED|CANCELED|SKIPPED) gum style --foreground 214 "${1}" ;;
    NEUTRAL|""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

color_review() {
  case "${1:-}" in
    APPROVED) gum style --foreground 42 "${1}" ;;
    CHANGES_REQUESTED) gum style --foreground 196 "${1}" ;;
    COMMENTED) gum style --foreground 214 "${1}" ;;
    REVIEW_REQUIRED) gum style --foreground 214 "${1}" ;;
    BLOCKED|RATE_LIMITED) gum style --foreground 196 "${1}" ;;
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
    true) gum style --foreground 244 "${1}" ;;    ""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

color_ready() {
  case "${1:-}" in
    READY*) gum style --foreground 42 "${1}" ;;
    WAITING*|UNKNOWN*) gum style --foreground 214 "${1}" ;;
    NOT_READY*) gum style --foreground 196 "${1}" ;;
    ""|-) gum style --foreground 244 "${1:--}" ;;
    *) gum style --foreground 244 "${1}" ;;
  esac
}

shorten() {
  local text=$1
  local max=$2
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$((max - 1))}"
  fi
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
  draft=$(echo "$pr" | jq -r '.isDraft // empty')
  merge=$(echo "$pr" | jq -r '.mergeStateStatus // "UNKNOWN"')
  review_decision=$(echo "$pr" | jq -r '.reviewDecision // "REVIEW_REQUIRED"')

  # GraphQL variables are expanded by gh from the -F arguments, not by the shell.
  # shellcheck disable=SC2016
  threads_json=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){isDraft reviewThreads(first:100){nodes{id,isResolved,isOutdated,comments(first:10){nodes{author{login}path body}}}}}}}' \
    -F owner="$owner" \
    -F repo="$repo" \
    -F number="$number")

  graphql_draft=$(echo "$threads_json" | jq -r '.data.repository.pullRequest.isDraft // empty')
  draft=${graphql_draft:-${draft:-false}}

  if [ "$draft" = "true" ]; then
    check_rows=$(echo "$pr" | jq -r '
      .statusCheckRollup
      | if length == 0 then
          ["Draft PR: checks/actions may be disabled until marked ready|-|SKIPPED"]
        else
          map((.name // .context // "unknown") + "|" + (.status // "-") + "|" + (.conclusion // .state // "-"))
        end
      | .[]
    ')
  else
    check_rows=$(echo "$pr" | jq -r '
      .statusCheckRollup
      | if length == 0 then
          ["(no checks reported)|-|-" ]
        else
          map((.name // .context // "unknown") + "|" + (.status // "-") + "|" + (.conclusion // .state // "-"))
        end
      | .[]
    ')
  fi

  reviews_json=$(gh api "repos/$owner/$repo/pulls/$number/reviews")
  comments_json=$(gh api "repos/$owner/$repo/issues/$number/comments")

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

  bot_reviews=$(echo "$reviews_json" | jq '
    group_by(.user.login)
    | map(max_by(.submittedAt))
    | map(select(.user.type == "Bot"))
  ')
  bot_review_count=$(echo "$bot_reviews" | jq 'length')

  bot_blocked=$(echo "$comments_json" | jq -r '
    [.[] | select(.user.type == "Bot")]
    | map(select(
        .body | test("couldn.t start this review"; "i")
        or test("Review limit reached"; "i")
        or test("rate limited by coderabbit"; "i")
        or test("used up its prepaid credits"; "i")
        or test("credit purchases are no longer available"; "i")
        or test("Review skipped: free tier disabled"; "i")
        or test("reached your Codex usage limits"; "i")
        or test("More reviews will be available in"; "i")
      ))
    | map(.user.login | sub("\\[bot\\]$"; ""))
    | unique
    | .[]
  ')
  bot_blocked=${bot_blocked:-}

  bot_warnings=$(echo "$comments_json" | jq -r '
    [.[] | select(.user.type == "Bot")]
    | map(select(
        (.body | test("\\[!WARNING\\]"; "i") or test("\\[!CAUTION\\]"; "i"))
        and (.body | test("couldn.t start this review"; "i") | not)
        and (.body | test("Review limit reached"; "i") | not)
        and (.body | test("rate limited by coderabbit"; "i") | not)
        and (.body | test("used up its prepaid credits"; "i") | not)
        and (.body | test("credit purchases are no longer available"; "i") | not)
        and (.body | test("Review skipped: free tier disabled"; "i") | not)
        and (.body | test("reached your Codex usage limits"; "i") | not)
        and (.body | test("More reviews will be available in"; "i") | not)
      ))
    | map(.user.login | sub("\\[bot\\]$"; ""))
    | unique
    | .[]
  ')
  bot_warnings=${bot_warnings:-}

  bot_comment_rows=$(echo "$comments_json" | jq -r '
    [.[] | select(.user.type == "Bot")]
    | group_by(.user.login)
    | map({
        bot: (.[0].user.login | sub("\\[bot\\]$"; "")),
        comments: length,
        warnings: ([.[] | select(.body | test("\\[!WARNING\\]|\\[!CAUTION\\]"; "i"))] | length),
        skipped: ([.[] | select(.body | test("Review skipped|skip review"; "i"))] | length),
        draft_skipped: ([.[] | select(.body | test("Review skipped|skip review"; "i") and test("Draft detected"; "i"))] | length)
      })
    | .[]
    | .bot + "\t" + (.comments | tostring) + "\t" + (.warnings | tostring) + "\t" + (.skipped | tostring) + "\t" + (.draft_skipped | tostring)
  ')
  bot_comment_rows=${bot_comment_rows:-}
  coderabbit_skipped=false
  if printf '%s\n' "$bot_comment_rows" | awk -F '\t' '$1 == "coderabbitai" && $4 > 0 { found = 1 } END { exit found ? 0 : 1 }'; then
    coderabbit_skipped=true
  fi

  blocked_json=$(echo "$bot_blocked" | jq -R -s 'split("\n") | map(select(. != ""))')
  effective_review=$(echo "$reviews_json" | jq -r \
    --argjson blocked "$blocked_json" \
    --arg decision "$review_decision" \
    '
      group_by(.user.login)
      | map(max_by(.submittedAt))
      | map(select(.user.type != "Bot" or (
          .user.login | sub("\\[bot\\]$"; "") as $name
          | ($blocked | contains([$name]) | not)
        )))
      | map(.state)
      | if contains(["CHANGES_REQUESTED"]) then "CHANGES_REQUESTED"
        elif contains(["APPROVED"]) then "APPROVED"
        elif $decision != "" and $decision != "null" then $decision
        else "REVIEW_REQUIRED"
        end
    ')

  review_comment_count=$(echo "$reviews_json" | jq '[.[] | select(.state == "COMMENTED")] | length')
  check_state=$(echo "$pr" | jq -r '
    .statusCheckRollup as $checks
    | if ($checks | length) == 0 then "NONE"
      elif any($checks[]; ((.conclusion // .state // "") as $s | ["FAILURE", "FAILED", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED", "CANCELED"] | index($s))) then "FAILING"
      elif any($checks[]; ((.status // .state // "") as $s | ["IN_PROGRESS", "PENDING", "QUEUED", "WAITING", "REQUESTED"] | index($s))) then "PENDING"
      else "PASSING"
      end
  ')
  check_summary=$(echo "$pr" | jq -r '
    .statusCheckRollup as $checks
    | if ($checks | length) == 0 then "no checks reported"
      else
        ([ $checks[] | select(((.conclusion // .state // "") as $s | ["FAILURE", "FAILED", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED", "CANCELED"] | index($s))) ] | length) as $failing
        | ([ $checks[] | select(((.status // .state // "") as $s | ["IN_PROGRESS", "PENDING", "QUEUED", "WAITING", "REQUESTED"] | index($s))) ] | length) as $pending
        | ([ $checks[] | select(((.conclusion // .state // "") as $s | ["SUCCESS", "PASSED", "PASSING"] | index($s))) ] | length) as $passing
        | "\($failing) failing, \($pending) pending, \($passing) passing"
      end
  ')

  blockers=0
  waiting=0
  blocker_rows=""
  if [ "$draft" = "true" ]; then
    blockers=$((blockers + 1))
    blocker_rows+="Draft\t$(color_status DRAFT)\tMark ready for review; draft PRs can suppress actions/checks.\n"
  fi
  if [ "$merge" != "CLEAN" ] && [ "$merge" != "HAS_HOOKS" ]; then
    blockers=$((blockers + 1))
    blocker_rows+="Base branch\t$(color_status "$merge")\tUpdate branch with $base before merging.\n"
  fi
  if [ "$effective_review" = "CHANGES_REQUESTED" ]; then
    blockers=$((blockers + 1))
    blocker_rows+="Review\t$(color_review "$effective_review")\tResolve requested changes.\n"
  fi
  if [ "$check_state" = "FAILING" ]; then
    blockers=$((blockers + 1))
    blocker_rows+="Checks\t$(color_status "$check_state")\t$check_summary.\n"
  elif [ "$check_state" = "PENDING" ]; then
    waiting=$((waiting + 1))
    blocker_rows+="Checks\t$(color_status "$check_state")\t$check_summary.\n"
  fi

  if [ "$blockers" -gt 0 ]; then
    ready_status="NOT_READY"
    ready_reason="$blockers blocker(s)"
  elif [ "$waiting" -gt 0 ]; then
    ready_status="WAITING"
    ready_reason="$waiting pending item(s)"
  else
    ready_status="READY"
    ready_reason="no blockers detected"
  fi

  bot_unresolved_counts=$(echo "$unresolved_threads" | jq -r '
    if length == 0 then empty else
      group_by(.comments.nodes[0].author.login)
      | map({
          author: (.[0].comments.nodes[0].author.login | sub("\\[bot\\]$"; "")),
          count: length
        })
      | .[]
      | .author + "|" + (.count | tostring)
    end
  ')

  gum style --border rounded --padding "0 1" --margin "1 0" --foreground 212 \
    "$owner/$repo PR #$number · $title"

  head_display=$(shorten "$head" 42)
  if [ "$CONCISE" = false ]; then
    gum style "path    $TARGET_DIR"
  fi
  gum style "branch  $head_display → $base"
  if [ "$CONCISE" = false ]; then
    gum style "url     $url"
  fi

  if [ "$CONCISE" = true ]; then
    printf 'ready   %s  %s\n' "$(color_ready "$ready_status")" "$ready_reason"
  else
    {
      printf 'Area\tState\tDetails\n'
      printf 'Ready\t%s\t%s\n' "$(color_ready "$ready_status")" "$ready_reason"
      printf 'Draft\t%s\t%s\n' "$(color_draft "$draft")" "$([ "$draft" = "true" ] && printf 'actions may be disabled' || printf '-')"
      printf 'Base\t%s\t%s\n' "$(color_merge "$merge")" "update from $base"
      printf 'Checks\t%s\t%s\n' "$(color_status "$check_state")" "$check_summary"
      printf 'Reviews\t%s\t%s\n' "$(color_review "$effective_review")" "$([ "$review_comment_count" -gt 0 ] && printf '%s non-blocking comment review(s)' "$review_comment_count" || printf '-')"
    } | gum table --print --separator $'\t' --widths '10,14,46'
  fi

  if [ "$blockers" -gt 0 ] || [ "$waiting" -gt 0 ]; then
    gum style --margin "1 0 0 0" --bold "Needs attention"
    {
      printf 'Item\tState\tWhy it matters\n'
      printf '%b' "$blocker_rows"
    } | gum table --print --separator $'\t'
  fi

  checks_table=$(echo "$check_rows" | while IFS='|' read -r name status conclusion; do
    if [ "$conclusion" != "-" ]; then
      check_display=$conclusion
      details="completed"
    else
      check_display=$status
      details="in progress"
    fi
    if [ "$name" = "CodeRabbit" ] && [ "$coderabbit_skipped" = true ]; then
      check_display="SKIPPED"
      details="review skipped"
    fi
    if [ "$CONCISE" = true ]; then
      case "$check_display" in
        SUCCESS|PASSED|PASSING) continue ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$name" "$(color_status "${check_display:--}")" "$details"
  done)

  if [ -n "$checks_table" ]; then
    gum style --margin "1 0 0 0" --bold "Checks"
    printf '%s\n' "$checks_table" | gum table --print --separator $'\t' --columns 'Check,State,Details'
  elif [ "$CONCISE" = false ]; then
    gum style --margin "1 0 0 0" --bold "Checks"
    gum style --foreground 42 "All reported checks passed."
  fi

  if [ -n "$bot_comment_rows" ]; then
    bot_activity_table=$(echo "$bot_comment_rows" | while IFS=$'\t' read -r bot_name comment_count warning_count skipped_count draft_skipped_count; do
      state="COMMENTED"
      details="$comment_count issue comment(s)"
      if [ "$skipped_count" -gt 0 ]; then
        state="SKIPPED"
        details="$details, review skipped"
        if [ "$draft_skipped_count" -gt 0 ]; then
          details="$details: draft"
        fi
      elif [ "$warning_count" -gt 0 ]; then
        state="WARNING"
        details="$details, $warning_count warning/caution"
      elif [ "$CONCISE" = true ]; then
        continue
      fi
      bot_check_key=$(printf '%s' "$bot_name" | tr '[:upper:]' '[:lower:]')
      bot_check_key=${bot_check_key%ai}
      if [ "$skipped_count" -eq 0 ] && printf '%s\n' "$check_rows" | tr '[:upper:]' '[:lower:]' | grep -Eq "^${bot_check_key}[^|]*\\|.*(success|passed|passing)$"; then
        details="$details, check success"
      fi
      printf '%s\t%s\t%s\n' "$bot_name" "$(color_status "$state")" "$details"
    done)
    if [ -n "$bot_activity_table" ]; then
      gum style --margin "1 0 0 0" --bold "Bot activity"
      printf '%s\n' "$bot_activity_table" | gum table --print --separator $'\t' --columns 'Bot,State,Details'
    fi
  fi

  if [ "$bot_review_count" -gt 0 ]; then
    gum style --margin "1 0 0 0" --bold "Bot Reviews"
    echo "$bot_reviews" | jq -c '.[]' | while IFS= read -r bot_review; do
      bot_name=$(echo "$bot_review" | jq -r '.user.login | sub("\\[bot\\]$"; "")')
      bot_state=$(echo "$bot_review" | jq -r '.state')
      bot_unresolved=$(echo "$bot_unresolved_counts" | grep "^$bot_name|" | cut -d'|' -f2 || true)
      bot_unresolved=${bot_unresolved:-0}
      is_blocked=$(echo "$bot_blocked" | grep -c "^$bot_name$" || true)
      has_warning=$(echo "$bot_warnings" | grep -c "^$bot_name$" || true)

      if [ "$is_blocked" -gt 0 ] && [ "$bot_state" = "APPROVED" ]; then
        bot_state="BLOCKED"
      fi

      gum style "• $bot_name"
      printf '  review: %s\n' "$(color_review "$bot_state")"
      if [ "$bot_unresolved" -gt 0 ]; then
        gum style --foreground 214 "  unresolved threads: $bot_unresolved"
      fi
      if [ "$is_blocked" -gt 0 ]; then
        gum style --foreground 196 "  ⛔ Review blocked (quota/rate limit)"
      elif [ "$has_warning" -gt 0 ]; then
        gum style --foreground 214 "  ⚠️ Warning found in comments"
      fi
    done
  fi

  if [ "$effective_review" = "CHANGES_REQUESTED" ]; then
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
