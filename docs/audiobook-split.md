# Audiobook Split

## Purpose

I needed to split audiobooks into smaller segments specifically for compatibility with my Shokz OpenSwim headphones, which work better with shorter audio files during swimming workouts.

## Overview

Split audiobooks into smaller segments for easier listening or processing using ffmpeg's efficient segment muxer.

## Requirements

- `ffmpeg` for audio processing
- `gum` for prettier terminal output

## Features

- **Efficient processing** - Uses ffmpeg's built-in segment muxer (low memory usage)
- **Real-time progress** - Shows percentage, elapsed time, and ETA with fallback for older gum versions
- **Intelligent performance** - Auto-detects CPU architecture and optimizes thread count accordingly
- **FAT32-compatible filenames** - Lowercase, no special characters, shorter paths
- **Dynamic numbering** - Uses minimum digits needed (2-4 digits based on segment count)
- **Human-friendly indexing** - Starts from 1 instead of 0
- **Custom output directory** - Specify where files are saved, uses directory name as file prefix
- **Multiple formats** - Supports m4a, m4b, and mp3 input
- **Comprehensive analysis** - Post-processing summary with file statistics and anomaly detection

## Usage

```bash
./audiobook-split.sh <audiobook_file> [segment_duration_in_seconds] [options]
./audiobook-split.sh -h  # Show help
```

## Options

- `-O, --output-dir DIR` - Custom output directory
- `-h, --help` - Show help message

## Supported Formats

- **Input**: m4a, m4b, mp3
- **Output**: mp3
- **Default segment duration**: 5 minutes (300 seconds)

## Examples

```bash
./audiobook-split.sh audiobook.m4a                    # Split into 5-minute segments
./audiobook-split.sh audiobook.m4b 600                # Split into 10-minute segments  
./audiobook-split.sh audiobook.mp3 480 -O harry_potter # Custom output directory
```

## Output Format

- Files saved as `{prefix}_01.mp3`, `{prefix}_02.mp3`, etc. (dynamic digit count)
- FAT32-compatible filenames (lowercase, underscores replace special chars)
- Custom directory: Uses directory name as prefix (e.g., `harry_potter_01.mp3`)
- Progress display: `🔄 45% (02:15 / 17:18:34) | Elapsed: 01:30 | ETA: 02:15`
- Performance info: `⚡ Performance: Using 16/32 threads (AMD Ryzen 9 7950X) | RAM: 64G`
- Post-processing analysis with file statistics and outlier detection

## Performance Optimization

### CPU Architecture Detection
The script automatically detects your CPU and optimizes thread usage:

- **AMD Ryzen**: Uses 50% of available threads
- **Intel Xeon**: Uses 75% of available threads  
- **ARM processors**: Uses 25% of available threads
- **Other CPUs**: Uses 50% of available threads

### Memory Considerations
- Uses ffmpeg's segment muxer for minimal memory footprint
- Single-pass processing to avoid memory buildup
- Efficient for large audiobook files

## File Naming

### Input Processing
- Extracts base name from input file
- Removes file extension
- Sanitizes for FAT32 compatibility (lowercase, no special chars)

### Output Naming
- **Default**: Uses sanitized input filename as prefix
- **Custom directory**: Uses directory name as prefix
- **Dynamic digits**: 2 digits for <100 segments, 3 for <1000, 4 for >=1000
- **Human indexing**: Starts from 01, not 00

### Examples
```bash
# Input: "Harry Potter and the Philosopher's Stone.m4b"
# Output: harrypotterandthephilosophersstone_01.mp3, harrypotterandthephilosophersstone_02.mp3

# Custom directory: -O "hp1"
# Output: hp1_01.mp3, hp1_02.mp3
```

## Progress Display

### Real-time Information
- Current segment being processed
- Percentage complete
- Elapsed time and ETA
- Processing speed
- System performance info

### Example Output
```
🔄 Processing: harrypotter_15.mp3
📊 Progress: 45% (15/33 segments)
⏱️  Time: 02:15 elapsed | ETA: 02:45
⚡ Performance: Using 16/32 threads (AMD Ryzen 9 7950X) | RAM: 64G
```

## Post-Processing Analysis

After splitting, the script provides comprehensive analysis:

### File Statistics
- Total segments created
- File size distribution
- Duration analysis
- Anomaly detection (oversized or undersized segments)

### Example Summary
```
✅ Split completed successfully!

📊 Summary:
   - Input: audiobook.m4b (847.2 MB, 18h 32m)
   - Output: 223 segments in ./audiobook/
   - Total size: 847.1 MB
   - Average segment: 5m 0s (3.8 MB)

🔍 Analysis:
   - Segments within expected range: 221/223
   - Potential issues: 2 segments >10% size variance
   - Largest: audiobook_087.mp3 (4.2 MB, 5m 34s)
   - Smallest: audiobook_223.mp3 (1.8 MB, 2m 15s)
```

## Directory Structure

```
./
├── audiobook.m4b                    # Input file
└── audiobook/                       # Output directory
    ├── audiobook_01.mp3
    ├── audiobook_02.mp3
    ├── ...
    └── audiobook_223.mp3
```

## Integration with Audiobook Pipeline

This script is designed to work with `audiobook-pipeline.sh`:

```bash
# Split M4B files after conversion
./audiobook-pipeline.sh convert book.aax
./audiobook-split.sh ~/Audiobooks/audible/converted/book.m4b

# Or use the integrated split command
./audiobook-pipeline.sh split --duration 480
```

## Troubleshooting

### Common Issues

1. **FFmpeg not found**: Install ffmpeg
2. **Permission errors**: Check output directory permissions
3. **Unsupported format**: Use m4a, m4b, or mp3 input files
4. **Large files**: Ensure sufficient disk space (output ~= input size)

### Performance Issues

1. **Slow processing**: 
   - Check available CPU threads
   - Verify disk I/O performance
   - Consider reducing thread count for older systems

2. **Memory usage**: 
   - Script uses minimal memory due to segment muxer
   - If issues persist, check system memory availability

### File Naming Issues

1. **Special characters**: Script automatically sanitizes filenames
2. **Long names**: Automatically truncated for FAT32 compatibility  
3. **Duplicate names**: Script will overwrite existing files

## Advanced Usage

### Custom Thread Count
For manual performance tuning, modify the script's thread detection logic or run with specific ffmpeg parameters.

### Batch Processing
Use with find or xargs for bulk processing:

```bash
find ~/Audiobooks -name "*.m4b" -exec ./audiobook-split.sh {} 600 \;
```

### Integration with Other Tools
The script's clean output format makes it suitable for integration with other automation tools and scripts.