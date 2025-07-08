#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="$HOME/Audiobooks/audible"
OUTPUT_DIR="$HOME/Audiobooks/OpenSwim"
PROFILE=""
ACTIVATION_BYTES=""
SEGMENT_DURATION=300
KEEP_INTERMEDIATE=false
DRY_RUN=false
TEST_LIBRARY=false

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Complete audiobook pipeline: Download → Convert → Split to MP3s
Interactive selection of audiobooks using gum for targeted processing.

PIPELINE STEPS:
1. List available audiobooks from Audible library
2. Interactive selection with gum
3. Download selected audiobooks (AAX/AAXC)
4. Convert to M4B format using activation bytes
5. Split into individual MP3 files for OpenSwim

OPTIONS:
    -p, --profile PROFILE     Audible profile to use
    -a, --activation-bytes    Activation bytes (will retrieve automatically if not provided)
    -d, --duration SECONDS    Segment duration in seconds (default: 300 = 5 minutes)
    -o, --output-dir DIR      Output directory (default: ~/Audiobooks/OpenSwim)
    -t, --temp-dir DIR        Temporary download directory (default: ~/Audiobooks/audible)
    -k, --keep-intermediate   Keep intermediate files (M4B, AAX)
    -n, --dry-run            Show what would be processed without doing it
    --test-library           Test library listing only (for debugging)
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME                                    # Full interactive pipeline
    $SCRIPT_NAME --profile work                     # Use specific profile
    $SCRIPT_NAME --duration 480                     # 8-minute segments
    $SCRIPT_NAME --keep-intermediate                # Keep downloaded files
    $SCRIPT_NAME --dry-run                          # Preview what would happen

DEPENDENCIES:
    - uvx (for audible-cli)
    - audible-cli (automatically installed via uvx)
    - ffmpeg (version 4.4+ for AAXC support)
    - gum (for interactive selection)
    - audiobook-split.sh (should be in same directory)

SETUP:
    1. Authenticate with Audible: uvx --from audible-cli audible quickstart
    2. Ensure ffmpeg 4.4+ is installed
    3. Install gum for interactive selection

DIRECTORY STRUCTURE:
    Input:  ~/Audiobooks/audible/          (temporary downloads)
    Output: ~/Audiobooks/OpenSwim/         (final MP3 files)
            └── BookTitle/                 (one folder per book)
                ├── booktitle_01.mp3
                ├── booktitle_02.mp3
                └── ...

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

log_step() {
    if command -v gum &> /dev/null; then
        gum style --foreground 208 --bold "🔄 $1"
    else
        echo "STEP: $1"
    fi
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v uvx &> /dev/null; then
        missing_deps+=("uvx")
    fi
    
    if ! command -v ffmpeg &> /dev/null; then
        missing_deps+=("ffmpeg")
    fi
    
    if ! command -v gum &> /dev/null; then
        missing_deps+=("gum")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    if ! uvx --from audible-cli audible --help &> /dev/null; then
        log_error "audible-cli is not accessible via uvx"
        exit 1
    fi
    
    if [[ ! -x "$SCRIPT_DIR/audiobook-split.sh" ]]; then
        log_error "audiobook-split.sh not found or not executable in $SCRIPT_DIR"
        exit 1
    fi
    
    # Check ffmpeg version for AAXC support
    local ffmpeg_version
    ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ $(echo "$ffmpeg_version" | cut -d. -f1) -lt 4 ]] || 
       [[ $(echo "$ffmpeg_version" | cut -d. -f1) -eq 4 && $(echo "$ffmpeg_version" | cut -d. -f2) -lt 4 ]]; then
        log_error "ffmpeg 4.4+ required for AAXC support (found: $ffmpeg_version)"
        exit 1
    fi
}

get_activation_bytes() {
    if [[ -n "$ACTIVATION_BYTES" ]]; then
        echo "$ACTIVATION_BYTES"
        return
    fi
    
    log_info "Retrieving activation bytes from audible-cli..."
    local cmd="uvx --from audible-cli audible"
    
    if [[ -n "$PROFILE" ]]; then
        cmd+=" -P $PROFILE"
    fi
    
    cmd+=" activation-bytes"
    
    local bytes
    if bytes=$(eval "$cmd" 2>/dev/null); then
        echo "$bytes"
    else
        log_error "Failed to retrieve activation bytes"
        log_error "Make sure you're authenticated with: uvx --from audible-cli audible quickstart"
        exit 1
    fi
}

get_library_list() {
    log_info "Fetching audiobook library..."
    
    local cmd="uvx --from audible-cli audible"
    
    if [[ -n "$PROFILE" ]]; then
        cmd+=" -P $PROFILE"
    fi
    
    # Try different possible formats for the export command
    local export_formats=("library export --format json" "library export --format csv" "library export" "library list")
    
    for format in "${export_formats[@]}"; do
        local test_cmd="$cmd $format"
        log_info "Trying: $test_cmd" >&2  # Send debug output to stderr
        
        local library_output
        if library_output=$(eval "$test_cmd" 2>/dev/null); then
            if [[ -n "$library_output" ]]; then
                # Check if it looks like JSON (starts with [ or {)
                if [[ "$library_output" =~ ^[[:space:]]*[\[{] ]]; then
                    echo "$library_output"
                    return 0
                elif [[ ! "$library_output" =~ (Usage:|Error:|Try) ]]; then
                    # If it's not JSON but we got valid output (not error messages)
                    log_info "Got non-JSON output, returning anyway" >&2
                    echo "$library_output"
                    return 0
                fi
            fi
        else
            log_info "Command failed: $test_cmd" >&2
        fi
    done
    
    log_error "Failed to fetch library with any format"
    log_error "Make sure you're authenticated with: uvx --from audible-cli audible quickstart"
    exit 1
}

parse_library_for_selection() {
    local library_data="$1"
    
    # Check if it's JSON format
    if [[ "$library_data" =~ ^[[:space:]]*[\[{] ]]; then
        # Parse JSON to create selection list (title | asin | format)
        echo "$library_data" | jq -r '.[] | "\(.title) | \(.asin) | \(.format_type // "unknown")"' 2>/dev/null || {
            log_error "Failed to parse library JSON"
            exit 1
        }
    else
        # Handle non-JSON format (like library list output)
        log_info "Parsing non-JSON library format" >&2
        
        # Clean the data first - remove any debug output, error messages, etc.
        local clean_data
        clean_data=$(echo "$library_data" | grep -v -E "^(•|ℹ️|❌|✅|🔄|INFO:|ERROR:|SUCCESS:|Usage:|Try|Error:|Trying:|Command failed:|Fetching|Checking|Parsing)" | grep -v "^[[:space:]]*$" | grep -v "|[[:space:]]*unknown[[:space:]]*|[[:space:]]*unknown[[:space:]]*$")
        
        # Try to parse as tab-separated values or other format
        echo "$clean_data" | while IFS=$'\t' read -r title asin format_type || [[ -n "$title" ]]; do
            if [[ -n "$title" ]]; then
                # Handle both TSV and other formats
                if [[ -n "$asin" ]]; then
                    echo "$title | $asin | ${format_type:-unknown}"
                else
                    # If no clear separation, treat the whole line as title
                    echo "$title | unknown | unknown"
                fi
            fi
        done
    fi
}

interactive_selection() {
    local library_list="$1"
    
    if [[ -z "$library_list" ]]; then
        log_error "No audiobooks found in library"
        exit 1
    fi
    
    log_info "Select audiobooks to process (use space to select, enter to confirm, ctrl+c to cancel):"
    
    # Use gum to create multi-select list
    local selected
    set +e  # Temporarily disable exit on error to handle gum cancellation
    selected=$(echo "$library_list" | gum choose --no-limit 2>/dev/null)
    local gum_exit_code=$?
    set -e  # Re-enable exit on error
    
    if [[ $gum_exit_code -ne 0 ]]; then
        log_info "Selection cancelled by user"
        exit 0
    fi
    
    if [[ -z "$selected" ]]; then
        log_info "No audiobooks selected"
        exit 0
    fi
    
    echo "$selected"
}

download_audiobook() {
    local asin="$1"
    local format="$2"
    
    log_step "Downloading audiobook: $asin"
    
    local cmd="uvx --from audible-cli audible"
    
    if [[ -n "$PROFILE" ]]; then
        cmd+=" -P $PROFILE"
    fi
    
    # Determine format flag
    local format_flag=""
    case "$format" in
        "AAX"|"aax") format_flag="--aax" ;;
        "AAXC"|"aaxc") format_flag="--aaxc" ;;
        *) format_flag="--aaxc" ;;  # Default to aaxc
    esac
    
    cmd+=" download $format_flag --asin $asin"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would execute: $cmd"
        return 0
    fi
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    if eval "$cmd"; then
        log_success "Downloaded: $asin"
        return 0
    else
        log_error "Failed to download: $asin"
        return 1
    fi
}

convert_to_m4b() {
    local input_file="$1"
    local output_file="$2"
    local activation_bytes="$3"
    
    log_step "Converting $(basename "$input_file") to M4B"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would convert $input_file to $output_file"
        return 0
    fi
    
    # Check if input file needs activation bytes (AAX format)
    if [[ "$input_file" == *.aax ]]; then
        if [[ -z "$activation_bytes" ]]; then
            log_error "Activation bytes required for AAX files"
            return 1
        fi
        ffmpeg -y -activation_bytes "$activation_bytes" -i "$input_file" -c copy "$output_file"
    else
        # AAXC files don't need activation bytes
        ffmpeg -y -i "$input_file" -c copy "$output_file"
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Converted to M4B: $(basename "$output_file")"
        return 0
    else
        log_error "Failed to convert: $(basename "$input_file")"
        return 1
    fi
}

sanitize_filename() {
    local filename="$1"
    # Remove/replace problematic characters for directory names
    echo "$filename" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
}

split_to_mp3() {
    local m4b_file="$1"
    local book_title="$2"
    
    log_step "Splitting $(basename "$m4b_file") into MP3 segments"
    
    local sanitized_title
    sanitized_title=$(sanitize_filename "$book_title")
    local book_output_dir="$OUTPUT_DIR/$sanitized_title"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would split $m4b_file into $book_output_dir"
        return 0
    fi
    
    # Use the existing audiobook-split.sh script
    "$SCRIPT_DIR/audiobook-split.sh" "$m4b_file" "$SEGMENT_DURATION" --output-dir "$book_output_dir"
    
    if [[ $? -eq 0 ]]; then
        log_success "Split complete: $book_output_dir"
        return 0
    else
        log_error "Failed to split: $(basename "$m4b_file")"
        return 1
    fi
}

cleanup_intermediate_files() {
    local keep_files="$1"
    
    if [[ "$keep_files" == true ]]; then
        log_info "Keeping intermediate files in $TEMP_DIR"
        return
    fi
    
    log_info "Cleaning up intermediate files..."
    
    # Only clean up the files we created, not the entire temp directory
    find "$TEMP_DIR" -name "*.aax" -o -name "*.aaxc" -o -name "*.m4b" | while read -r file; do
        if [[ "$DRY_RUN" == true ]]; then
            log_info "DRY RUN: Would remove $file"
        else
            rm -f "$file"
        fi
    done
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--profile)
                PROFILE="$2"
                shift 2
                ;;
            -a|--activation-bytes)
                ACTIVATION_BYTES="$2"
                shift 2
                ;;
            -d|--duration)
                SEGMENT_DURATION="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -t|--temp-dir)
                TEMP_DIR="$2"
                shift 2
                ;;
            -k|--keep-intermediate)
                KEEP_INTERMEDIATE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --test-library)
                TEST_LIBRARY=true
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

main() {
    parse_arguments "$@"
    
    check_dependencies
    
    # Special test mode for debugging library listing
    if [[ "$TEST_LIBRARY" == true ]]; then
        log_step "Testing library listing functionality"
        local library_json
        library_json=$(get_library_list 2>/dev/null)  # Suppress debug output for clean test
        
        echo "=== RAW LIBRARY OUTPUT ==="
        echo "$library_json"
        echo
        
        echo "=== PARSED LIBRARY OUTPUT ==="
        local library_list
        library_list=$(parse_library_for_selection "$library_json" 2>/dev/null)
        echo "$library_list"
        echo
        
        log_success "Library test complete"
        exit 0
    fi
    
    # Step 1: Get activation bytes
    log_step "Step 1: Getting activation bytes"
    local activation_bytes
    activation_bytes=$(get_activation_bytes)
    log_info "Activation bytes: ${activation_bytes:0:8}..."
    
    # Step 2: Get library and interactive selection
    log_step "Step 2: Fetching library and interactive selection"
    local library_json
    library_json=$(get_library_list)
    
    local library_list
    library_list=$(parse_library_for_selection "$library_json")
    
    local selected_books
    selected_books=$(interactive_selection "$library_list")
    
    if [[ -z "$selected_books" ]]; then
        log_info "No books selected, exiting"
        exit 0
    fi
    
    log_info "Selected $(echo "$selected_books" | wc -l) audiobook(s)"
    
    # Step 3: Process each selected book
    log_step "Step 3: Processing selected audiobooks"
    
    local processed_count=0
    local failed_count=0
    
    while IFS= read -r book_line; do
        if [[ -z "$book_line" ]]; then continue; fi
        
        # Parse the selection line: "title | asin | format"
        local title asin format
        title=$(echo "$book_line" | cut -d'|' -f1 | xargs)
        asin=$(echo "$book_line" | cut -d'|' -f2 | xargs)
        format=$(echo "$book_line" | cut -d'|' -f3 | xargs)
        
        log_step "Processing: $title ($asin)"
        
        # Download
        if ! download_audiobook "$asin" "$format"; then
            log_error "Failed to download: $title"
            ((failed_count++))
            continue
        fi
        
        # Find downloaded file
        local downloaded_file
        downloaded_file=$(find "$TEMP_DIR" -name "*.aax" -o -name "*.aaxc" | head -1)
        
        if [[ -z "$downloaded_file" ]]; then
            log_error "Downloaded file not found for: $title"
            ((failed_count++))
            continue
        fi
        
        # Convert to M4B
        local m4b_file="${downloaded_file%.*}.m4b"
        if ! convert_to_m4b "$downloaded_file" "$m4b_file" "$activation_bytes"; then
            log_error "Failed to convert: $title"
            ((failed_count++))
            continue
        fi
        
        # Split to MP3
        if ! split_to_mp3 "$m4b_file" "$title"; then
            log_error "Failed to split: $title"
            ((failed_count++))
            continue
        fi
        
        ((processed_count++))
        log_success "Completed: $title"
        
    done <<< "$selected_books"
    
    # Step 4: Cleanup
    log_step "Step 4: Cleanup"
    cleanup_intermediate_files "$KEEP_INTERMEDIATE"
    
    # Summary
    log_success "Pipeline complete!"
    log_info "Successfully processed: $processed_count audiobook(s)"
    if [[ $failed_count -gt 0 ]]; then
        log_error "Failed to process: $failed_count audiobook(s)"
    fi
    log_info "Output directory: $OUTPUT_DIR"
}

main "$@"