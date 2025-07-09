#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="$HOME/Audiobooks/audible"
RAW_DIR="$HOME/Audiobooks/audible/raw"
CONVERTED_DIR="$HOME/Audiobooks/audible/converted"
OUTPUT_DIR="$HOME/Audiobooks/OpenSwim"
CACHE_DIR="$HOME/Audiobooks/cache"
PROFILE=""
ACTIVATION_BYTES=""
SEGMENT_DURATION=300
KEEP_INTERMEDIATE=false
DRY_RUN=false
FORCE_REFRESH=false

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME <subcommand> [OPTIONS]

Modular audiobook processing pipeline with subcommands for different operations.

SUBCOMMANDS:
    download        Download audiobooks from Audible library
    convert         Convert existing AAX/AAXC files to M4B format
    split           Split M4B files into MP3 segments
    automate        Full pipeline: download and convert in one step
    metadata        Show file metadata (duration, size) in tree format

GLOBAL OPTIONS:
    -p, --profile PROFILE     Audible profile to use
    -d, --duration SECONDS    Segment duration in seconds (default: 300 = 5 minutes)
    -o, --output-dir DIR      Output directory (default: ~/Audiobooks/OpenSwim)
    -t, --temp-dir DIR        Temporary download directory (default: ~/Audiobooks/audible)
    -r, --raw-dir DIR         Raw download directory (default: ~/Audiobooks/audible/raw)
    -c, --converted-dir DIR   Converted files directory (default: ~/Audiobooks/audible/converted)
    -k, --keep-intermediate   Keep intermediate files (M4B, AAX)
    -n, --dry-run            Show what would be processed without doing it
    --force-refresh          Force refresh of library cache
    -h, --help               Show this help message

For subcommand-specific help, use: $SCRIPT_NAME <subcommand> --help

DOWNLOAD SUBCOMMAND:
    Download audiobooks from your Audible library with automatic conversion to M4B.
    
    Usage: $SCRIPT_NAME download [OPTIONS]
    
    Options:
        -a, --all                Download all audiobooks from library
        -f, --format FORMAT      Download format: aaxc, aax, pdf (default: aaxc)
        --activation-bytes BYTES Activation bytes (auto-retrieved if not provided)
        --no-convert            Skip automatic conversion to M4B
        --force-refresh          Force refresh of library cache before download
    
    Examples:
        $SCRIPT_NAME download                    # Interactive selection with auto-conversion
        $SCRIPT_NAME download --all              # Download all audiobooks with conversion
        $SCRIPT_NAME download --format aax       # Download in AAX format with conversion
        $SCRIPT_NAME download --no-convert       # Download only, no conversion

CONVERT SUBCOMMAND:
    Convert existing AAX/AAXC files to split MP3 segments.
    
    Usage: $SCRIPT_NAME convert [OPTIONS] <input_file> [input_file2...]
    
    Options:
        --activation-bytes BYTES Activation bytes (auto-retrieved if not provided)
        --title TITLE           Override book title (default: extracted from file)
    
    Examples:
        $SCRIPT_NAME convert book.aaxc                           # Convert single file
        $SCRIPT_NAME convert *.aaxc                              # Convert multiple files
        $SCRIPT_NAME convert book.aax --title "My Book"          # Custom title
        $SCRIPT_NAME convert book.aax --duration 480             # 8-minute segments

AUTOMATE SUBCOMMAND:
    Full pipeline: download and convert audiobooks in one step.
    
    Usage: $SCRIPT_NAME automate [OPTIONS]
    
    Combines download and convert functionality with interactive selection.
    
    Examples:
        $SCRIPT_NAME automate                    # Full interactive pipeline
        $SCRIPT_NAME automate --profile work     # Use specific profile
        $SCRIPT_NAME automate --duration 480     # 8-minute segments

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
    Raw:       ~/Audiobooks/audible/raw/        (original AAX/AAXC files)
    Converted: ~/Audiobooks/audible/converted/  (M4B files with chapters)
    Output:    ~/Audiobooks/OpenSwim/           (final MP3 files)
               └── BookTitle/                   (one folder per book)
                   ├── booktitle_01.mp3
                   ├── booktitle_02.mp3
                   └── ...

EOF
}

show_download_help() {
    cat << EOF
Usage: $SCRIPT_NAME download [OPTIONS]

Download audiobooks from your Audible library with automatic conversion to M4B.

OPTIONS:
    -a, --all                Download all audiobooks from library
    -f, --format FORMAT      Download format: aaxc, aax, pdf (default: aaxc)
    --activation-bytes BYTES Activation bytes (auto-retrieved if not provided)
    --no-convert            Skip automatic conversion to M4B
    --force-refresh          Force refresh of library cache before download
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME download                    # Interactive selection with auto-conversion
    $SCRIPT_NAME download --all              # Download all audiobooks with conversion
    $SCRIPT_NAME download --format aax       # Download in AAX format with conversion
    $SCRIPT_NAME download --no-convert       # Download only, no conversion

NOTES:
    - Auto-conversion to M4B is enabled by default with chapter preservation
    - Use --no-convert to disable automatic conversion
    - Library cache is refreshed daily automatically
    - Use --force-refresh to force immediate cache refresh
EOF
}

show_convert_help() {
    cat << EOF
Usage: $SCRIPT_NAME convert [OPTIONS] [input_file] [input_file2...]

Convert existing AAX/AAXC files to M4B format with chapter preservation.

OPTIONS:
    --activation-bytes BYTES Activation bytes (auto-retrieved if not provided)
    --title TITLE           Override book title (default: extracted from file metadata)
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME convert                                      # Convert all unconverted files in raw directory
    $SCRIPT_NAME convert book.aaxc                           # Convert single file to M4B
    $SCRIPT_NAME convert *.aaxc                              # Convert multiple files to M4B
    $SCRIPT_NAME convert book.aax --title "My Book"          # Custom title

NOTES:
    - Converts AAX/AAXC files to M4B format only (no MP3 splitting)
    - If no input files specified, automatically finds unconverted files in raw directory
    - Skips files that already have corresponding M4B versions
    - Supports AAX and AAXC formats
    - Automatically preserves chapters and metadata
    - Activation bytes are auto-retrieved for AAX files
    - AAXC files don't require activation bytes
    - Use the 'split' subcommand to convert M4B files to MP3 segments
EOF
}

show_split_help() {
    cat << EOF
Usage: $SCRIPT_NAME split [OPTIONS] [input_file] [input_file2...]

Split M4B audiobook files into MP3 segments for MP3 player compatibility.

OPTIONS:
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME split                       # Split all M4B files in converted directory
    $SCRIPT_NAME split book.m4b              # Split single M4B file
    $SCRIPT_NAME split *.m4b                 # Split multiple M4B files

NOTES:
    - Uses the existing audiobook-split.sh script for MP3 segmentation
    - If no input files specified, automatically finds M4B files in converted directory
    - Default segment duration: 5 minutes (300 seconds)
    - Use global --duration option to change segment length
    - Output files saved to ~/Audiobooks/OpenSwim/ by default
    - Use global --output-dir option to change output location
EOF
}

show_automate_help() {
    cat << EOF
Usage: $SCRIPT_NAME automate [OPTIONS]

Full pipeline: download and convert audiobooks in one step.

Combines download and convert functionality with interactive selection.

OPTIONS:
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME automate                    # Full interactive pipeline
    $SCRIPT_NAME automate --profile work     # Use specific profile
    $SCRIPT_NAME automate --duration 480     # 8-minute segments

NOTES:
    - Uses interactive selection from your Audible library
    - Automatically converts downloaded files to M4B and then to MP3
    - Preserves chapters and metadata throughout the process
    - Creates final MP3 files in ~/Audiobooks/OpenSwim/
EOF
}

show_metadata_help() {
    cat << EOF
Usage: $SCRIPT_NAME metadata [OPTIONS] [directory]

Show file metadata (duration, size) for audio files in tree format.

OPTIONS:
    -h, --help               Show this help message

EXAMPLES:
    $SCRIPT_NAME metadata                           # Show metadata for converted directory
    $SCRIPT_NAME metadata ~/Audiobooks/OpenSwim     # Show metadata for specific directory
    $SCRIPT_NAME metadata ~/Audiobooks/audible/raw  # Show metadata for raw files

NOTES:
    - Supports M4B, M4A, MP3, AAX, and AAXC files
    - Shows duration in H:MM format and file size
    - Displays results in tree format with totals
    - Recursively scans subdirectories
    - Default directory: ~/Audiobooks/audible/converted/
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

get_system_info() {
    local detected_cores
    detected_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")
    
    local cpu_model=""
    local cpu_arch=""
    local total_memory=""
    
    if command -v lscpu &>/dev/null; then
        cpu_model=$(lscpu | grep "Model name" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        cpu_arch=$(lscpu | grep "Architecture" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    elif [ -f /proc/cpuinfo ]; then
        cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        cpu_arch=$(uname -m)
    fi
    
    if command -v free &>/dev/null; then
        total_memory=$(free -h | grep "^Mem:" | awk '{print $2}')
    elif command -v sysctl &>/dev/null; then
        total_memory=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)"G"}')
    fi
    
    echo "$detected_cores|$cpu_model|$cpu_arch|$total_memory"
}

calculate_optimal_threads() {
    local system_info
    system_info=$(get_system_info)
    
    local detected_cores cpu_model cpu_arch total_memory
    IFS='|' read -r detected_cores cpu_model cpu_arch total_memory <<< "$system_info"
    
    local cpu_count
    
    # Intelligent thread count based on system characteristics
    if [[ "$cpu_model" == *"AMD"* ]] && [[ "$cpu_model" == *"Ryzen"* ]] && [ "$detected_cores" -gt 16 ]; then
        # AMD Ryzen with many cores - use more threads
        cpu_count=$((detected_cores / 2))
    elif [[ "$cpu_model" == *"Intel"* ]] && [[ "$cpu_model" == *"Xeon"* ]] && [ "$detected_cores" -gt 12 ]; then
        # Intel Xeon - server grade, can handle more threads
        cpu_count=$((detected_cores / 2))
    elif [[ "$cpu_arch" == *"aarch64"* ]] || [[ "$cpu_arch" == *"arm64"* ]]; then
        # ARM processors (like Apple Silicon) - different threading characteristics
        cpu_count=$((detected_cores < 12 ? detected_cores : 12))
    elif [ "$detected_cores" -gt 8 ]; then
        # Generic cap for unknown processors
        cpu_count=8
    else
        cpu_count="$detected_cores"
    fi
    
    # Memory consideration - if low memory, reduce threads
    if [[ "$total_memory" =~ ^[0-9]+G$ ]]; then
        local memory_gb=${total_memory%G}
        if [ "$memory_gb" -lt 8 ] && [ "$cpu_count" -gt 4 ]; then
            cpu_count=4
        fi
    fi
    
    echo "$cpu_count|$cpu_model|$total_memory"
}

log_performance_info() {
    local thread_info
    thread_info=$(calculate_optimal_threads)
    
    local cpu_count cpu_model total_memory
    IFS='|' read -r cpu_count cpu_model total_memory <<< "$thread_info"
    
    if command -v gum &> /dev/null; then
        gum style --foreground 226 "⚡ Performance: Using $cpu_count threads | CPU: $cpu_model | RAM: $total_memory"
    else
        echo "PERFORMANCE: Using $cpu_count threads | CPU: $cpu_model | RAM: $total_memory"
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

get_cache_file() {
    local profile_suffix=""
    if [[ -n "$PROFILE" ]]; then
        profile_suffix="_${PROFILE}"
    fi
    echo "$CACHE_DIR/library${profile_suffix}.json"
}

is_cache_fresh() {
    local cache_file="$1"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    # Check if cache is less than 24 hours old
    local cache_age
    cache_age=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
    local current_time
    current_time=$(date +%s)
    local age_hours=$(((current_time - cache_age) / 3600))
    
    if [[ $age_hours -lt 24 ]]; then
        return 0
    else
        return 1
    fi
}

save_library_cache() {
    local library_data="$1"
    local cache_file="$2"
    
    mkdir -p "$CACHE_DIR"
    
    # Create a JSON structure with metadata
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Convert library data to JSON format
    local json_data
    json_data=$(echo "$library_data" | jq -R -s 'split("\n") | map(select(. != "")) | {"timestamp": "'$timestamp'", "profile": "'${PROFILE:-default}'", "books": .}')
    
    echo "$json_data" > "$cache_file"
    log_info "Library cache saved to $cache_file"
}

load_library_cache() {
    local cache_file="$1"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    # Extract the books array from JSON and convert back to text format
    jq -r '.books[]' "$cache_file" 2>/dev/null || return 1
}

get_library_list() {
    local cache_file
    cache_file=$(get_cache_file)
    
    # Check if we should use cache
    if [[ "$FORCE_REFRESH" != true ]] && is_cache_fresh "$cache_file"; then
        log_info "Using cached library data (cache age: $((($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)) / 3600)) hours)" >&2
        if load_library_cache "$cache_file"; then
            return 0
        else
            log_info "Cache corrupted, fetching fresh data..." >&2
        fi
    elif [[ "$FORCE_REFRESH" == true ]]; then
        log_info "Force refresh requested, fetching fresh library data..." >&2
    else
        log_info "Cache expired, fetching fresh library data..." >&2
    fi
    
    log_info "Fetching audiobook library..." >&2
    
    local cmd="uvx --from audible-cli audible"
    
    if [[ -n "$PROFILE" ]]; then
        cmd+=" -P $PROFILE"
    fi
    
    # Try different possible formats for the export command
    local export_formats=("library export --format json" "library export --format csv" "library export" "library list")
    
    for format in "${export_formats[@]}"; do
        local test_cmd="$cmd $format"
        log_info "Trying: $test_cmd" >&2
        
        local library_output
        if library_output=$(eval "$test_cmd" 2>/dev/null); then
            if [[ -n "$library_output" ]]; then
                # Check if it looks like JSON (starts with [ or {)
                if [[ "$library_output" =~ ^[[:space:]]*[\[{] ]]; then
                    save_library_cache "$library_output" "$cache_file"
                    echo "$library_output"
                    return 0
                elif [[ ! "$library_output" =~ (Usage:|Error:|Try) ]]; then
                    # If it's not JSON but we got valid output (not error messages)
                    log_info "Got non-JSON output, returning anyway" >&2
                    save_library_cache "$library_output" "$cache_file"
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
        clean_data=$(echo "$library_data" | grep -v -E "^(•|ℹ️|❌|✅|🔄|INFO:|ERROR:|SUCCESS:|Usage:|Try|Error:|Trying:|Command failed:|Fetching|Checking|Parsing|Got non-JSON|Select audiobooks)" | grep -v "^[[:space:]]*$" | grep -v "|[[:space:]]*unknown[[:space:]]*|[[:space:]]*unknown[[:space:]]*$")
        
        # Parse format: "ASIN: Author: Series: Title" or "ASIN: Author: Title"
        # Use a temporary array to collect and sort the results
        local -a parsed_books
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ -n "$line" && "$line" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
                local asin="${BASH_REMATCH[1]}"
                local rest="${BASH_REMATCH[2]}"
                
                # Split on first colon to get author, then use everything after as title
                if [[ "$rest" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
                    local author="${BASH_REMATCH[1]}"
                    local title="${BASH_REMATCH[2]}"
                    parsed_books+=("$title (by $author) | $asin | unknown")
                else
                    # If no second colon, treat entire rest as title
                    parsed_books+=("$rest | $asin | unknown")
                fi
            elif [[ -n "$line" ]]; then
                # Fallback for other formats
                parsed_books+=("$line | unknown | unknown")
            fi
        done <<< "$clean_data"
        
        # Sort the books alphabetically and output
        printf '%s\n' "${parsed_books[@]}" | sort
    fi
}

interactive_selection() {
    local library_list="$1"
    
    if [[ -z "$library_list" ]]; then
        log_error "No audiobooks found in library"
        exit 1
    fi
    
    # Check if we're in an interactive terminal
    if [[ ! -t 0 ]]; then
        log_error "Interactive selection requires stdin to be a terminal."
        log_info "Use --all flag for batch processing: $SCRIPT_NAME download --all"
        exit 1
    fi
    
    # Show instruction message to stderr to avoid interfering with gum
    echo "ℹ️  Select audiobooks to process (use space to select, enter to confirm, ctrl+c to cancel):" >&2
    
    # Use gum to create multi-select list
    local selected
    set +e  # Temporarily disable exit on error to handle gum cancellation
    selected=$(echo "$library_list" | gum choose --no-limit)
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
    
    mkdir -p "$RAW_DIR"
    cd "$RAW_DIR"
    
    # Store files before download to identify what was downloaded
    local files_before=()
    while IFS= read -r -d '' file; do
        files_before+=("$file")
    done < <(find . -maxdepth 1 -name "*.aax" -o -name "*.aaxc" -print0 2>/dev/null)
    
    if eval "$cmd"; then
        log_success "Downloaded: $asin"
        
        # Find the newly downloaded file
        local files_after=()
        while IFS= read -r -d '' file; do
            files_after+=("$file")
        done < <(find . -maxdepth 1 -name "*.aax" -o -name "*.aaxc" -print0 2>/dev/null)
        
        # Find the difference (new file)
        local new_files=()
        for file_after in "${files_after[@]}"; do
            local found=false
            for file_before in "${files_before[@]}"; do
                if [[ "$file_after" == "$file_before" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                new_files+=("$file_after")
            fi
        done
        
        # Return the path of the newly downloaded file
        if [[ ${#new_files[@]} -eq 1 ]]; then
            # Output the full path of the downloaded file to stdout
            echo "$RAW_DIR/${new_files[0]#./}"
        elif [[ ${#new_files[@]} -gt 1 ]]; then
            # Multiple files downloaded, return the first one
            echo "$RAW_DIR/${new_files[0]#./}"
        else
            # No new files detected, but download succeeded
            # This could happen if the file was already there but we didn't detect it
            # Try to find the most recently modified file that might be our download
            local latest_file
            latest_file=$(find "$RAW_DIR" -maxdepth 1 -type f \( -name "*.aax" -o -name "*.aaxc" \) -exec ls -t {} + 2>/dev/null | head -1)
            
            if [[ -n "$latest_file" && -f "$latest_file" ]]; then
                log_info "Using most recent file as download result: $(basename "$latest_file")"
                echo "$latest_file"
            else
                log_error "No audiobook files found after download"
                return 1
            fi
        fi
        
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
    
    log_step "Converting $(basename "$input_file") to M4B with chapter preservation"
    log_performance_info
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would convert $input_file to $output_file"
        return 0
    fi
    
    # Ensure output directory exists
    mkdir -p "$CONVERTED_DIR"
    
    # Get optimal thread count
    local thread_info
    thread_info=$(calculate_optimal_threads)
    local cpu_count
    cpu_count=$(echo "$thread_info" | cut -d'|' -f1)
    
    # Check if input file needs activation bytes (AAX format)
    local ffmpeg_exit_code
    if [[ "$input_file" == *.aax ]]; then
        if [[ -z "$activation_bytes" ]]; then
            log_error "Activation bytes required for AAX files"
            return 1
        fi
        set +e  # Temporarily disable exit on error for ffmpeg
        ffmpeg -y \
            -loglevel warning \
            -stats \
            -threads "$cpu_count" \
            -fflags +fastseek+genpts \
            -analyzeduration 1000000 \
            -probesize 1000000 \
            -thread_queue_size 512 \
            -activation_bytes "$activation_bytes" \
            -i "$input_file" \
            -c:v copy \
            -c:a copy \
            -f mp4 \
            -map_chapters 0 \
            -map_metadata 0 \
            -threads "$cpu_count" \
            "$output_file"
        ffmpeg_exit_code=$?
        set -e  # Re-enable exit on error
    else
        # AAXC files don't need activation bytes
        # Use error-tolerant settings to handle corrupted streams
        set +e  # Temporarily disable exit on error for ffmpeg
        ffmpeg -y \
            -loglevel warning \
            -stats \
            -threads "$cpu_count" \
            -fflags +fastseek+genpts+igndts \
            -analyzeduration 1000000 \
            -probesize 1000000 \
            -thread_queue_size 512 \
            -err_detect ignore_err \
            -i "$input_file" \
            -c:v copy \
            -c:a copy \
            -f mp4 \
            -map_chapters 0 \
            -map_metadata 0 \
            -ignore_unknown \
            -threads "$cpu_count" \
            "$output_file"
        ffmpeg_exit_code=$?
        set -e  # Re-enable exit on error
    fi
    
    if [[ $ffmpeg_exit_code -eq 0 ]]; then
        # Preserve timestamps from original file
        if command -v touch &>/dev/null; then
            touch -r "$input_file" "$output_file" 2>/dev/null || true
        fi
        
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

extract_title_from_file() {
    local file="$1"
    
    # Try to extract title from ffprobe metadata
    if command -v ffprobe &> /dev/null; then
        local title
        title=$(ffprobe -v quiet -show_entries format_tags=title -of csv=p=0 "$file" 2>/dev/null)
        if [[ -n "$title" ]]; then
            echo "$title"
            return 0
        fi
    fi
    
    # Fallback to filename without extension
    basename "$file" | sed 's/\.[^.]*$//'
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
    
    # Use the existing audiobook-split.sh script with correct argument order
    "$SCRIPT_DIR/audiobook-split.sh" "$m4b_file" "$SEGMENT_DURATION" --output-dir "$book_output_dir"
    
    local split_exit_code=$?
    if [[ $split_exit_code -eq 0 ]]; then
        log_success "Split complete: $book_output_dir"
        return 0
    else
        log_error "Failed to split: $(basename "$m4b_file") (exit code: $split_exit_code)"
        return 1
    fi
}

cleanup_intermediate_files() {
    local keep_files="$1"
    
    if [[ "$keep_files" == true ]]; then
        log_info "Keeping intermediate files in $RAW_DIR and $CONVERTED_DIR"
        return
    fi
    
    log_info "Cleaning up intermediate files..."
    
    # Only clean up the M4B files, keep the raw downloads
    find "$CONVERTED_DIR" -name "*.m4b" 2>/dev/null | while read -r file; do
        if [[ "$DRY_RUN" == true ]]; then
            log_info "DRY RUN: Would remove $file"
        else
            rm -f "$file"
        fi
    done
}

# Subcommand implementations

cmd_download() {
    local download_all=false
    local download_format="aaxc"
    local auto_convert=true
    
    # Parse download-specific arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_download_help
                exit 0
                ;;
            -a|--all)
                download_all=true
                shift
                ;;
            -f|--format)
                download_format="$2"
                shift 2
                ;;
            --activation-bytes)
                ACTIVATION_BYTES="$2"
                shift 2
                ;;
            --no-convert)
                auto_convert=false
                shift
                ;;
            --force-refresh)
                FORCE_REFRESH=true
                shift
                ;;
            *)
                log_error "Unknown download option: $1"
                exit 1
                ;;
        esac
    done
    
    log_step "Download Mode: Getting audiobooks from Audible"
    
    # Get library and selection
    local library_json
    library_json=$(get_library_list)
    
    local library_list
    library_list=$(parse_library_for_selection "$library_json")
    
    # Show how many books were fetched
    local book_count
    book_count=$(echo "$library_list" | wc -l)
    log_info "Successfully fetched $book_count audiobooks from library"
    
    local selected_books
    if [[ "$download_all" == true ]]; then
        selected_books="$library_list"
        log_info "Downloading all $book_count audiobooks"
    else
        selected_books=$(interactive_selection "$library_list")
    fi
    
    if [[ -z "$selected_books" ]]; then
        log_info "No books selected, exiting"
        exit 0
    fi
    
    # Show selection count
    local selected_count
    selected_count=$(echo "$selected_books" | wc -l)
    log_info "Selected $selected_count audiobook(s) for download"
    
    # Get activation bytes if auto-conversion is enabled
    local activation_bytes=""
    if [[ "$auto_convert" == true ]]; then
        activation_bytes=$(get_activation_bytes)
    fi
    
    # Download each selected book
    local downloaded_count=0
    local converted_count=0
    local failed_count=0
    
    while IFS= read -r book_line; do
        if [[ -z "$book_line" ]]; then continue; fi
        
        # Parse the selection line: "title | asin | format"
        local title asin format
        title=$(echo "$book_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        asin=$(echo "$book_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        format=$(echo "$book_line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Use user-specified format if provided, otherwise use detected format
        if [[ "$download_format" != "aaxc" ]]; then
            format="$download_format"
        fi
        
        log_step "Processing: $title ($asin) [$format]"
        
        # Check if file already exists in raw directory
        # Try multiple approaches to find existing file
        local existing_file
        # First try by ASIN
        existing_file=$(find "$RAW_DIR" -name "*$asin*" -type f \( -name "*.aax" -o -name "*.aaxc" \) | head -1)
        
        # If not found by ASIN, try by title (sanitized)
        if [[ -z "$existing_file" ]]; then
            local sanitized_title
            sanitized_title=$(echo "$title" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
            existing_file=$(find "$RAW_DIR" -iname "*$sanitized_title*" -type f \( -name "*.aax" -o -name "*.aaxc" \) | head -1)
        fi
        
        # If still not found, try partial title matching
        if [[ -z "$existing_file" ]]; then
            local title_words
            title_words=$(echo "$title" | tr ' ' '\n' | head -3 | tr '\n' ' ')
            for word in $title_words; do
                if [[ ${#word} -gt 3 ]]; then  # Only use words longer than 3 characters
                    existing_file=$(find "$RAW_DIR" -iname "*$word*" -type f \( -name "*.aax" -o -name "*.aaxc" \) | head -1)
                    if [[ -n "$existing_file" ]]; then
                        break
                    fi
                fi
            done
        fi
        
        local downloaded_file=""
        local actually_downloaded=false
        
        if [[ -n "$existing_file" && -f "$existing_file" ]]; then
            log_info "File already downloaded: $(basename "$existing_file")"
            downloaded_file="$existing_file"
        else
            # File doesn't exist, download it
            log_info "Downloading: $title ($asin) [$format]"
            downloaded_file=$(download_audiobook "$asin" "$format")
            local download_exit_code=$?
            
            if [[ $download_exit_code -eq 0 ]]; then
                if [[ -n "$downloaded_file" && -f "$downloaded_file" ]]; then
                    downloaded_count=$((downloaded_count + 1))
                    actually_downloaded=true
                    log_success "Downloaded: $title"
                else
                    log_error "Download succeeded but file not found: $title"
                    downloaded_file=""
                fi
            else
                failed_count=$((failed_count + 1))
                log_error "Failed to download: $title"
                downloaded_file=""
            fi
        fi
        
        # Auto-convert if enabled and we have a valid file
        if [[ "$auto_convert" == true && -n "$downloaded_file" && -f "$downloaded_file" ]]; then
            # Check if M4B already exists
            local m4b_file="$CONVERTED_DIR/$(basename "${downloaded_file%.*}").m4b"
            
            if [[ -f "$m4b_file" ]]; then
                log_info "M4B already exists: $(basename "$m4b_file")"
                log_success "Conversion up to date: $title"
            else
                log_info "Auto-converting $(if [[ "$actually_downloaded" == true ]]; then echo "downloaded"; else echo "existing"; fi) file: $(basename "$downloaded_file")"
                if convert_to_m4b "$downloaded_file" "$m4b_file" "$activation_bytes"; then
                    converted_count=$((converted_count + 1))
                    log_success "Converted: $title"
                else
                    log_error "Failed to convert: $title"
                fi
            fi
        fi
        
    done <<< "$selected_books"
    
    # Summary
    log_success "Processing complete!"
    if [[ $downloaded_count -gt 0 ]]; then
        log_info "Newly downloaded: $downloaded_count audiobook(s)"
    fi
    if [[ "$auto_convert" == true ]]; then
        log_info "Successfully converted: $converted_count audiobook(s)"
    fi
    if [[ $failed_count -gt 0 ]]; then
        log_error "Failed to process: $failed_count audiobook(s)"
    fi
    log_info "Raw files in: $RAW_DIR"
    if [[ "$auto_convert" == true ]]; then
        log_info "Converted files in: $CONVERTED_DIR"
    fi
}

cmd_convert() {
    local input_files=()
    local custom_title=""
    
    # Parse convert-specific arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_convert_help
                exit 0
                ;;
            --activation-bytes)
                ACTIVATION_BYTES="$2"
                shift 2
                ;;
            --title)
                custom_title="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown convert option: $1"
                exit 1
                ;;
            *)
                input_files+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ ${#input_files[@]} -eq 0 ]]; then
        log_info "No input files specified, scanning raw directory for unconverted files..."
        
        # Find all AAX/AAXC files in the raw directory
        local raw_files=()
        while IFS= read -r -d '' file; do
            raw_files+=("$file")
        done < <(find "$RAW_DIR" -type f \( -name "*.aax" -o -name "*.aaxc" \) -print0 2>/dev/null)
        
        if [[ ${#raw_files[@]} -eq 0 ]]; then
            log_error "No AAX/AAXC files found in raw directory: $RAW_DIR"
            exit 1
        fi
        
        log_info "Found ${#raw_files[@]} raw file(s) in $RAW_DIR"
        
        # Filter out files that already have M4B versions
        local unconverted_files=()
        for raw_file in "${raw_files[@]}"; do
            local m4b_file="$CONVERTED_DIR/$(basename "${raw_file%.*}").m4b"
            if [[ ! -f "$m4b_file" ]]; then
                unconverted_files+=("$raw_file")
            else
                log_info "Skipping $(basename "$raw_file") - M4B already exists"
            fi
        done
        
        if [[ ${#unconverted_files[@]} -eq 0 ]]; then
            log_success "All files in raw directory have already been converted to M4B"
            log_info "Converted files location: $CONVERTED_DIR"
            exit 0
        fi
        
        input_files=("${unconverted_files[@]}")
        log_info "Found ${#input_files[@]} file(s) that need conversion"
    fi
    
    # Get activation bytes if needed
    local activation_bytes
    activation_bytes=$(get_activation_bytes)
    
    log_step "Convert Mode: Processing ${#input_files[@]} file(s)"
    
    local converted_count=0
    local failed_count=0
    
    for input_file in "${input_files[@]}"; do
        if [[ ! -f "$input_file" ]]; then
            log_error "Input file not found: $input_file"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Validate file format
        if [[ ! "$input_file" =~ \.(aax|aaxc)$ ]]; then
            log_error "Unsupported file format: $input_file (only .aax and .aaxc supported)"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Extract or use custom title
        local book_title
        if [[ -n "$custom_title" ]]; then
            book_title="$custom_title"
        else
            book_title=$(extract_title_from_file "$input_file")
        fi
        
        log_step "Processing: $book_title ($(basename "$input_file"))"
        
        # Convert to M4B
        local m4b_file="$CONVERTED_DIR/$(basename "${input_file%.*}").m4b"
        if convert_to_m4b "$input_file" "$m4b_file" "$activation_bytes"; then
            converted_count=$((converted_count + 1))
            log_success "Converted: $book_title"
        else
            log_error "Failed to convert: $(basename "$input_file")"
            failed_count=$((failed_count + 1))
        fi
        
    done
    
    # Summary
    log_success "Conversion complete!"
    log_info "Successfully converted: $converted_count audiobook(s)"
    if [[ $failed_count -gt 0 ]]; then
        log_error "Failed to convert: $failed_count audiobook(s)"
    fi
    log_info "Output directory: $OUTPUT_DIR"
}

cmd_automate() {
    # Parse automate-specific arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_automate_help
                exit 0
                ;;
            *)
                log_error "Unknown automate option: $1"
                exit 1
                ;;
        esac
    done
    
    log_step "Automate Mode: Full download and convert pipeline"
    
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
        title=$(echo "$book_line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        asin=$(echo "$book_line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        format=$(echo "$book_line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        log_step "Processing: $title ($asin)"
        
        # Download
        if ! download_audiobook "$asin" "$format"; then
            log_error "Failed to download: $title"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Find downloaded file
        local downloaded_file
        downloaded_file=$(find "$RAW_DIR" -name "*.aax" -o -name "*.aaxc" | grep -v ".tmp" | tail -1)
        
        if [[ -z "$downloaded_file" ]]; then
            log_error "Downloaded file not found for: $title"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Convert to M4B
        local m4b_file="$CONVERTED_DIR/$(basename "${downloaded_file%.*}").m4b"
        if ! convert_to_m4b "$downloaded_file" "$m4b_file" "$activation_bytes"; then
            log_error "Failed to convert: $title"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Split to MP3
        if ! split_to_mp3 "$m4b_file" "$title"; then
            log_error "Failed to split: $title"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        processed_count=$((processed_count + 1))
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

cmd_split() {
    local input_files=()
    
    # Parse split-specific arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_split_help
                exit 0
                ;;
            -*)
                log_error "Unknown split option: $1"
                exit 1
                ;;
            *)
                input_files+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ ${#input_files[@]} -eq 0 ]]; then
        log_info "No input files specified, scanning converted directory for M4B files..."
        
        # Find all M4B files in the converted directory
        local m4b_files=()
        while IFS= read -r -d '' file; do
            m4b_files+=("$file")
        done < <(find "$CONVERTED_DIR" -type f -name "*.m4b" -print0 2>/dev/null)
        
        if [[ ${#m4b_files[@]} -eq 0 ]]; then
            log_error "No M4B files found in converted directory: $CONVERTED_DIR"
            exit 1
        fi
        
        input_files=("${m4b_files[@]}")
        log_info "Found ${#input_files[@]} M4B file(s) to split"
    fi
    
    log_step "Split Mode: Processing ${#input_files[@]} file(s)"
    
    local split_count=0
    local failed_count=0
    
    for input_file in "${input_files[@]}"; do
        if [[ ! -f "$input_file" ]]; then
            log_error "Input file not found: $input_file"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Check if it's an M4B file
        if [[ "${input_file,,}" != *.m4b ]]; then
            log_error "Unsupported file format: $input_file (only .m4b supported)"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Extract title from filename
        local book_title
        book_title=$(basename "${input_file%.*}")
        
        log_step "Processing: $book_title ($(basename "$input_file"))"
        
        # Create output directory based on book title
        local sanitized_title
        sanitized_title=$(sanitize_filename "$book_title")
        local book_output_dir="$OUTPUT_DIR/$sanitized_title"
        
        # Use audiobook-split.sh to split the file
        if [[ "$DRY_RUN" == true ]]; then
            log_info "DRY RUN: Would split $input_file into $book_output_dir"
            log_info "DRY RUN: Would execute: $SCRIPT_DIR/audiobook-split.sh \"$input_file\" \"$SEGMENT_DURATION\" --output-dir \"$book_output_dir\""
            split_count=$((split_count + 1))
        else
            if "$SCRIPT_DIR/audiobook-split.sh" "$input_file" "$SEGMENT_DURATION" --output-dir "$book_output_dir"; then
                log_success "Split complete: $book_title"
                split_count=$((split_count + 1))
            else
                log_error "Failed to split: $(basename "$input_file")"
                failed_count=$((failed_count + 1))
            fi
        fi
    done
    
    # Summary
    log_success "Split complete!"
    log_info "Successfully split: $split_count audiobook(s)"
    if [[ $failed_count -gt 0 ]]; then
        log_error "Failed to split: $failed_count audiobook(s)"
    fi
    log_info "Output directory: $OUTPUT_DIR"
}

format_duration() {
    local seconds="$1"
    if [[ -z "$seconds" || "$seconds" == "N/A" ]]; then
        echo "N/A"
        return
    fi
    
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%d:%02d" "$hours" "$minutes"
    else
        printf "0:%02d" "$minutes"
    fi
}

format_size() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0B"
        return
    fi
    
    local units=("B" "KB" "MB" "GB" "TB")
    local unit_index=0
    local size="$bytes"
    
    while [[ $size -gt 1024 && $unit_index -lt 4 ]]; do
        size=$((size / 1024))
        unit_index=$((unit_index + 1))
    done
    
    printf "%d%s" "$size" "${units[$unit_index]}"
}

get_audio_metadata() {
    local file="$1"
    local duration size
    
    # Get duration using ffprobe
    duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1)
    
    # Get file size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
    
    echo "$duration|$size"
}

cmd_metadata() {
    local target_dir="$CONVERTED_DIR"
    
    # Parse metadata-specific arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_metadata_help
                exit 0
                ;;
            -*)
                log_error "Unknown metadata option: $1"
                exit 1
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done
    
    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory not found: $target_dir"
        exit 1
    fi
    
    log_step "Metadata Analysis: $target_dir"
    
    # Find all audio files
    local audio_files=()
    while IFS= read -r -d '' file; do
        audio_files+=("$file")
    done < <(find "$target_dir" -type f \( -name "*.m4b" -o -name "*.m4a" -o -name "*.mp3" -o -name "*.aax" -o -name "*.aaxc" \) -print0 2>/dev/null)
    
    if [[ ${#audio_files[@]} -eq 0 ]]; then
        log_error "No audio files found in $target_dir"
        exit 1
    fi
    
    log_info "Found ${#audio_files[@]} audio file(s)"
    
    # Build directory structure
    declare -A dir_structure
    declare -A file_metadata
    local total_duration=0
    local total_size=0
    
    for file in "${audio_files[@]}"; do
        local rel_path="${file#$target_dir/}"
        local dir_path=$(dirname "$rel_path")
        local filename=$(basename "$file")
        
        # Get metadata
        local metadata
        metadata=$(get_audio_metadata "$file")
        local duration=$(echo "$metadata" | cut -d'|' -f1)
        local size=$(echo "$metadata" | cut -d'|' -f2)
        
        # Store metadata
        file_metadata["$rel_path"]="$duration|$size"
        
        # Add to totals
        if [[ -n "$duration" && "$duration" != "N/A" ]]; then
            total_duration=$((total_duration + duration))
        fi
        if [[ -n "$size" && "$size" != "0" ]]; then
            total_size=$((total_size + size))
        fi
        
        # Add to directory structure
        if [[ "$dir_path" == "." ]]; then
            dir_structure["ROOT"]+="$filename|"
        else
            dir_structure["$dir_path"]+="$filename|"
        fi
    done
    
    # Display tree structure
    echo
    if command -v gum &> /dev/null; then
        gum style --foreground 46 --bold "📁 $(basename "$target_dir")"
    else
        echo "📁 $(basename "$target_dir")"
    fi
    echo
    
    # Sort directories and files
    local sorted_dirs=()
    while IFS= read -r dir; do
        sorted_dirs+=("$dir")
    done < <(printf '%s\n' "${!dir_structure[@]}" | sort)
    
    for dir in "${sorted_dirs[@]}"; do
        if [[ "$dir" == "ROOT" ]]; then
            # Root level files
            local files_str="${dir_structure[$dir]}"
            IFS='|' read -ra files <<< "$files_str"
            for file in "${files[@]}"; do
                if [[ -n "$file" ]]; then
                    local metadata="${file_metadata[$file]}"
                    local duration=$(echo "$metadata" | cut -d'|' -f1)
                    local size=$(echo "$metadata" | cut -d'|' -f2)
                    
                    local formatted_duration=$(format_duration "$duration")
                    local formatted_size=$(format_size "$size")
                    
                    printf "├── %s\n" "$file"
                    printf "│   └── Duration: %s  │  Size: %s\n" "$formatted_duration" "$formatted_size"
                fi
            done
        else
            # Directory with files
            printf "├── 📁 %s/\n" "$dir"
            local files_str="${dir_structure[$dir]}"
            IFS='|' read -ra files <<< "$files_str"
            for file in "${files[@]}"; do
                if [[ -n "$file" ]]; then
                    local rel_path="$dir/$file"
                    local metadata="${file_metadata[$rel_path]}"
                    local duration=$(echo "$metadata" | cut -d'|' -f1)
                    local size=$(echo "$metadata" | cut -d'|' -f2)
                    
                    local formatted_duration=$(format_duration "$duration")
                    local formatted_size=$(format_size "$size")
                    
                    printf "│   ├── %s\n" "$file"
                    printf "│   │   └── Duration: %s  │  Size: %s\n" "$formatted_duration" "$formatted_size"
                fi
            done
        fi
    done
    
    # Display totals
    echo "└──────────────────────────────────────────────────────────────────────"
    local formatted_total_duration=$(format_duration "$total_duration")
    local formatted_total_size=$(format_size "$total_size")
    
    if command -v gum &> /dev/null; then
        gum style --foreground 226 --bold "📊 Total: ${#audio_files[@]} files  │  Duration: $formatted_total_duration  │  Size: $formatted_total_size"
    else
        printf "📊 Total: %d files  │  Duration: %s  │  Size: %s\n" "${#audio_files[@]}" "$formatted_total_duration" "$formatted_total_size"
    fi
    
    echo
}

parse_global_arguments() {
    local subcommand=""
    local global_args=()
    local subcommand_args=()
    local found_subcommand=false
    
    # First pass: separate global args from subcommand and its args
    while [[ $# -gt 0 ]]; do
        case $1 in
            download|convert|split|automate|metadata)
                subcommand="$1"
                found_subcommand=true
                shift
                break
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -p|--profile)
                PROFILE="$2"
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
                RAW_DIR="$2/raw"
                CONVERTED_DIR="$2/converted"
                shift 2
                ;;
            -r|--raw-dir)
                RAW_DIR="$2"
                shift 2
                ;;
            -c|--converted-dir)
                CONVERTED_DIR="$2"
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
            --force-refresh)
                FORCE_REFRESH=true
                shift
                ;;
            *)
                log_error "Unknown global option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Collect remaining args as subcommand args
    subcommand_args=("$@")
    
    if [[ -z "$subcommand" ]]; then
        log_error "No subcommand specified"
        show_help
        exit 1
    fi
    
    # Execute the subcommand
    case "$subcommand" in
        download)
            cmd_download "${subcommand_args[@]}"
            ;;
        convert)
            cmd_convert "${subcommand_args[@]}"
            ;;
        split)
            cmd_split "${subcommand_args[@]}"
            ;;
        automate)
            cmd_automate "${subcommand_args[@]}"
            ;;
        metadata)
            cmd_metadata "${subcommand_args[@]}"
            ;;
        *)
            log_error "Unknown subcommand: $subcommand"
            show_help
            exit 1
            ;;
    esac
}

main() {
    check_dependencies
    parse_global_arguments "$@"
}

main "$@"