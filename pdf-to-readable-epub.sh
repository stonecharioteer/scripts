#!/usr/bin/env bash
#
# pdf-to-readable-epub.sh - Convert research papers (especially 2-column) to readable EPUB
#
# This script converts PDF research papers to EPUB format while preserving:
# - Images and figures
# - Code snippets and formatting
# - Table structures
# - Mathematical equations
# - Proper text flow from 2-column layouts
#
# Dependencies: pandoc, pdftohtml (poppler-utils), imagemagick, calibre
#
# Usage: ./pdf-to-readable-epub.sh input.pdf [output.epub]

set -euo pipefail

# Default values
VERBOSE=false
KEEP_TEMP=false
QUALITY="high"
DPI=300

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS] INPUT_PDF [OUTPUT_EPUB]

Convert research papers (especially 2-column layouts) to readable EPUB format.
Preserves images, code snippets, tables, and mathematical equations.

ARGUMENTS:
    INPUT_PDF       Input PDF file to convert
    OUTPUT_EPUB     Output EPUB file (default: INPUT_PDF with .epub extension)

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output
    -k, --keep-temp Keep temporary files for debugging
    -q, --quality   Image quality: low|medium|high (default: high)
    -d, --dpi       Image DPI for extraction (default: 300)

DEPENDENCIES:
    pandoc          Document converter (apt install pandoc)
    pdftohtml       PDF to HTML converter (apt install poppler-utils)
    convert         ImageMagick for image processing (apt install imagemagick)
    ebook-convert   Calibre for EPUB optimization (apt install calibre)

EXAMPLES:
    $0 paper.pdf
    $0 paper.pdf readable-paper.epub
    $0 -v -q high paper.pdf
    $0 --keep-temp --dpi 600 complex-paper.pdf

EOF
}

check_dependencies() {
    local deps=("pandoc" "pdftohtml" "convert" "ebook-convert")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo
        echo "Install with:"
        echo "  sudo apt install pandoc poppler-utils imagemagick calibre"
        echo "  # or on macOS:"
        echo "  brew install pandoc poppler imagemagick calibre"
        exit 1
    fi
}

cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ] && [ "$KEEP_TEMP" = false ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

extract_pdf_content() {
    local input_pdf="$1"
    local temp_dir="$2"
    
    print_info "Extracting PDF content with multiple methods..."
    
    # Try multiple pdftotext methods for best text extraction
    if command -v pdftotext &> /dev/null; then
        print_info "Extracting text with pdftotext (reading order)..."
        # Use -raw for better text flow, not -layout which preserves columns
        pdftotext -raw -nopgbrk "$input_pdf" "$temp_dir/raw_text.txt" 2>/dev/null || {
            # Fallback to simple extraction if -raw fails
            pdftotext -nopgbrk "$input_pdf" "$temp_dir/raw_text.txt" 2>/dev/null || true
        }
    fi
    
    # Extract to HTML with images for visual elements
    print_info "Extracting visual content with pdftohtml..."
    
    # Try multiple image extraction methods
    local extraction_success=false
    
    # Method 1: PNG format with complex options
    if pdftohtml -c -s -i -noframes -fmt png "$input_pdf" "$temp_dir/visual" 2>/dev/null; then
        extraction_success=true
        if [ "$VERBOSE" = true ]; then
            print_info "PNG extraction succeeded"
        fi
    # Method 2: Default format with complex options
    elif pdftohtml -c -s -i -noframes "$input_pdf" "$temp_dir/visual" 2>/dev/null; then
        extraction_success=true
        if [ "$VERBOSE" = true ]; then
            print_info "Default format extraction succeeded"
        fi
    # Method 3: Simple extraction
    elif pdftohtml -i -noframes "$input_pdf" "$temp_dir/visual" 2>/dev/null; then
        extraction_success=true
        if [ "$VERBOSE" = true ]; then
            print_info "Simple extraction succeeded"
        fi
    # Method 4: Alternative extraction with different options
    elif pdftohtml -s -i "$input_pdf" "$temp_dir/visual" 2>/dev/null; then
        extraction_success=true
        if [ "$VERBOSE" = true ]; then
            print_info "Alternative extraction succeeded"
        fi
    else
        print_warning "All HTML extraction methods failed, using text-only conversion"
        echo "<html><body><pre>" > "$temp_dir/visual.html"
        if [ -f "$temp_dir/raw_text.txt" ]; then
            cat "$temp_dir/raw_text.txt" >> "$temp_dir/visual.html"
        fi
        echo "</pre></body></html>" >> "$temp_dir/visual.html"
        extraction_success=true  # We have fallback content
    fi
    
    # Rename the output file to have .html extension if needed
    if [ -f "$temp_dir/visual" ] && [ ! -f "$temp_dir/visual.html" ]; then
        mv "$temp_dir/visual" "$temp_dir/visual.html"
    fi
    
    # Additional image extraction attempts if main extraction didn't produce images
    if [ "$extraction_success" = true ] && [ -f "$temp_dir/visual.html" ]; then
        # Try extracting images separately if none were found in main extraction
        if [ ! -f "$temp_dir"/*.png ] && [ ! -f "$temp_dir"/*.jpg ]; then
            print_info "Attempting separate image extraction..."
            # Try pdfimages if available
            if command -v pdfimages &> /dev/null; then
                pdfimages -png "$input_pdf" "$temp_dir/img" 2>/dev/null || true
                pdfimages -j "$input_pdf" "$temp_dir/img" 2>/dev/null || true
            fi
        fi
    fi
    
    # Move images to organized directory and ensure they exist
    mkdir -p "$temp_dir/images"
    local image_count=0
    
    # Look for images created by pdftohtml or pdfimages
    for img in "$temp_dir"/*.png "$temp_dir"/*.jpg "$temp_dir"/*.jpeg "$temp_dir"/img-*.png "$temp_dir"/img-*.jpg; do
        if [ -f "$img" ] && [[ "$(basename "$img")" != *".html" ]]; then
            if [ "$VERBOSE" = true ]; then
                print_info "Found image: $(basename "$img")"
            fi
            mv "$img" "$temp_dir/images/" 2>/dev/null && ((image_count++))
        fi
    done
    
    if [ "$VERBOSE" = true ]; then
        print_info "Extracted $image_count images"
    fi
}

process_html_content() {
    local temp_dir="$1"
    local html_file="$temp_dir/visual.html"
    local processed_file="$temp_dir/processed.html"
    local text_file="$temp_dir/raw_text.txt"
    
    print_info "Processing content for optimal readability..."
    
    if [ ! -f "$html_file" ]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi
    
    # Create improved HTML with better structure and intelligent content merging
    cat > "$processed_file" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Research Paper</title>
    <style>
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Georgia, serif; 
            line-height: 1.7; 
            max-width: 45em; 
            margin: 0 auto; 
            padding: 2rem 1rem;
            color: #2d3748;
            background: #fff;
            font-size: 16px;
        }
        .page-break { page-break-before: always; margin-top: 2rem; }
        img { 
            max-width: 100%; 
            height: auto; 
            display: block; 
            margin: 2rem auto;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            border-radius: 8px;
        }
        pre, code { 
            background: #f7fafc; 
            padding: 1rem; 
            border-radius: 6px; 
            overflow-x: auto;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', monospace;
            font-size: 0.9em;
            border-left: 4px solid #4299e1;
            margin: 1.5rem 0;
        }
        code {
            padding: 0.2rem 0.4rem;
            margin: 0;
            border-left: none;
            display: inline;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 2rem 0;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        th, td {
            border: 1px solid #e2e8f0;
            padding: 0.75rem 1rem;
            text-align: left;
        }
        th {
            background-color: #f7fafc;
            font-weight: 600;
            color: #2d3748;
        }
        .figure-caption, .table-caption {
            font-style: italic;
            text-align: center;
            margin: 1rem 0;
            font-size: 0.9em;
            color: #718096;
        }
        h1, h2, h3, h4, h5, h6 {
            color: #1a202c;
            margin-top: 2.5rem;
            margin-bottom: 1rem;
            font-weight: 600;
            line-height: 1.3;
        }
        h1 { font-size: 1.875rem; border-bottom: 2px solid #e2e8f0; padding-bottom: 0.5rem; }
        h2 { font-size: 1.5rem; }
        h3 { font-size: 1.25rem; }
        .math {
            text-align: center;
            margin: 1.5rem 0;
            font-style: italic;
            background: #f7fafc;
            padding: 1rem;
            border-radius: 6px;
        }
        .abstract, .introduction {
            background: #f7fafc;
            padding: 1.5rem;
            border-radius: 8px;
            margin: 2rem 0;
            border-left: 4px solid #38b2ac;
        }
        .references {
            font-size: 0.9em;
            margin-top: 3rem;
            border-top: 2px solid #e2e8f0;
            padding-top: 2rem;
        }
        p {
            margin: 1rem 0;
            text-align: justify;
        }
        blockquote {
            border-left: 4px solid #38b2ac;
            padding-left: 1rem;
            margin: 1.5rem 0;
            font-style: italic;
            color: #4a5568;
        }
    </style>
</head>
<body>
EOF

    # Process content - prioritize clean text but fallback to HTML
    if [ -f "$text_file" ] && [ -s "$text_file" ]; then
        print_info "Using extracted text with simple formatting..."
        
        # Advanced text processing to reconstruct proper paragraphs
        cat "$text_file" | \
        # First, clean up and reconstruct paragraphs
        awk '
        BEGIN { 
            in_para = 0
            current_para = ""
            RS = "\n"
        }
        
        # Skip empty lines
        /^[[:space:]]*$/ { 
            if (current_para != "") {
                print current_para
                current_para = ""
            }
            next 
        }
        
        # Major section headers (numbers or roman numerals)
        /^[0-9]+\.?[[:space:]]+[A-Z]/ || /^[IVX]+\.?[[:space:]]+[A-Z]/ { 
            if (current_para != "") {
                print current_para
                current_para = ""
            }
            print "HEADER:" $0
            next 
        }
        
        # Abstract section
        /^[Aa]bstract[[:space:]]*$/ && NR < 20 { 
            if (current_para != "") {
                print current_para
                current_para = ""
            }
            print "ABSTRACT:" $0
            next 
        }
        
        # References section
        /^[Rr]eferences[[:space:]]*$/ { 
            if (current_para != "") {
                print current_para
                current_para = ""
            }
            print "REFERENCES:" $0
            next 
        }
        
        # Code or indented blocks
        /^[[:space:]]{4,}/ { 
            if (current_para != "") {
                print current_para
                current_para = ""
            }
            print "CODE:" $0
            next 
        }
        
        # Regular text - smart paragraph reconstruction
        {
            line = $0
            gsub(/^[[:space:]]+/, "", line)  # Remove leading whitespace
            gsub(/[[:space:]]+$/, "", line)  # Remove trailing whitespace
            
            if (line == "") next
            
            # Check if this line continues the previous paragraph
            should_join = 0
            if (current_para != "") {
                # Join if: line starts with lowercase, or previous line doesn t end with period/question/exclamation
                if (match(line, /^[a-z]/) || !match(current_para, /[.!?][[:space:]]*$/)) {
                    should_join = 1
                }
                # Don t join if line looks like a new sentence (starts with capital after space)
                if (match(line, /^[A-Z][a-z]/) && match(current_para, /[.!?][[:space:]]*$/)) {
                    should_join = 0
                }
            }
            
            if (should_join) {
                current_para = current_para " " line
            } else {
                if (current_para != "") {
                    print current_para
                }
                current_para = line
            }
        }
        
        END { 
            if (current_para != "") print current_para 
        }
        ' | \
        # Now convert to HTML with proper escaping
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | \
        awk '
        /^HEADER:/ { 
            gsub(/^HEADER:/, "")
            print "<h2>" $0 "</h2>"
            next
        }
        /^ABSTRACT:/ { 
            gsub(/^ABSTRACT:/, "")
            print "<div class=\"abstract\"><h3>Abstract</h3>"
            next
        }
        /^REFERENCES:/ { 
            print "<div class=\"references\"><h2>References</h2>"
            next
        }
        /^CODE:/ { 
            gsub(/^CODE:/, "")
            print "<pre>" $0 "</pre>"
            next
        }
        {
            print "<p>" $0 "</p>"
        }
        ' >> "$processed_file"
        
    else
        print_info "Processing HTML content..."
        # Fallback to HTML processing if no clean text
        if [ -f "$html_file" ]; then
            sed -n '/<body/,/<\/body>/p' "$html_file" | \
            sed 's/<body[^>]*>//g; s/<\/body>//g' | \
            sed 's/images\//images\//g' | \
            sed 's/<br[^>]*>/<br\/>/g' | \
            sed 's/<hr[^>]*>/<hr\/>/g' >> "$processed_file"
        fi
    fi
    
    # Add any images found in the HTML or images directory
    local image_added=false
    if [ -f "$html_file" ]; then
        print_info "Adding images from HTML..."
        grep -o '<img[^>]*>' "$html_file" 2>/dev/null | while read -r img_tag; do
            echo "$img_tag" >> "$processed_file"
            image_added=true
        done || true
    fi
    
    # If no images in HTML, add any images from the images directory
    if [ "$image_added" = false ] && [ -d "$temp_dir/images" ]; then
        for img in "$temp_dir/images"/*; do
            if [ -f "$img" ]; then
                local img_name=$(basename "$img")
                echo "<figure><img src=\"images/$img_name\" alt=\"Figure\" /><figcaption>Figure</figcaption></figure>" >> "$processed_file"
                if [ "$VERBOSE" = true ]; then
                    print_info "Added image: $img_name"
                fi
            fi
        done
    fi
    
    echo "</body></html>" >> "$processed_file"
    
    # Fix image paths to be relative
    sed -i 's/src="[^"]*\/\([^"]*\)"/src="images\/\1"/g' "$processed_file"
}

optimize_images() {
    local temp_dir="$1"
    local images_dir="$temp_dir/images"
    
    if [ ! -d "$images_dir" ] || [ -z "$(ls -A "$images_dir" 2>/dev/null)" ]; then
        print_warning "No images found to optimize"
        return 0
    fi
    
    print_info "Optimizing images for EPUB..."
    
    local quality_setting
    case "$QUALITY" in
        low) quality_setting=60 ;;
        medium) quality_setting=80 ;;
        high) quality_setting=90 ;;
        *) quality_setting=80 ;;
    esac
    
    find "$images_dir" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) | while read -r img; do
        if [ "$VERBOSE" = true ]; then
            print_info "Optimizing $(basename "$img")..."
        fi
        
        # Optimize image while preserving important details
        convert "$img" \
            -density "$DPI" \
            -quality "$quality_setting" \
            -resize '800x800>' \
            -unsharp 0x.5 \
            "$img.optimized" && \
        mv "$img.optimized" "$img" 2>/dev/null || true
    done
}

convert_to_epub() {
    local temp_dir="$1"
    local output_epub="$2"
    local processed_html="$temp_dir/processed.html"
    local temp_epub="$temp_dir/temp.epub"
    
    print_info "Converting HTML to EPUB..."
    
    # First convert with pandoc
    pandoc \
        --from html \
        --to epub3 \
        --embed-resources \
        --standalone \
        --toc \
        --toc-depth=3 \
        --epub-cover-image="$temp_dir/images/$(ls "$temp_dir/images/" | head -n1 2>/dev/null || echo '')" \
        --metadata title="Research Paper" \
        --metadata author="Academic Paper" \
        --metadata language="en" \
        "$processed_html" \
        -o "$temp_epub" 2>/dev/null || {
        
        # Fallback without cover image
        pandoc \
            --from html \
            --to epub3 \
            --embed-resources \
            --standalone \
            --toc \
            --toc-depth=3 \
            --metadata title="Research Paper" \
            --metadata author="Academic Paper" \
            --metadata language="en" \
            "$processed_html" \
            -o "$temp_epub"
    }
    
    # Optimize with calibre if available
    if command -v ebook-convert &> /dev/null && [ -f "$temp_epub" ]; then
        print_info "Optimizing EPUB with Calibre..."
        ebook-convert "$temp_epub" "$output_epub" \
            --enable-heuristics \
            --fix-indents \
            --remove-paragraph-spacing \
            --insert-blank-line \
            --linearize-tables \
            2>/dev/null || cp "$temp_epub" "$output_epub"
    else
        cp "$temp_epub" "$output_epub"
    fi
}

main() {
    # Parse arguments
    local input_pdf=""
    local output_epub=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -k|--keep-temp)
                KEEP_TEMP=true
                shift
                ;;
            -q|--quality)
                QUALITY="$2"
                shift 2
                ;;
            -d|--dpi)
                DPI="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -z "$input_pdf" ]; then
                    input_pdf="$1"
                elif [ -z "$output_epub" ]; then
                    output_epub="$1"
                else
                    print_error "Too many arguments"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$input_pdf" ]; then
        print_error "Input PDF file required"
        usage
        exit 1
    fi
    
    if [ ! -f "$input_pdf" ]; then
        print_error "Input file not found: $input_pdf"
        exit 1
    fi
    
    # Validate that input is actually a PDF file
    if ! file "$input_pdf" | grep -q "PDF document"; then
        print_error "Input file is not a PDF document: $input_pdf"
        print_error "File type detected: $(file -b "$input_pdf")"
        exit 1
    fi
    
    if [ -z "$output_epub" ]; then
        output_epub="${input_pdf%.*}.epub"
    fi
    
    # Check dependencies
    check_dependencies
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    
    print_info "Converting '$input_pdf' to '$output_epub'"
    print_info "Using temporary directory: $TEMP_DIR"
    
    # Main conversion process
    extract_pdf_content "$input_pdf" "$TEMP_DIR"
    process_html_content "$TEMP_DIR"
    optimize_images "$TEMP_DIR"
    convert_to_epub "$TEMP_DIR" "$output_epub"
    
    if [ -f "$output_epub" ]; then
        print_success "EPUB created successfully: $output_epub"
        print_info "File size: $(du -h "$output_epub" | cut -f1)"
        
        if [ "$KEEP_TEMP" = true ]; then
            print_info "Temporary files kept in: $TEMP_DIR"
        fi
    else
        print_error "Failed to create EPUB file"
        exit 1
    fi
}

# Run main function
main "$@"