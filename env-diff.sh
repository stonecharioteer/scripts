#!/usr/bin/env bash
#
# env-diff.sh - Compare two .env files without leaking token-like values.

set -euo pipefail
IFS=$'\n\t'

MAX_VALUE_WIDTH=80
ENV_DIFF_TEMP_DIR=""

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] LEFT_ENV RIGHT_ENV

Compare two .env files and render the result as a gum table. Duplicate
assignments inside one file use the last value, matching dotenv override style.

OPTIONS:
    -h, --help              Show this help message
    -a, --all               Include unchanged variables in the table
    --exit-code             Exit 1 when differences are found
    --max-width WIDTH       Maximum displayed width for non-secret values

NOTES:
    Values that look like tokens, passwords, credentials, or private keys are
    redacted. Redacted values get stable per-run labels so equality and
    differences are still visible without printing the secret itself.

EXAMPLES:
    $(basename "$0") .env .env.example
    $(basename "$0") --all .env.local .env.production
    $(basename "$0") --exit-code .env.old .env.new
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

cleanup() {
    if [[ -n "${ENV_DIFF_TEMP_DIR:-}" ]]; then
        rm -rf "$ENV_DIFF_TEMP_DIR"
    fi
}

parse_env_file() {
    local input_file="$1"
    local output_file="$2"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        function unescape_double_quoted(value) {
            gsub(/\\\\/, "\\", value)
            gsub(/\\"/, "\"", value)
            gsub(/\\n/, "\n", value)
            gsub(/\\r/, "\r", value)
            gsub(/\\t/, "\t", value)
            return value
        }

        function parse_value(value, quote) {
            value = trim(value)

            if (length(value) >= 2) {
                quote = substr(value, 1, 1)
                if (quote == "\"" || quote == "'\''") {
                    value = substr(value, 2)
                    if (index(value, quote) > 0) {
                        value = substr(value, 1, index(value, quote) - 1)
                    }
                    if (quote == "\"") {
                        value = unescape_double_quoted(value)
                    }
                    return value
                }
            }

            sub(/[[:space:]]+#.*$/, "", value)
            return trim(value)
        }

        {
            line = $0
            sub(/\r$/, "", line)

            if (line ~ /^[[:space:]]*($|#)/) {
                next
            }

            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            equals_index = index(line, "=")
            if (equals_index == 0) {
                next
            }

            key = trim(substr(line, 1, equals_index - 1))
            if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                next
            }

            value = parse_value(substr(line, equals_index + 1))
            gsub(/\r/, "\\r", value)
            gsub(/\n/, "\\n", value)
            gsub(/\t/, "\\t", value)

            if (!(key in seen)) {
                keys[++key_count] = key
                seen[key] = 1
            }
            values[key] = value
        }

        END {
            for (idx = 1; idx <= key_count; idx++) {
                key = keys[idx]
                printf "%s\t%s\n", key, values[key]
            }
        }
    ' "$input_file" > "$output_file"
}

generate_rows() {
    local left_parsed="$1"
    local right_parsed="$2"

    awk -v max_width="$MAX_VALUE_WIDTH" '
        BEGIN {
            FS = OFS = "\t"
        }

        function has_alpha(value) {
            return value ~ /[[:alpha:]]/
        }

        function has_digit(value) {
            return value ~ /[[:digit:]]/
        }

        function has_symbol(value) {
            return value ~ /[^[:alnum:]_]/
        }

        function is_sensitive_key(key, lowered) {
            lowered = tolower(key)
            return lowered ~ /(^|_)(api[_-]?)?key($|_)|secret|token|password|passwd|pwd|credential|private|bearer|auth|session|cookie|client_secret|access_key|refresh/
        }

        function looks_like_token(value) {
            if (value == "") {
                return 0
            }

            if (value ~ /^-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
                return 1
            }
            if (value ~ /^(gh[pousr]_|github_pat_|glpat-|sk-[A-Za-z0-9]|xox[baprs]-|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ya29\.|eyJ[A-Za-z0-9_-]*\.)/) {
                return 1
            }
            if (value ~ /(token|secret|signature|sig|apikey|api_key|access_key|client_secret)=/) {
                return 1
            }
            if (value ~ /^[A-Fa-f0-9]{32,}$/) {
                return 1
            }
            if (length(value) >= 24 && value !~ /[[:space:]]/ && value ~ /^[A-Za-z0-9_+\/.=:-]+$/ && has_alpha(value) && has_digit(value) && (has_symbol(value) || length(value) >= 32)) {
                return 1
            }

            return 0
        }

        function redacted_value(value) {
            if (value == "") {
                return "∅"
            }
            if (!(value in secret_ids)) {
                secret_ids[value] = ++secret_count
            }
            return "<redacted #" secret_ids[value] " len=" length(value) ">"
        }

        function display_value(key, value, shown) {
            if (value == "") {
                return "∅"
            }
            if (is_sensitive_key(key) || looks_like_token(value)) {
                return redacted_value(value)
            }

            shown = value
            gsub(/\r/, "\\r", shown)
            gsub(/\n/, "\\n", shown)
            if (length(shown) > max_width) {
                shown = substr(shown, 1, max_width - 1) "…"
            }
            return shown
        }

        NR == FNR {
            left[$1] = $2
            if (!($1 in seen)) {
                keys[++key_count] = $1
                seen[$1] = 1
            }
            next
        }

        {
            right[$1] = $2
            if (!($1 in seen)) {
                keys[++key_count] = $1
                seen[$1] = 1
            }
        }

        END {
            for (idx = 1; idx <= key_count; idx++) {
                key = keys[idx]
                has_left = key in left
                has_right = key in right

                if (has_left && has_right) {
                    if (left[key] == right[key]) {
                        status = "SAME"
                    } else {
                        status = "CHANGED"
                    }
                } else if (has_right) {
                    status = "ADDED"
                } else {
                    status = "REMOVED"
                }

                left_display = has_left ? display_value(key, left[key]) : "—"
                right_display = has_right ? display_value(key, right[key]) : "—"
                print status, key, left_display, right_display
            }
        }
    ' "$left_parsed" "$right_parsed"
}

print_table() {
    local rows_file="$1"
    local left_label="$2"
    local right_label="$3"
    local left_name
    local right_name

    left_name=$(basename "$left_label")
    right_name=$(basename "$right_label")

    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border rounded \
        --align center \
        --width 72 \
        --margin "1 0" \
        --padding "1 2" \
        "Environment Diff" \
        "$left_name → $right_name"

    if [[ ! -s "$rows_file" ]]; then
        gum style --foreground 42 "No differences found."
        return
    fi

    gum table \
        --print \
        --separator $'\t' \
        --columns "Status,Env Var,Left,Right" \
        --widths "10,30,${MAX_VALUE_WIDTH},${MAX_VALUE_WIDTH}" \
        --border rounded \
        --header.foreground 212 \
        --border.foreground 240 \
        --file "$rows_file"
}

main() {
    local show_all=false
    local use_exit_code=false
    local left_file=""
    local right_file=""
    local left_parsed
    local right_parsed
    local all_rows
    local display_rows
    local total_count
    local changed_count
    local added_count
    local removed_count
    local same_count
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -a|--all)
                show_all=true
                shift
                ;;
            --exit-code)
                use_exit_code=true
                shift
                ;;
            --max-width)
                [[ $# -ge 2 ]] || error "Missing value for $1"
                [[ "$2" =~ ^[0-9]+$ ]] || error "--max-width must be a positive integer"
                (( 2 <= 10#$2 )) || error "--max-width must be at least 2"
                MAX_VALUE_WIDTH="$2"
                shift 2
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    positional+=("$1")
                    shift
                done
                ;;
            -* )
                error "Unknown option: $1. Use -h or --help for usage information."
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    [[ ${#positional[@]} -eq 2 ]] || error "Expected LEFT_ENV and RIGHT_ENV. Use -h or --help for usage information."
    left_file="${positional[0]}"
    right_file="${positional[1]}"

    [[ -f "$left_file" ]] || error "File not found: $left_file"
    [[ -f "$right_file" ]] || error "File not found: $right_file"

    require_command gum
    require_command awk
    require_command sort

    ENV_DIFF_TEMP_DIR=$(mktemp -d)
    trap cleanup EXIT

    left_parsed="$ENV_DIFF_TEMP_DIR/left.tsv"
    right_parsed="$ENV_DIFF_TEMP_DIR/right.tsv"
    all_rows="$ENV_DIFF_TEMP_DIR/all.tsv"
    display_rows="$ENV_DIFF_TEMP_DIR/display.tsv"

    parse_env_file "$left_file" "$left_parsed"
    parse_env_file "$right_file" "$right_parsed"
    generate_rows "$left_parsed" "$right_parsed" | sort -t $'\t' -k2,2f > "$all_rows"

    if [[ "$show_all" == true ]]; then
        cp "$all_rows" "$display_rows"
    else
        awk -F $'\t' '$1 != "SAME"' "$all_rows" > "$display_rows"
    fi

    total_count=$(awk -F $'\t' '$1 != "SAME" { count++ } END { print count + 0 }' "$all_rows")
    changed_count=$(awk -F $'\t' '$1 == "CHANGED" { count++ } END { print count + 0 }' "$all_rows")
    added_count=$(awk -F $'\t' '$1 == "ADDED" { count++ } END { print count + 0 }' "$all_rows")
    removed_count=$(awk -F $'\t' '$1 == "REMOVED" { count++ } END { print count + 0 }' "$all_rows")
    same_count=$(awk -F $'\t' '$1 == "SAME" { count++ } END { print count + 0 }' "$all_rows")

    print_table "$display_rows" "$left_file" "$right_file"

    gum style \
        --foreground 244 \
        "Summary: $total_count differences ($changed_count changed, $added_count added, $removed_count removed), $same_count unchanged."

    if [[ "$use_exit_code" == true && "$total_count" -gt 0 ]]; then
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
