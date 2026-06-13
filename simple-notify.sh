#!/usr/bin/env bash
#
# simple-notify.sh - Send a Simplepush notification from the command line

set -euo pipefail

DEFAULT_ENDPOINT="https://api.simplepush.io/send"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] MESSAGE
       $(basename "$0") [OPTIONS] < message.txt

Send a Simplepush notification as JSON.

OPTIONS:
    -h, --help              Show this help message
    -q, --quiet             Suppress API response output
    -u, --url URL           Override the Simplepush endpoint

ENVIRONMENT:
    SIMPLE_PUSH_KEY         Required. Your Simplepush key.

EXAMPLES:
    $(basename "$0") "Build finished"
    $(basename "$0") Deploy completed successfully
    echo "Long job is done" | $(basename "$0")

FISH SETUP:
    set -Ux SIMPLE_PUSH_KEY your-simplepush-key

PAYLOAD:
    {"key":"<SIMPLE_PUSH_KEY>","msg":"<message>"}
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

json_escape() {
    local value="${1-}"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//$'\f'/\\f}
    value=${value//$'\b'/\\b}

    printf '%s' "$value"
}

main() {
    local quiet=false
    local endpoint="$DEFAULT_ENDPOINT"
    local message=""
    local key="${SIMPLE_PUSH_KEY:-}"
    local payload
    local response

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -u|--url)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                endpoint="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown option: $1. Use -h or --help for usage information."
                ;;
            *)
                break
                ;;
        esac
    done

    require_command curl

    if [[ -z "$key" ]]; then
        error "SIMPLE_PUSH_KEY is not set"
    fi

    if [[ $# -gt 0 ]]; then
        message="$*"
    elif [[ ! -t 0 ]]; then
        message=$(cat)
    else
        error "No message provided. Pass a message argument or pipe one on stdin."
    fi

    if [[ -z "$message" ]]; then
        error "Message cannot be empty"
    fi

    payload=$(printf '{"key":"%s","msg":"%s"}' \
        "$(json_escape "$key")" \
        "$(json_escape "$message")")

    response=$(curl \
        --silent \
        --show-error \
        --fail \
        --connect-timeout 10 \
        --max-time 30 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data "$payload" \
        "$endpoint")

    if [[ "$quiet" != true ]]; then
        printf '%s\n' "$response"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
