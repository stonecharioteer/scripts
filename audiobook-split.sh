#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_SEGMENT_DURATION=300

show_help() {
    gum style --foreground="#04B575" --bold "📚 Audiobook Splitter"
    echo
    gum style --foreground="#7C3AED" "Split audiobooks into smaller segments using ffmpeg's segment muxer"
    echo
    gum style --bold "Usage:"
    echo "  $SCRIPT_NAME <audiobook_file> [segment_duration_in_seconds] [options]"
    echo
    gum style --bold "Arguments:"
    echo "  audiobook_file           Path to the audiobook file (m4a, m4b, or mp3)"
    echo "  segment_duration         Duration of each segment in seconds (default: 300 = 5 minutes)"
    echo
    gum style --bold "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -O, --output-dir DIR    Output directory (default: {filename}_segments)"
    echo
    gum style --bold "Examples:"
    echo "  $SCRIPT_NAME audiobook.m4a"
    echo "  $SCRIPT_NAME audiobook.m4b 600"
    echo "  $SCRIPT_NAME audiobook.mp3 480 -O /media/usb/audiobooks"
    echo
    gum style --foreground="#F59E0B" "Note: Requires ffmpeg to be installed"
    gum style --foreground="#6B7280" "Filenames are sanitized for FAT32 compatibility"
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v ffmpeg &> /dev/null; then
        missing_deps+=("ffmpeg")
    fi
    
    if ! command -v gum &> /dev/null; then
        missing_deps+=("gum")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        gum style --foreground="#DC2626" --bold "❌ Missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

validate_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        gum style --foreground="#DC2626" "❌ File not found: $file"
        exit 1
    fi
    
    local extension="${file##*.}"
    extension="${extension,,}"
    
    case "$extension" in
        m4a|m4b|mp3)
            return 0
            ;;
        *)
            gum style --foreground="#DC2626" "❌ Unsupported file format: .$extension"
            gum style --foreground="#6B7280" "Supported formats: m4a, m4b, mp3"
            exit 1
            ;;
    esac
}

validate_duration() {
    local duration="$1"
    
    if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -le 0 ]; then
        gum style --foreground="#DC2626" "❌ Invalid segment duration: $duration"
        gum style --foreground="#6B7280" "Duration must be a positive integer (seconds)"
        exit 1
    fi
}

format_time() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ "$hours" -gt 0 ]; then
        printf "%02d:%02d:%02d" "$hours" "$minutes" "$secs"
    else
        printf "%02d:%02d" "$minutes" "$secs"
    fi
}

format_size() {
    local bytes="$1"
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))KB"
    else
        echo "$((bytes / 1048576))MB"
    fi
}

analyze_output_files() {
    local output_dir="$1"
    local file_prefix="$2"
    local expected_duration="$3"
    
    gum style --foreground="#8B5CF6" --bold "📊 Analyzing output files..."
    echo
    
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$output_dir" -name "${file_prefix}_*.mp3" -print0 | sort -z)
    
    if [ ${#files[@]} -eq 0 ]; then
        gum style --foreground="#DC2626" "❌ No output files found!"
        return 1
    fi
    
    # Collect file data
    local total_size=0
    local normal_duration_count=0
    local outliers=()
    local tolerance=$((expected_duration / 10))  # 10% tolerance
    
    # Create temporary file for table data
    local table_data="/tmp/audiobook_summary_$$"
    echo "Category,Count,Duration Range,Size Range" > "$table_data"
    
    local min_duration=999999
    local max_duration=0
    local min_size=999999999
    local max_size=0
    
    for file in "${files[@]}"; do
        local duration
        duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1)
        local size
        size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
        
        total_size=$((total_size + size))
        
        # Track min/max
        if [ "$duration" -lt "$min_duration" ]; then min_duration="$duration"; fi
        if [ "$duration" -gt "$max_duration" ]; then max_duration="$duration"; fi
        if [ "$size" -lt "$min_size" ]; then min_size="$size"; fi
        if [ "$size" -gt "$max_size" ]; then max_size="$size"; fi
        
        # Check if duration is within tolerance
        local diff=$((duration - expected_duration))
        if [ "$diff" -lt 0 ]; then diff=$((-diff)); fi
        
        if [ "$diff" -le "$tolerance" ]; then
            normal_duration_count=$((normal_duration_count + 1))
        else
            outliers+=("$(basename "$file"):$(format_time "$duration"):$(format_size "$size")")
        fi
    done
    
    # Add data to table
    {
        echo "Normal Files,$normal_duration_count,~$(format_time "$expected_duration"),$(format_size "$min_size")-$(format_size "$max_size")"
        echo "Outliers,${#outliers[@]},$(format_time "$min_duration")-$(format_time "$max_duration"),Varies"
        echo "Total Files,${#files[@]},$(format_time "$min_duration")-$(format_time "$max_duration"),$(format_size "$total_size")"
    } >> "$table_data"
    
    # Display summary with gum format instead of interactive table
    gum style --foreground="#06B6D4" --bold "📋 File Summary:"
    echo
    gum style --foreground="#10B981" "  Normal Files: $normal_duration_count (within 10% of $(format_time "$expected_duration"))"
    gum style --foreground="#F59E0B" "  Outliers: ${#outliers[@]} (duration deviation >10%)"
    gum style --foreground="#8B5CF6" "  Total Files: ${#files[@]}"
    gum style --foreground="#6B7280" "  Size Range: $(format_size "$min_size") - $(format_size "$max_size")"
    gum style --foreground="#6B7280" "  Duration Range: $(format_time "$min_duration") - $(format_time "$max_duration")"
    
    # Show outliers if any
    if [ ${#outliers[@]} -gt 0 ]; then
        echo
        gum style --foreground="#F59E0B" --bold "⚠️  Duration Outliers (>10% deviation):"
        for outlier in "${outliers[@]}"; do
            local filename
            local duration
            local size
            filename=$(echo "$outlier" | cut -d: -f1)
            duration=$(echo "$outlier" | cut -d: -f2)
            size=$(echo "$outlier" | cut -d: -f3)
            gum style --foreground="#F59E0B" "    $filename: $duration ($size)"
        done
    fi
    
    # Cleanup
    rm -f "$table_data"
    
    echo
    gum style --foreground="#10B981" "✨ Analysis complete! Total size: $(format_size "$total_size")"
}

get_duration() {
    local file="$1"
    
    ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1
}

split_audiobook() {
    local input_file="$1"
    local segment_duration="$2"
    local custom_output_dir="$3"
    
    gum style --foreground="#04B575" --bold "🎵 Processing audiobook: $(basename "$input_file")"
    
    local total_duration
    total_duration=$(get_duration "$input_file")
    
    if [ -z "$total_duration" ] || [ "$total_duration" -eq 0 ]; then
        gum style --foreground="#DC2626" "❌ Could not determine file duration"
        exit 1
    fi
    
    local total_segments=$(((total_duration + segment_duration - 1) / segment_duration))
    
    # Calculate minimum digits needed for numbering
    local digit_count
    if [[ "$total_segments" -lt 10 ]]; then
        digit_count=2
    elif [[ "$total_segments" -lt 100 ]]; then
        digit_count=2
    elif [[ "$total_segments" -lt 1000 ]]; then
        digit_count=3
    else
        digit_count=4
    fi
    
    gum style --foreground="#7C3AED" "📊 Total duration: $(format_time "$total_duration")"
    gum style --foreground="#7C3AED" "⏱️  Segment duration: $(format_time "$segment_duration")"
    gum style --foreground="#7C3AED" "📦 Estimated segments: $total_segments (${digit_count}-digit numbering)"
    echo
    
    local base_name
    base_name=$(sanitize_filename "$(basename "${input_file%.*}")")
    
    local output_dir
    local file_prefix
    if [[ -n "$custom_output_dir" ]]; then
        output_dir="$custom_output_dir"
        # Use the last part of the output directory path as prefix
        file_prefix=$(sanitize_filename "$(basename "$custom_output_dir")")
    else
        output_dir="${base_name}_segments"
        file_prefix="$base_name"
    fi
    
    mkdir -p "$output_dir"
    
    # Detect system info for optimal threading decisions
    local cpu_count
    local detected_cores
    detected_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")
    
    # Collect system information
    local cpu_model=""
    local cpu_arch=""
    local total_memory=""
    
    if command -v lscpu &>/dev/null; then
        cpu_model=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
        cpu_arch=$(lscpu | grep "Architecture" | cut -d: -f2 | xargs)
    elif [ -f /proc/cpuinfo ]; then
        cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        cpu_arch=$(uname -m)
    fi
    
    if command -v free &>/dev/null; then
        total_memory=$(free -h | grep "^Mem:" | awk '{print $2}')
    elif command -v sysctl &>/dev/null; then
        total_memory=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)"G"}')
    fi
    
    # Intelligent thread count based on system characteristics
    if [[ "$cpu_model" == *"AMD"* ]] && [[ "$cpu_model" == *"Ryzen"* ]] && [ "$detected_cores" -gt 16 ]; then
        # AMD Ryzen with many cores - use more threads (good for parallel workloads)
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
    
    gum style --foreground="#F59E0B" "📁 Output directory: $output_dir"
    gum style --foreground="#06B6D4" "🔄 Splitting audiobook using ffmpeg segment muxer..."
    
    # Display system-aware performance info
    local perf_msg="⚡ Performance: Using $cpu_count/$detected_cores threads"
    if [[ -n "$cpu_model" ]]; then
        perf_msg="$perf_msg ($cpu_model)"
    fi
    if [[ -n "$total_memory" ]]; then
        perf_msg="$perf_msg | RAM: $total_memory"
    fi
    gum style --foreground="#8B5CF6" "$perf_msg"
    echo
    
    # Use ffmpeg's segment muxer for efficient splitting with progress
    local segment_pattern="$output_dir/${file_prefix}_%0${digit_count}d.mp3"
    local progress_file="/tmp/ffmpeg_progress_$$"
    
    # Start ffmpeg in background with progress reporting and performance optimizations
    ffmpeg -y \
        -threads "$cpu_count" \
        -fflags +fastseek+genpts \
        -analyzeduration 1000000 \
        -probesize 1000000 \
        -thread_queue_size 512 \
        -i "$input_file" \
        -f segment \
        -segment_time "$segment_duration" \
        -segment_start_number 1 \
        -c:a libmp3lame \
        -b:a 128k \
        -q:a 2 \
        -joint_stereo 1 \
        -threads "$cpu_count" \
        -avoid_negative_ts make_zero \
        -reset_timestamps 1 \
        -progress "$progress_file" \
        "$segment_pattern" 2>/dev/null &
    
    local ffmpeg_pid=$!
    
    # Check if gum supports progress command
    if gum progress --help &>/dev/null; then
        # Use gum progress bar for newer versions
        {
            while kill -0 "$ffmpeg_pid" 2>/dev/null; do
                if [[ -f "$progress_file" ]]; then
                    local current_time_us
                    current_time_us=$(grep "^out_time_us=" "$progress_file" | tail -1 | cut -d= -f2)
                    
                    if [[ -n "$current_time_us" && "$current_time_us" != "N/A" && "$current_time_us" -gt 0 ]]; then
                        local current_seconds=$((current_time_us / 1000000))
                        local progress_percent=$((current_seconds * 100 / total_duration))
                        
                        if [[ "$progress_percent" -le 100 ]]; then
                            echo "$progress_percent"
                        fi
                    fi
                fi
                sleep 0.5
            done
            echo "100"  # Ensure we reach 100% at the end
        } | gum progress --title "🔄 Splitting audiobook..." --color="#06B6D4"
    else
        # Fallback to styled text progress for older gum versions
        local last_percent=-1
        local start_time
        start_time=$(date +%s)
        while kill -0 "$ffmpeg_pid" 2>/dev/null; do
            if [[ -f "$progress_file" ]]; then
                local current_time_us
                current_time_us=$(grep "^out_time_us=" "$progress_file" | tail -1 | cut -d= -f2)
                
                if [[ -n "$current_time_us" && "$current_time_us" != "N/A" && "$current_time_us" -gt 0 ]]; then
                    local current_seconds=$((current_time_us / 1000000))
                    local progress_percent=$((current_seconds * 100 / total_duration))
                    
                    if [[ "$progress_percent" -le 100 && "$progress_percent" != "$last_percent" ]]; then
                        local now
                        now=$(date +%s)
                        local elapsed=$((now - start_time))
                        
                        local eta_seconds=""
                        if [[ "$progress_percent" -gt 0 ]]; then
                            local total_estimated=$((elapsed * 100 / progress_percent))
                            local remaining=$((total_estimated - elapsed))
                            eta_seconds=" | ETA: $(format_time "$remaining")"
                        fi
                        
                        printf "\r\033[K🔄 %s%% (%s / %s) | Elapsed: %s%s" \
                            "$progress_percent" \
                            "$(format_time "$current_seconds")" \
                            "$(format_time "$total_duration")" \
                            "$(format_time "$elapsed")" \
                            "$eta_seconds"
                        last_percent="$progress_percent"
                    fi
                fi
            fi
            sleep 0.5
        done
        local final_time
        final_time=$(date +%s)
        local total_elapsed=$((final_time - start_time))
        printf "\r\033[K✅ Complete: 100%% (%s / %s) | Total time: %s\n" \
            "$(format_time "$total_duration")" \
            "$(format_time "$total_duration")" \
            "$(format_time "$total_elapsed")"
    fi
    
    # Wait for ffmpeg to complete and check exit status
    if ! wait "$ffmpeg_pid"; then
        rm -f "$progress_file"
        echo
        gum style --foreground="#DC2626" "❌ Failed to split audiobook"
        exit 1
    fi
    
    # Clean up progress file
    rm -f "$progress_file"
    
    # Count actual segments created
    local actual_segments
    actual_segments=$(find "$output_dir" -name "${file_prefix}_*.mp3" | wc -l)
    
    echo
    gum style --foreground="#10B981" --bold "✅ Successfully split audiobook into $actual_segments segments"
    gum style --foreground="#6B7280" "Output location: $output_dir"
    gum style --foreground="#6B7280" "Used ffmpeg's built-in segment muxer for efficient processing"
    
    # Analyze output files for anomalies
    echo
    analyze_output_files "$output_dir" "$file_prefix" "$segment_duration"
}

sanitize_filename() {
    local filename="$1"
    
    # Remove file extension for processing
    local name_only="${filename%.*}"
    
    # Convert to lowercase and sanitize for FAT32
    echo "$name_only" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
}

main() {
    check_dependencies
    
    local input_file=""
    local segment_duration="$DEFAULT_SEGMENT_DURATION"
    local output_dir=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -O|--output-dir)
                if [[ -n "$2" && "$2" != -* ]]; then
                    output_dir="$2"
                    shift 2
                else
                    gum style --foreground="#DC2626" "❌ Option $1 requires an argument"
                    exit 1
                fi
                ;;
            -*)
                gum style --foreground="#DC2626" "❌ Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$input_file" ]]; then
                    input_file="$1"
                elif [[ "$1" =~ ^[0-9]+$ ]]; then
                    segment_duration="$1"
                else
                    gum style --foreground="#DC2626" "❌ Invalid argument: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$input_file" ]]; then
        gum style --foreground="#DC2626" "❌ No input file specified"
        echo
        show_help
        exit 1
    fi
    
    validate_file "$input_file"
    validate_duration "$segment_duration"
    
    split_audiobook "$input_file" "$segment_duration" "$output_dir"
}

main "$@"