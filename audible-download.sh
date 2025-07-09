#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DOWNLOAD_DIR="$HOME/Audiobooks/audible"
PROFILE=""
VERBOSE_LEVEL="info"
DOWNLOAD_ALL=false
DOWNLOAD_FORMAT="aaxc"
START_DATE=""
END_DATE=""
DRY_RUN=false

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Download audiobooks from Audible using audible-cli.

OPTIONS:
    -d, --download-dir DIR    Download directory (default: ~/Audiobooks/audible)
    -p, --profile PROFILE     Audible profile to use
    -f, --format FORMAT       Download format: aaxc, aax, pdf (default: aaxc)
    -a, --all                 Download all audiobooks from library
    -s, --start-date DATE     Download books added after this date (YYYY-MM-DD)
    -e, --end-date DATE       Download books added before this date (YYYY-MM-DD)
    -v, --verbose LEVEL       Verbose level: debug, info, warning, error (default: info)
    -n, --dry-run             Show what would be downloaded without downloading
    -h, --help                Show this help message

EXAMPLES:
    $SCRIPT_NAME --all                              # Download all audiobooks
    $SCRIPT_NAME --all --format aax                 # Download all as AAX format
    $SCRIPT_NAME --start-date "2023-01-01" --all    # Download books added after Jan 1, 2023
    $SCRIPT_NAME --profile work --all               # Use specific profile
    $SCRIPT_NAME --dry-run --all                    # Preview what would be downloaded

DEPENDENCIES:
    - uvx (for running audible-cli)
    - audible-cli (installed via uvx)
    - gum (optional, for enhanced UI)

SETUP:
    Before using this script, you need to authenticate with Audible:
    1. Run: uvx --from audible-cli audible quickstart
    2. Follow the authentication prompts
    3. Optionally create additional profiles if needed

EOF
}

log_info() {
    if command -v gum &> /dev/null; then
        gum style --foreground 39 "ℹ️  $1"
    else
        echo "INFO: $1"
    fi
}

log_error() {
    if command -v gum &> /dev/null; then
        gum style --foreground 196 "❌ $1"
    else
        echo "ERROR: $1" >&2
    fi
}

log_success() {
    if command -v gum &> /dev/null; then
        gum style --foreground 46 "✅ $1"
    else
        echo "SUCCESS: $1"
    fi
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v uvx &> /dev/null; then
        missing_deps+=("uvx")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install them and try again."
        exit 1
    fi
    
    if ! uvx --from audible-cli audible --help &> /dev/null; then
        log_error "audible-cli is not accessible via uvx"
        log_error "Please ensure audible-cli is properly installed"
        exit 1
    fi
}

validate_date() {
    local date_str="$1"
    if ! date -d "$date_str" &> /dev/null; then
        log_error "Invalid date format: $date_str"
        log_error "Please use YYYY-MM-DD format"
        exit 1
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--download-dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -p|--profile)
                PROFILE="$2"
                shift 2
                ;;
            -f|--format)
                DOWNLOAD_FORMAT="$2"
                shift 2
                ;;
            -a|--all)
                DOWNLOAD_ALL=true
                shift
                ;;
            -s|--start-date)
                START_DATE="$2"
                validate_date "$START_DATE"
                shift 2
                ;;
            -e|--end-date)
                END_DATE="$2"
                validate_date "$END_DATE"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE_LEVEL="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

build_audible_command() {
    local cmd="uvx --from audible-cli audible"
    
    if [[ -n "$PROFILE" ]]; then
        cmd+=" -P $PROFILE"
    fi
    
    cmd+=" -v $VERBOSE_LEVEL"
    
    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" library list"
        if [[ -n "$START_DATE" ]]; then
            cmd+=" --start-date $START_DATE"
        fi
        if [[ -n "$END_DATE" ]]; then
            cmd+=" --end-date $END_DATE"
        fi
    else
        cmd+=" download"
        
        if [[ "$DOWNLOAD_ALL" == true ]]; then
            cmd+=" --all"
        fi
        
        cmd+=" --$DOWNLOAD_FORMAT"
        
        if [[ -n "$START_DATE" ]]; then
            cmd+=" --start-date $START_DATE"
        fi
        
        if [[ -n "$END_DATE" ]]; then
            cmd+=" --end-date $END_DATE"
        fi
    fi
    
    echo "$cmd"
}

main() {
    parse_arguments "$@"
    
    if [[ "$DOWNLOAD_ALL" == false && -z "$START_DATE" && -z "$END_DATE" ]]; then
        log_error "You must specify either --all or date filters"
        show_help
        exit 1
    fi
    
    if [[ ! "$DOWNLOAD_FORMAT" =~ ^(aaxc|aax|pdf)$ ]]; then
        log_error "Invalid format: $DOWNLOAD_FORMAT"
        log_error "Valid formats: aaxc, aax, pdf"
        exit 1
    fi
    
    if [[ ! "$VERBOSE_LEVEL" =~ ^(debug|info|warning|error)$ ]]; then
        log_error "Invalid verbose level: $VERBOSE_LEVEL"
        log_error "Valid levels: debug, info, warning, error"
        exit 1
    fi
    
    check_dependencies
    
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$DOWNLOAD_DIR"
        cd "$DOWNLOAD_DIR"
        log_info "Download directory: $DOWNLOAD_DIR"
    fi
    
    local audible_cmd
    audible_cmd=$(build_audible_command)
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would execute the following command:"
        echo "$audible_cmd"
        log_info "This would list the audiobooks that match your criteria"
    else
        log_info "Starting audiobook download..."
        log_info "Command: $audible_cmd"
        
        if eval "$audible_cmd"; then
            log_success "Download completed successfully!"
            log_info "Files saved to: $DOWNLOAD_DIR"
        else
            log_error "Download failed"
            exit 1
        fi
    fi
}

main "$@"