#!/usr/bin/env bash
#
# ntfy.sh - Interact with a self-hosted ntfy server from the command line

set -euo pipefail

DEFAULT_SERVER="http://ntfy.home.arpa"
DEFAULT_TOPIC="${NTFY_TOPIC:-alerts}"
CONNECT_TIMEOUT=10
REQUEST_TIMEOUT=30

SERVER="${NTFY_SERVER:-$DEFAULT_SERVER}"
TOKEN="${NTFY_TOKEN:-}"
USER_NAME="${NTFY_USER:-}"
PASSWORD="${NTFY_PASSWORD:-}"
INSECURE=false
COMMON_CURL_ARGS=()

show_help() {
    cat << EOF
Usage: $(basename "$0") [GLOBAL_OPTIONS] MESSAGE
       $(basename "$0") [GLOBAL_OPTIONS] COMMAND [COMMAND_OPTIONS]
       $(basename "$0") [GLOBAL_OPTIONS] TOPIC MESSAGE
       $(basename "$0") [GLOBAL_OPTIONS] TOPIC < message.txt

Interact with a ntfy server. Defaults to ${DEFAULT_SERVER}.

Publishing is the primary workflow. A single MESSAGE sends to the default topic (${DEFAULT_TOPIC}).
TOPIC MESSAGE is shorthand for send TOPIC MESSAGE. Common local topics: agents, chores.

COMMANDS:
    send, publish, pub      Publish a notification to a topic
    subscribe, sub, listen  Subscribe to a topic as newline-delimited JSON
    poll                    Fetch cached messages once as newline-delimited JSON
    health                  Check the ntfy server health endpoint

GLOBAL OPTIONS:
    -h, --help              Show this help message
    -s, --server URL        ntfy server URL or host (default: ${DEFAULT_SERVER})
        --token TOKEN       Bearer token for authenticated ntfy servers
        --user USER         Username for basic auth
        --password PASS     Password for basic auth
    -k, --insecure          Allow insecure TLS certificates

SEND OPTIONS:
    -T, --title TITLE       Notification title
    -p, --priority VALUE    Priority: min, low, default, high, urgent, or 1-5
        --tags TAGS         Comma-separated tags/emojis
        --markdown          Enable markdown rendering
        --click URL         URL opened when the notification is clicked
        --attach URL        Attachment URL
        --filename NAME     Attachment filename
        --delay DELAY       Delivery delay, for example 10m, 1h, 2025-12-31
        --email ADDRESS     Forward notification to email
        --no-cache          Disable ntfy message caching
        --no-firebase       Disable Firebase forwarding
    -H, --header HEADER     Extra ntfy/curl header, for example 'Actions: view, Open, https://example.com'
    -q, --quiet             Suppress publish response output

SUBSCRIBE/POLL OPTIONS:
        --since VALUE       Start from a message ID, 'all', or a duration like 10m
        --scheduled         Include scheduled messages

ENVIRONMENT:
    NTFY_SERVER             Override server URL (default: ${DEFAULT_SERVER})
    NTFY_TOPIC              Default publish topic (default: ${DEFAULT_TOPIC})
    NTFY_TOKEN              Bearer token
    NTFY_USER               Basic auth username
    NTFY_PASSWORD           Basic auth password

EXAMPLES:
    $(basename "$0") "Quick notification to the default topic"
    echo "Long job is done" | $(basename "$0")
    $(basename "$0") agents "Agent done: updated docs and tests passed"
    $(basename "$0") send -T "Agent done" --tags robot agents "Finished work in scripts"
    $(basename "$0") chores "Take out trash bins tonight"
    $(basename "$0") alerts "Build finished"
    echo "Long job is done" | $(basename "$0") send agents
    $(basename "$0") sub agents
    $(basename "$0") poll --since all agents
    $(basename "$0") health
EOF
}

error() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "'$command_name' is required but not installed"
    fi
}

stdin_available() {
    [[ -p /dev/stdin || -f /dev/stdin ]]
}

normalize_server() {
    local value="$1"

    if [[ -z "$value" ]]; then
        error "Server URL cannot be empty"
    fi

    if [[ ! "$value" =~ ^https?:// ]]; then
        value="http://$value"
    fi

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    printf '%s' "$value"
}

validate_topic() {
    local topic="$1"

    if [[ ! "$topic" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
        error "Invalid topic '$topic'. Use 1-64 URL-safe characters: letters, numbers, dot, underscore, or hyphen."
    fi
}

validate_header_value() {
    local name="$1"
    local value="$2"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        error "$name cannot contain newlines"
    fi
}

validate_priority() {
    local priority="$1"

    case "$priority" in
        min|low|default|high|urgent|1|2|3|4|5)
            ;;
        *)
            error "Invalid priority '$priority'. Use min, low, default, high, urgent, or 1-5."
            ;;
    esac
}

url_encode() {
    local string="$1"
    local length=${#string}
    local i
    local char

    LC_CTYPE=C
    for ((i = 0; i < length; i++)); do
        char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-])
                printf '%s' "$char"
                ;;
            *)
                printf '%%%02X' "'$char"
                ;;
        esac
    done
}

append_query() {
    local url="$1"
    local key="$2"
    local value="${3-}"
    local encoded

    encoded=$(url_encode "$key")
    if [[ -n "$value" ]]; then
        encoded+="=$(url_encode "$value")"
    fi

    if [[ "$url" == *\?* ]]; then
        printf '%s&%s' "$url" "$encoded"
    else
        printf '%s?%s' "$url" "$encoded"
    fi
}

prepare_curl_args() {
    if [[ -n "$TOKEN" && -n "$USER_NAME" ]]; then
        error "Use either token auth or basic auth, not both"
    fi

    if [[ -n "$USER_NAME" && -z "$PASSWORD" ]]; then
        error "NTFY_PASSWORD or --password is required when using basic auth"
    fi

    COMMON_CURL_ARGS=(
        --silent
        --show-error
        --fail
        --connect-timeout "$CONNECT_TIMEOUT"
    )

    if [[ "$INSECURE" == true ]]; then
        COMMON_CURL_ARGS+=(--insecure)
    fi

    if [[ -n "$TOKEN" ]]; then
        validate_header_value "Token" "$TOKEN"
        COMMON_CURL_ARGS+=(--header "Authorization: Bearer $TOKEN")
    elif [[ -n "$USER_NAME" ]]; then
        COMMON_CURL_ARGS+=(--user "$USER_NAME:$PASSWORD")
    fi
}

send_command() {
    local quiet=false
    local title=""
    local priority=""
    local tags=""
    local click=""
    local attach=""
    local filename=""
    local delay=""
    local email=""
    local markdown=false
    local no_cache=false
    local no_firebase=false
    local custom_headers=()
    local topic
    local message
    local url
    local response
    local curl_args

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -T|--title)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                title="$2"
                shift 2
                ;;
            -p|--priority)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                priority="$2"
                validate_priority "$priority"
                shift 2
                ;;
            --tags)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                tags="$2"
                shift 2
                ;;
            --markdown)
                markdown=true
                shift
                ;;
            --click)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                click="$2"
                shift 2
                ;;
            --attach)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                attach="$2"
                shift 2
                ;;
            --filename)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                filename="$2"
                shift 2
                ;;
            --delay)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                delay="$2"
                shift 2
                ;;
            --email)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                email="$2"
                shift 2
                ;;
            --no-cache)
                no_cache=true
                shift
                ;;
            --no-firebase)
                no_firebase=true
                shift
                ;;
            -H|--header)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                validate_header_value "Header" "$2"
                [[ "$2" == *:* ]] || error "Custom header must contain a colon, for example 'Actions: view, Open, https://example.com'"
                custom_headers+=(--header "$2")
                shift 2
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            --)
                shift
                break
                ;;
            -* )
                error "Unknown send option: $1. Use -h or --help for usage information."
                ;;
            *)
                break
                ;;
        esac
    done

    [[ $# -ge 1 ]] || error "Missing topic"
    topic="$1"
    shift
    validate_topic "$topic"

    if [[ $# -gt 0 ]]; then
        message="$*"
    elif stdin_available; then
        message=$(cat)
    else
        error "No message provided. Pass a message argument or pipe one on stdin."
    fi

    if [[ -z "$message" ]]; then
        error "Message cannot be empty"
    fi

    url="$SERVER/$topic"
    curl_args=("${COMMON_CURL_ARGS[@]}" --max-time "$REQUEST_TIMEOUT" --request POST)

    if [[ -n "$title" ]]; then
        validate_header_value "Title" "$title"
        curl_args+=(--header "Title: $title")
    fi
    if [[ -n "$priority" ]]; then
        validate_header_value "Priority" "$priority"
        curl_args+=(--header "Priority: $priority")
    fi
    if [[ -n "$tags" ]]; then
        validate_header_value "Tags" "$tags"
        curl_args+=(--header "Tags: $tags")
    fi
    if [[ -n "$click" ]]; then
        validate_header_value "Click" "$click"
        curl_args+=(--header "Click: $click")
    fi
    if [[ -n "$attach" ]]; then
        validate_header_value "Attach" "$attach"
        curl_args+=(--header "Attach: $attach")
    fi
    if [[ -n "$filename" ]]; then
        validate_header_value "Filename" "$filename"
        curl_args+=(--header "Filename: $filename")
    fi
    if [[ -n "$delay" ]]; then
        validate_header_value "Delay" "$delay"
        curl_args+=(--header "Delay: $delay")
    fi
    if [[ -n "$email" ]]; then
        validate_header_value "Email" "$email"
        curl_args+=(--header "Email: $email")
    fi

    if [[ "$markdown" == true ]]; then
        curl_args+=(--header "Markdown: yes")
    fi
    if [[ "$no_cache" == true ]]; then
        curl_args+=(--header "Cache: no")
    fi
    if [[ "$no_firebase" == true ]]; then
        curl_args+=(--header "Firebase: no")
    fi
    if [[ ${#custom_headers[@]} -gt 0 ]]; then
        curl_args+=("${custom_headers[@]}")
    fi

    if ! response=$(printf '%s' "$message" | curl "${curl_args[@]}" --data-binary @- "$url"); then
        error "Failed to publish notification to $topic"
    fi

    if [[ "$quiet" != true ]]; then
        printf '%s\n' "$response"
    fi
}

stream_command() {
    local mode="$1"
    shift
    local since=""
    local scheduled=false
    local topic
    local url
    local curl_args

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --since)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                since="$2"
                shift 2
                ;;
            --scheduled)
                scheduled=true
                shift
                ;;
            --)
                shift
                break
                ;;
            -* )
                error "Unknown $mode option: $1. Use -h or --help for usage information."
                ;;
            *)
                break
                ;;
        esac
    done

    [[ $# -eq 1 ]] || error "$mode requires exactly one topic"
    topic="$1"
    validate_topic "$topic"

    url="$SERVER/$topic/json"
    if [[ "$mode" == "poll" ]]; then
        url=$(append_query "$url" "poll" "1")
    fi
    if [[ -n "$since" ]]; then
        url=$(append_query "$url" "since" "$since")
    fi
    if [[ "$scheduled" == true ]]; then
        url=$(append_query "$url" "scheduled" "1")
    fi

    if [[ "$mode" == "poll" ]]; then
        curl_args=("${COMMON_CURL_ARGS[@]}" --max-time "$REQUEST_TIMEOUT")
    else
        curl_args=("${COMMON_CURL_ARGS[@]}" --max-time 0 --no-buffer)
    fi

    if ! curl "${curl_args[@]}" "$url"; then
        error "Failed to $mode topic $topic"
    fi
}

health_command() {
    local response

    if [[ $# -ne 0 ]]; then
        error "health does not accept arguments"
    fi

    if ! response=$(curl "${COMMON_CURL_ARGS[@]}" --max-time "$REQUEST_TIMEOUT" "$SERVER/v1/health"); then
        error "Failed to query ntfy health endpoint"
    fi

    printf '%s\n' "$response"
}

main() {
    local command=""
    local shorthand_send=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--server)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                SERVER="$2"
                shift 2
                ;;
            --token)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                TOKEN="$2"
                shift 2
                ;;
            --user)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                USER_NAME="$2"
                shift 2
                ;;
            --password)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                PASSWORD="$2"
                shift 2
                ;;
            -k|--insecure)
                INSECURE=true
                shift
                ;;
            --)
                shift
                break
                ;;
            send|publish|pub|subscribe|sub|listen|poll|health)
                command="$1"
                shorthand_send=false
                shift
                break
                ;;
            -* )
                error "Unknown global option: $1. Use -h or --help for usage information."
                ;;
            *)
                command="send"
                shorthand_send=true
                break
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        if [[ $# -gt 0 ]]; then
            command="send"
            shorthand_send=true
        elif stdin_available; then
            command="send"
            shorthand_send=true
            set -- "$DEFAULT_TOPIC"
        else
            show_help
            exit 0
        fi
    fi

    if [[ "$command" == "send" && "$shorthand_send" == true && $# -eq 1 ]] && ! stdin_available; then
        set -- "$DEFAULT_TOPIC" "$1"
    fi

    require_command curl
    SERVER=$(normalize_server "$SERVER")
    validate_topic "$DEFAULT_TOPIC"
    prepare_curl_args

    case "$command" in
        send|publish|pub)
            send_command "$@"
            ;;
        subscribe|sub|listen)
            stream_command "subscribe" "$@"
            ;;
        poll)
            stream_command "poll" "$@"
            ;;
        health)
            health_command "$@"
            ;;
        *)
            error "Unknown command: $command"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
