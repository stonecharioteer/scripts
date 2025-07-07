#!/bin/bash

# highlight-manager.sh - Manage Kindle highlights with DuckDB
# Usage: ./highlight-manager.sh <subcommand> [options]

set -euo pipefail

# Default values
DEFAULT_DATABASE_PATH="$HOME/Documents/highlights.db"
DATABASE_PATH="$DEFAULT_DATABASE_PATH"
INPUT_FILE="myClippings.txt"
DEFAULT_SHOW_COUNT=10

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Function to show main help
show_help() {
    cat << EOF
highlight-manager.sh - Manage Kindle highlights with DuckDB

Usage: $0 <subcommand> [options]

Subcommands:
  import    Import highlights from myClippings file to database
  show      Display highlights from database
  summary   Show database statistics and overview

Global Options:
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Examples:
  $0 import myClippings.txt
  $0 import file1.txt file2.txt file3.txt
  $0 show -n 5
  $0 summary
  $0 --database-path ~/custom.db import *.clippings.txt
  $0 show --number 20

For subcommand-specific help:
  $0 import --help
  $0 show --help
  $0 summary --help
EOF
}

# Function to show summary help
show_summary_help() {
    cat << EOF
highlight-manager.sh summary - Show database statistics and overview

Usage: $0 summary [options]

Options:
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Examples:
  $0 summary
  $0 summary --database-path ~/custom.db
EOF
}

# Function to show import help
show_import_help() {
    cat << EOF
highlight-manager.sh import - Import highlights from myClippings file(s)

Usage: $0 import [options] [INPUT_FILE...]

Arguments:
  INPUT_FILE...    One or more myClippings files to import (default: myClippings.txt)

Options:
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Examples:
  $0 import
  $0 import myClippings.txt
  $0 import file1.txt file2.txt file3.txt
  $0 import --database-path ~/custom.db *.clippings.txt
  $0 import book1.txt book2.txt --database-path ~/highlights.db
EOF
}

# Function to show show help
show_show_help() {
    cat << EOF
highlight-manager.sh show - Display highlights from database

Usage: $0 show [options]

Options:
  -n, --number COUNT      Number of highlights to show (default: $DEFAULT_SHOW_COUNT)
  --sort-by FIELD         Sort by field: location, date_added (default: location)
  --sort-order ORDER      Sort order: asc, desc (default: asc)
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Sort Options:
  Default sort: location ASC, date_added ASC, book_title ASC
  --sort-by date_added: date_added ASC, location ASC, book_title ASC
  Use --sort-order desc to reverse the primary sort field

Examples:
  $0 show
  $0 show -n 5
  $0 show --number 20
  $0 show --sort-by location
  $0 show --sort-by date_added --sort-order desc
  $0 show --database-path ~/custom.db
EOF
}

# Function to check dependencies
check_dependencies() {
    local missing=()
    
    if ! command -v duckdb &> /dev/null; then
        missing+=("duckdb")
    fi
    
    if ! command -v gum &> /dev/null; then
        missing+=("gum")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies:${NC}"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Installation instructions:"
        echo "  DuckDB: https://duckdb.org/docs/installation/"
        echo "  gum: https://github.com/charmbracelet/gum#installation"
        exit 1
    fi
}

# Function to initialize database
init_database() {
    local db_path="$1"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$db_path")"
    
    # Create database and table if they don't exist
    duckdb "$db_path" "CREATE TABLE IF NOT EXISTS highlights (
        book_title TEXT NOT NULL,
        author TEXT,
        highlight_type TEXT NOT NULL,
        location TEXT,
        date_added TEXT,
        content TEXT NOT NULL,
        content_hash TEXT UNIQUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );"
    
    duckdb "$db_path" "CREATE INDEX IF NOT EXISTS idx_content_hash ON highlights(content_hash);"
    duckdb "$db_path" "CREATE INDEX IF NOT EXISTS idx_book_title ON highlights(book_title);"
    duckdb "$db_path" "CREATE INDEX IF NOT EXISTS idx_author ON highlights(author);"
}

# Function to parse book title and author
parse_book_author() {
    local full_title="$1"
    local book_title=""
    local author=""
    
    # Try to parse "Title (Author)" format
    if [[ "$full_title" =~ ^(.+)\ \(([^\)]+)\)$ ]]; then
        book_title="${BASH_REMATCH[1]}"
        author="${BASH_REMATCH[2]}"
    else
        # Fallback: entire string as book title
        book_title="$full_title"
        author=""
    fi
    
    # Clean up whitespace
    book_title=$(echo "$book_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    author=$(echo "$author" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    echo "$book_title|$author"
}

# Function to clean content text
clean_content() {
    local content="$1"
    
    # Remove trailing/leading whitespace, non-breaking spaces, normalize spaces
    content=$(echo "$content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    content=$(echo "$content" | tr -d '\r' | tr '\n' ' ')
    content=$(echo "$content" | sed 's/[[:space:]]\+/ /g')
    content=$(echo "$content" | sed 's/—$//')  # Remove trailing em dash
    
    echo "$content"
}

# Function to generate content hash
generate_hash() {
    local content="$1"
    # Use a simpler approach to avoid issues with special characters
    printf '%s' "$content" | sha256sum | cut -d' ' -f1
}

# Function to import highlights and return statistics (for multiple file processing)
import_highlights_with_stats() {
    local input_file="$1"
    local db_path="$2"
    
    if [[ ! -f "$input_file" ]]; then
        echo "Error: Input file '$input_file' not found" >&2
        echo "0,0,0"
        return 1
    fi
    
    # Initialize database
    init_database "$db_path"
    
    # Convert myClippings to JSON format
    local temp_json=$(mktemp)
    
    # Parse myClippings format directly (suppress output)
    python3 << EOF >/dev/null 2>&1
import json
import re
import sys

def parse_book_author(full_title):
    """Parse 'Title (Author)' format into separate fields"""
    match = re.search(r'^(.+?) \(([^)]+)\)$', full_title.strip())
    if match:
        return match.group(1).strip(), match.group(2).strip()
    return full_title.strip(), ""

def clean_content(content):
    """Clean content text"""
    content = content.strip()
    content = ' '.join(content.split())  # Normalize whitespace
    content = content.rstrip('—')  # Remove trailing em dash
    return content

clippings = []
current_book = ""
current_metadata = ""
current_content = ""
in_content = False

try:
    with open('$input_file', 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n\r')
            
            if line == "==========":
                # End of clipping - process it
                if current_book and current_metadata and current_content:
                    # Parse book and author
                    book_title, author = parse_book_author(current_book)
                    
                    # Parse metadata
                    highlight_type = "highlight"
                    location = ""
                    date_added = ""
                    
                    metadata_match = re.search(r'- Your ([^\\s]+) on (.+) \\| Added on (.+)', current_metadata)
                    if metadata_match:
                        highlight_type = metadata_match.group(1)
                        location = metadata_match.group(2)
                        date_added = metadata_match.group(3)
                    
                    # Clean content
                    clean_content_text = clean_content(current_content)
                    
                    clippings.append({
                        "book_title": book_title,
                        "author": author,
                        "type": highlight_type,
                        "location": location,
                        "date_added": date_added,
                        "content": clean_content_text
                    })
                
                # Reset for next clipping
                current_book = ""
                current_metadata = ""
                current_content = ""
                in_content = False
                
            elif in_content:
                # Accumulate content lines
                if current_content:
                    current_content += "\n" + line
                else:
                    current_content = line
                    
            elif line.startswith("- Your ") and " | Added on " in line:
                # This is the metadata line
                current_metadata = line
                
            elif line and not current_metadata:
                # This is the book title
                current_book = line
                
            elif not line and current_metadata:
                # Empty line after metadata - next lines are content
                in_content = True

    # Write JSON output
    with open('$temp_json', 'w', encoding='utf-8') as f:
        json.dump(clippings, f, indent=2, ensure_ascii=False)
    
except Exception as e:
    sys.exit(1)
EOF
    
    # Get the total found from the JSON
    local total_found
    total_found=$(python3 << EOF
import json
try:
    with open('$temp_json', 'r') as f:
        data = json.load(f)
    print(len(data))
except:
    print(0)
EOF
)
    
    # Get count before import
    local count_before
    count_before=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null || echo "0")
    
    # Generate and execute SQL inserts
    python3 << EOF >/dev/null 2>&1
import json
import hashlib

# Read JSON file
with open('$temp_json', 'r') as f:
    data = json.load(f)

# Generate SQL inserts for all highlights
with open('/tmp/import.sql', 'w') as f:
    for item in data:
        # Use the parsed fields from the Python parser
        book_clean = item['book_title']
        author = item.get('author', '')
        highlight_type = item['type']
        location = item['location']
        date_added = item['date_added']
        content = item['content']
        
        # Clean content
        content_clean = content.strip()
        content_clean = ' '.join(content_clean.split())  # Normalize whitespace
        content_clean = content_clean.rstrip('—')  # Remove trailing em dash
        
        # Generate hash
        content_hash = hashlib.sha256(content_clean.encode()).hexdigest()
        
        # Escape single quotes for SQL
        book_escaped = book_clean.replace("'", "''")
        author_escaped = author.replace("'", "''")
        highlight_type_escaped = highlight_type.replace("'", "''")
        location_escaped = location.replace("'", "''")
        date_escaped = date_added.replace("'", "''")
        content_escaped = content_clean.replace("'", "''")
        
        f.write(f"INSERT INTO highlights (book_title, author, highlight_type, location, date_added, content, content_hash) VALUES ('{book_escaped}', '{author_escaped}', '{highlight_type_escaped}', '{location_escaped}', '{date_escaped}', '{content_escaped}', '{content_hash}') ON CONFLICT DO NOTHING;\n")
EOF
    
    # Import the SQL into DuckDB
    if [[ -f "/tmp/import.sql" ]]; then
        duckdb "$db_path" < /tmp/import.sql 2>/dev/null
        rm -f /tmp/import.sql
    fi
    
    # Get count after import
    local count_after
    count_after=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null || echo "0")
    
    # Calculate statistics
    local new_imports=$((count_after - count_before))
    local duplicates=$((total_found - new_imports))
    
    # Clean up
    rm -f "$temp_json"
    
    # Return statistics as CSV
    echo "$total_found,$new_imports,$duplicates"
}

# Function to convert myClippings to JSON first, then import (with display output)
import_highlights() {
    local input_file="$1"
    local db_path="$2"
    
    echo -e "${BLUE}Importing highlights from '$input_file' to '$db_path'...${NC}"
    
    if [[ ! -f "$input_file" ]]; then
        echo -e "${RED}Error: Input file '$input_file' not found${NC}"
        exit 1
    fi
    
    # Initialize database
    init_database "$db_path"
    
    # Convert myClippings to JSON format
    local temp_json=$(mktemp)
    
    echo "Converting myClippings format to structured data..."
    
    # Parse myClippings format directly and show progress
    python3 << EOF
import json
import re
import sys

def parse_book_author(full_title):
    """Parse 'Title (Author)' format into separate fields"""
    match = re.search(r'^(.+?) \(([^)]+)\)$', full_title.strip())
    if match:
        return match.group(1).strip(), match.group(2).strip()
    return full_title.strip(), ""

def clean_content(content):
    """Clean content text"""
    content = content.strip()
    content = ' '.join(content.split())  # Normalize whitespace
    content = content.rstrip('—')  # Remove trailing em dash
    return content

clippings = []
current_book = ""
current_metadata = ""
current_content = ""
in_content = False

try:
    with open('$input_file', 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n\r')
            
            if line == "==========":
                # End of clipping - process it
                if current_book and current_metadata and current_content:
                    # Parse book and author
                    book_title, author = parse_book_author(current_book)
                    
                    # Parse metadata
                    highlight_type = "highlight"
                    location = ""
                    date_added = ""
                    
                    metadata_match = re.search(r'- Your ([^\\s]+) on (.+) \\| Added on (.+)', current_metadata)
                    if metadata_match:
                        highlight_type = metadata_match.group(1)
                        location = metadata_match.group(2)
                        date_added = metadata_match.group(3)
                    
                    # Clean content
                    clean_content_text = clean_content(current_content)
                    
                    clippings.append({
                        "book_title": book_title,
                        "author": author,
                        "type": highlight_type,
                        "location": location,
                        "date_added": date_added,
                        "content": clean_content_text
                    })
                
                # Reset for next clipping
                current_book = ""
                current_metadata = ""
                current_content = ""
                in_content = False
                
            elif in_content:
                # Accumulate content lines
                if current_content:
                    current_content += "\n" + line
                else:
                    current_content = line
                    
            elif line.startswith("- Your ") and " | Added on " in line:
                # This is the metadata line
                current_metadata = line
                
            elif line and not current_metadata:
                # This is the book title
                current_book = line
                
            elif not line and current_metadata:
                # Empty line after metadata - next lines are content
                in_content = True

    # Write JSON output
    with open('$temp_json', 'w', encoding='utf-8') as f:
        json.dump(clippings, f, indent=2, ensure_ascii=False)
    
    print(f"Converted {len(clippings)} clippings to structured format", file=sys.stderr)
    
except Exception as e:
    print(f"Error parsing myClippings file: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    
    echo "Processing highlights and detecting duplicates..."
    echo "Generating import data..."
    
    # Use the stats function but without its own output
    local import_stats
    import_stats=$(import_highlights_with_stats "$input_file" "$db_path")
    
    # Parse the statistics
    IFS=',' read -r total_found new_imports duplicates <<< "$import_stats"
    
    # Get final count for display
    local final_count
    final_count=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null)
    
    echo -e "${GREEN}✅ Import completed:${NC}"
    echo "   - $total_found quotes found in file"
    echo "   - $new_imports new highlights imported"
    echo "   - $duplicates duplicates skipped (already in database)"
    echo "   - $final_count total highlights in database"
}

# Function to show database summary
show_summary() {
    local db_path="$1"
    
    if [[ ! -f "$db_path" ]]; then
        echo -e "${RED}Error: Database file '$db_path' not found${NC}"
        echo "Run 'import' command first to create the database."
        exit 1
    fi
    
    echo -e "${BLUE}Database Summary for '$db_path'${NC}"
    echo ""
    
    # Get total highlights count (use CSV mode for clean output)
    local total_highlights
    total_highlights=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null)
    
    # Get unique books count
    local total_books
    total_books=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(DISTINCT book_title) FROM highlights;" 2>/dev/null)
    
    # Get unique authors count
    local total_authors
    total_authors=$(duckdb "$db_path" -csv -noheader "SELECT COUNT(DISTINCT author) FROM highlights WHERE author IS NOT NULL AND author != '';" 2>/dev/null)
    
    echo -e "${GREEN}📊 Overall Statistics:${NC}"
    echo "   Total highlights: $total_highlights"
    echo "   Unique books: $total_books"
    echo "   Unique authors: $total_authors"
    echo ""
    
    # Get highlights per book using tab-separated output for easier parsing
    echo -e "${GREEN}📚 Highlights per Book:${NC}"
    local temp_tsv=$(mktemp)
    duckdb "$db_path" "COPY (SELECT book_title, COALESCE(author, 'Unknown') as author, COUNT(*) as highlight_count FROM highlights GROUP BY book_title, author ORDER BY highlight_count DESC, book_title ASC) TO '/dev/stdout' (DELIMITER '\t', HEADER false);" 2>/dev/null > "$temp_tsv"
    
    if [[ -s "$temp_tsv" ]]; then
        while IFS=$'\t' read -r book_title author count; do
            # Format the output
            if [[ "$author" != "Unknown" && -n "$author" ]]; then
                printf "   %-50s by %-20s %s highlights\n" "$book_title" "$author" "$count"
            else
                printf "   %-72s %s highlights\n" "$book_title" "$count"
            fi
        done < "$temp_tsv"
    else
        echo "   No data available"
    fi
    rm -f "$temp_tsv"
    
    echo ""
    
    # Get date range using tab-separated output
    echo -e "${GREEN}📅 Date Range:${NC}"
    local temp_dates=$(mktemp)
    duckdb "$db_path" "COPY (SELECT MIN(date_added) as earliest, MAX(date_added) as latest FROM highlights WHERE date_added IS NOT NULL AND date_added != '') TO '/dev/stdout' (DELIMITER '\t', HEADER false);" 2>/dev/null > "$temp_dates"
    
    if [[ -s "$temp_dates" ]]; then
        while IFS=$'\t' read -r earliest latest; do
            if [[ -n "$earliest" && "$earliest" != "NULL" ]]; then
                echo "   Earliest highlight: $earliest"
                echo "   Latest highlight: $latest"
            else
                echo "   No date information available"
            fi
            break  # Only process first line
        done < "$temp_dates"
    else
        echo "   No date information available"
    fi
    rm -f "$temp_dates"
    
    echo ""
    
    # Get top authors by highlight count using tab-separated output
    echo -e "${GREEN}✍️  Top Authors by Highlight Count:${NC}"
    local temp_authors=$(mktemp)
    duckdb "$db_path" "COPY (SELECT author, COUNT(*) as highlight_count FROM highlights WHERE author IS NOT NULL AND author != '' GROUP BY author ORDER BY highlight_count DESC LIMIT 10) TO '/dev/stdout' (DELIMITER '\t', HEADER false);" 2>/dev/null > "$temp_authors"
    
    if [[ -s "$temp_authors" ]]; then
        while IFS=$'\t' read -r author count; do
            printf "   %-30s %s highlights\n" "$author" "$count"
        done < "$temp_authors"
    else
        echo "   No author information available"
    fi
    rm -f "$temp_authors"
}

# Function to show highlights
show_highlights() {
    local db_path="$1"
    local count="$2"
    local sort_by="${3:-location}"
    local sort_order="${4:-asc}"
    local user_specified_count="${5:-false}"
    
    if [[ ! -f "$db_path" ]]; then
        echo -e "${RED}Error: Database file '$db_path' not found${NC}"
        echo "Run 'import' command first to create the database."
        exit 1
    fi
    
    echo -e "${BLUE}Showing $count highlights from '$db_path'...${NC}"
    echo ""
    
    # Create a temporary CSV file for gum table
    local temp_csv=$(mktemp)
    
    # Build ORDER BY clause based on sort parameters
    local order_clause
    local primary_order=$(echo "$sort_order" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$sort_by" == "date_added" ]]; then
        order_clause="date_added $primary_order, location ASC, book_title ASC"
    else
        # Default: location sorting
        order_clause="location $primary_order, date_added ASC, book_title ASC"
    fi
    
    # Get data using tab-separated output to avoid comma issues
    local raw_data
    raw_data=$(duckdb "$db_path" "COPY (SELECT book_title, COALESCE(author, 'Unknown') as author, content, location, date_added FROM highlights ORDER BY $order_clause LIMIT $count) TO '/dev/stdout' (DELIMITER '\t');" 2>/dev/null | tail -n +2)
    
    if [[ -z "$raw_data" ]]; then
        echo -e "${YELLOW}No highlights found in database.${NC}"
        rm -f "$temp_csv"
        return
    fi
    
    
    # Create simple display instead of CSV
    echo -e "${GREEN}📖 Recent Highlights:${NC}"
    echo ""
    
    # Use a more direct approach with readarray
    readarray -t lines <<< "$raw_data"
    
    local counter=1
    for line in "${lines[@]}"; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Parse tab-separated fields
        IFS=$'\t' read -r book_title author content location date_added <<< "$line"
        
        # Determine wrapping width (80 chars or screen width, whichever is smaller)
        local screen_width=$(tput cols 2>/dev/null || echo 80)
        local wrap_width=$((screen_width < 80 ? screen_width : 80))
        local content_width=$((wrap_width - 3))  # Account for "   " prefix
        
        echo -e "${BLUE}$counter. $book_title${NC} by ${YELLOW}$author${NC}"
        echo ""
        
        # Wrap the content text
        local wrapped_content
        wrapped_content=$(echo "$content" | fold -s -w "$content_width" | sed '2,$s/^/   /')
        echo "   $wrapped_content"
        
        # Display location and date on separate lines after content
        echo ""
        echo "   📍 $location"
        echo "   📅 $date_added"
        echo ""
        
        ((counter++))
    done
    
    # Only offer option to view full highlights if using default count
    if [[ "$user_specified_count" == "false" ]]; then
        echo ""
        echo -e "${GREEN}Would you like to view full highlights? (y/N)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            show_full_highlights "$db_path" "$count" "$sort_by" "$sort_order"
        fi
    fi
    
    # Clean up
    rm -f "$temp_csv"
}

# Function to show full highlights with gum choose
show_full_highlights() {
    local db_path="$1"
    local count="$2"
    local sort_by="${3:-location}"
    local sort_order="${4:-asc}"
    
    # Get highlights and create a choice list
    local temp_list=$(mktemp)
    
    # Build ORDER BY clause based on sort parameters
    local order_clause
    local primary_order=$(echo "$sort_order" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$sort_by" == "date_added" ]]; then
        order_clause="date_added $primary_order, location ASC, book_title ASC"
    else
        # Default: location sorting
        order_clause="location $primary_order, date_added ASC, book_title ASC"
    fi
    
    # Get highlights using DuckDB CLI
    local query_result
    query_result=$(duckdb "$db_path" "SELECT book_title, author, content, location, date_added FROM highlights ORDER BY $order_clause LIMIT $count;" 2>/dev/null)
    
    if [[ -z "$query_result" ]]; then
        echo -e "${YELLOW}No highlights found in database.${NC}"
        rm -f "$temp_list"
        return
    fi
    
    # Process results and create choice list and full content files
    local counter=1
    echo "$query_result" | tail -n +4 | head -n -1 | while IFS='│' read -r book_title author content location date_added; do
        # Clean up the pipe-separated values
        book_title=$(echo "$book_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        author=$(echo "$author" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        content=$(echo "$content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        location=$(echo "$location" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        date_added=$(echo "$date_added" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines
        [[ -z "$book_title" ]] && continue
        
        # Create short description for choice menu
        local short_desc="$content"
        if [[ ${#content} -gt 80 ]]; then
            short_desc="${content:0:80}..."
        fi
        
        # Write to choice list
        echo "$counter. $book_title - $short_desc" >> "$temp_list"
        
        # Create header and footer
        local header="$book_title"
        if [[ -n "$author" ]]; then
            header="$header by $author"
        fi
        
        local footer="$location"
        if [[ -n "$date_added" ]]; then
            footer="$footer | $date_added"
        fi
        
        # Write to full content file
        {
            echo "--- Highlight $counter ---"
            echo "$header"
            echo ""
            echo "$content"
            echo ""
            echo "$footer"
            echo "$(printf "%80s" | tr ' ' '-')"
            echo ""
        } >> "$temp_list.full"
        
        ((counter++))
    done
    
    if [[ -f "$temp_list" ]]; then
        while true; do
            local selected
            selected=$(gum choose --header "Select a highlight to view in full (or press Esc to exit):" < "$temp_list")
            
            if [[ -n "$selected" ]]; then
                # Extract the number from the selection
                local num=$(echo "$selected" | cut -d'.' -f1)
                
                # Show the full highlight
                local full_highlight
                full_highlight=$(sed -n "/--- Highlight $num ---/,/^-\{80\}$/p" "$temp_list.full")
                
                echo ""
                gum style \
                    --foreground 212 \
                    --border-foreground 212 \
                    --border double \
                    --align left \
                    --width 100 \
                    --margin "1 0" \
                    --padding "1 2" \
                    "$full_highlight"
                echo ""
            else
                break
            fi
        done
        
        # Clean up
        rm -f "$temp_list" "$temp_list.full"
    else
        echo -e "${RED}Error: Failed to create highlight list${NC}"
        return 1
    fi
}

# Main function
main() {
    # Parse global options first
    while [[ $# -gt 0 ]]; do
        case $1 in
            --database-path)
                DATABASE_PATH="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            import|show|summary)
                # Found subcommand, break to handle it
                break
                ;;
            *)
                echo -e "${RED}Error: Unknown option '$1'${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check if subcommand is provided
    if [[ $# -eq 0 ]]; then
        echo -e "${RED}Error: No subcommand provided${NC}"
        show_help
        exit 1
    fi
    
    # Check dependencies
    check_dependencies
    
    # Handle subcommands
    case $1 in
        import)
            shift
            local input_files=()
            
            # Parse import-specific options
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --database-path)
                        DATABASE_PATH="$2"
                        shift 2
                        ;;
                    -h|--help)
                        show_import_help
                        exit 0
                        ;;
                    -*)
                        echo -e "${RED}Error: Unknown option '$1' for import command${NC}"
                        show_import_help
                        exit 1
                        ;;
                    *)
                        input_files+=("$1")
                        shift
                        ;;
                esac
            done
            
            # If no files specified, use default
            if [[ ${#input_files[@]} -eq 0 ]]; then
                input_files=("$INPUT_FILE")
            fi
            
            # Process each file
            local total_files=${#input_files[@]}
            local current_file=1
            local overall_found=0
            local overall_new=0
            local overall_duplicates=0
            local initial_count
            initial_count=$(duckdb "$DATABASE_PATH" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null || echo "0")
            
            for input_file in "${input_files[@]}"; do
                if [[ $total_files -gt 1 ]]; then
                    echo -e "${YELLOW}Processing file $current_file of $total_files: $input_file${NC}"
                    echo ""
                fi
                
                # Get count before this file import
                local before_count
                before_count=$(duckdb "$DATABASE_PATH" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null || echo "0")
                
                # Show import progress for this file
                echo -e "${BLUE}Importing highlights from '$input_file' to '$DATABASE_PATH'...${NC}"
                echo "Converting myClippings format to structured data..."
                echo "Processing highlights and detecting duplicates..."
                echo "Generating import data..."
                
                # Import this file and capture the statistics
                local import_stats
                import_stats=$(import_highlights_with_stats "$input_file" "$DATABASE_PATH")
                
                # Parse the statistics from this import
                IFS=',' read -r file_found file_new file_duplicates <<< "$import_stats"
                
                # Get current count for display
                local current_count
                current_count=$(duckdb "$DATABASE_PATH" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null)
                
                # Show individual file results
                echo -e "${GREEN}✅ Import completed:${NC}"
                echo "   - $file_found quotes found in file"
                echo "   - $file_new new highlights imported"
                echo "   - $file_duplicates duplicates skipped (already in database)"
                echo "   - $current_count total highlights in database"
                
                # Add to overall totals
                overall_found=$((overall_found + file_found))
                overall_new=$((overall_new + file_new))
                overall_duplicates=$((overall_duplicates + file_duplicates))
                
                # If processing multiple files, add spacing
                if [[ $total_files -gt 1 && $current_file -lt $total_files ]]; then
                    echo ""
                fi
                
                ((current_file++))
            done
            
            # Show overall summary for multiple files
            if [[ $total_files -gt 1 ]]; then
                local final_count
                final_count=$(duckdb "$DATABASE_PATH" -csv -noheader "SELECT COUNT(*) FROM highlights;" 2>/dev/null)
                
                echo ""
                echo -e "${GREEN}📊 Overall Import Summary:${NC}"
                echo "   - $overall_found total quotes found across all files"
                echo "   - $overall_new new highlights imported"
                echo "   - $overall_duplicates duplicates skipped"
                echo "   - $final_count total highlights in database"
            fi
            ;;
            
        show)
            shift
            local show_count="$DEFAULT_SHOW_COUNT"
            local sort_by="location"
            local sort_order="asc"
            local user_specified_count="false"
            
            # Parse show-specific options
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -n|--number)
                        show_count="$2"
                        user_specified_count="true"
                        shift 2
                        ;;
                    --sort-by)
                        if [[ "$2" == "location" || "$2" == "date_added" ]]; then
                            sort_by="$2"
                        else
                            echo -e "${RED}Error: Invalid sort field '$2'. Use 'location' or 'date_added'${NC}"
                            exit 1
                        fi
                        shift 2
                        ;;
                    --sort-order)
                        if [[ "$2" == "asc" || "$2" == "desc" ]]; then
                            sort_order="$2"
                        else
                            echo -e "${RED}Error: Invalid sort order '$2'. Use 'asc' or 'desc'${NC}"
                            exit 1
                        fi
                        shift 2
                        ;;
                    --database-path)
                        DATABASE_PATH="$2"
                        shift 2
                        ;;
                    -h|--help)
                        show_show_help
                        exit 0
                        ;;
                    *)
                        echo -e "${RED}Error: Unknown option '$1' for show command${NC}"
                        show_show_help
                        exit 1
                        ;;
                esac
            done
            
            show_highlights "$DATABASE_PATH" "$show_count" "$sort_by" "$sort_order" "$user_specified_count"
            ;;
            
        summary)
            shift
            
            # Parse summary-specific options
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --database-path)
                        DATABASE_PATH="$2"
                        shift 2
                        ;;
                    -h|--help)
                        show_summary_help
                        exit 0
                        ;;
                    *)
                        echo -e "${RED}Error: Unknown option '$1' for summary command${NC}"
                        show_summary_help
                        exit 1
                        ;;
                esac
            done
            
            show_summary "$DATABASE_PATH"
            ;;
            
        *)
            echo -e "${RED}Error: Unknown subcommand '$1'${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"