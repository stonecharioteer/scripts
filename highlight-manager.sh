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

Global Options:
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Examples:
  $0 import myClippings.txt
  $0 show -n 5
  $0 --database-path ~/custom.db import myClippings.txt
  $0 show --number 20

For subcommand-specific help:
  $0 import --help
  $0 show --help
EOF
}

# Function to show import help
show_import_help() {
    cat << EOF
highlight-manager.sh import - Import highlights from myClippings file

Usage: $0 import [options] [INPUT_FILE]

Arguments:
  INPUT_FILE    myClippings file to import (default: myClippings.txt)

Options:
  --database-path PATH    Database file path (default: $DEFAULT_DATABASE_PATH)
  -h, --help             Show this help message

Examples:
  $0 import
  $0 import myClippings.txt
  $0 import --database-path ~/custom.db myClippings.txt
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

# Function to convert myClippings to JSON first, then import
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
    
    # Parse myClippings format directly
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
    
    # Import from JSON using a simple approach
    local count=0
    local duplicates=0
    
    echo "Converting JSON to SQL inserts..."
    
    # Create a temporary SQL file with all inserts
    local temp_sql=$(mktemp)
    
    # Generate SQL inserts from JSON
    jq -r '.[] | 
        @base64 | 
        "INSERT INTO highlights (book_title, author, highlight_type, location, date_added, content, content_hash) VALUES (" +
        "'" + (.book | @sh) + "', " +
        "'" + (.author // "" | @sh) + "', " +
        "'" + (.type | @sh) + "', " +
        "'" + (.location | @sh) + "', " +
        "'" + (.date_added | @sh) + "', " +
        "'" + (.content | @sh) + "', " +
        "'" + (.content | @sha256) + "');"' "$temp_json" > "$temp_sql"
    
    # This approach is complex. Let me use a simpler Python script instead
    python3 << EOF
import json
import hashlib
import sqlite3
import sys

# Read JSON file
with open('$temp_json', 'r') as f:
    data = json.load(f)

# Connect to DuckDB using SQLite compatibility (create temporary SQLite DB)
temp_db = "/tmp/temp_import.db"
conn = sqlite3.connect(temp_db)
cursor = conn.cursor()

# Create temporary table
cursor.execute('''
CREATE TABLE IF NOT EXISTS temp_highlights (
    book_title TEXT NOT NULL,
    author TEXT,
    highlight_type TEXT NOT NULL,
    location TEXT,
    date_added TEXT,
    content TEXT NOT NULL,
    content_hash TEXT UNIQUE
)
''')

count = 0
duplicates = 0

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
    
    try:
        cursor.execute('''
        INSERT INTO temp_highlights (book_title, author, highlight_type, location, date_added, content, content_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', (book_clean, author, highlight_type, location, date_added, content_clean, content_hash))
        count += 1
    except sqlite3.IntegrityError:
        duplicates += 1

conn.commit()
conn.close()

# Print results to stderr so they don't interfere with bash
import sys
print(f"Processed {count} new entries, {duplicates} duplicates", file=sys.stderr)

# Now dump to SQL for DuckDB with explicit column names
conn = sqlite3.connect(temp_db)
cursor = conn.cursor()
cursor.execute('SELECT * FROM temp_highlights')
rows = cursor.fetchall()

with open('/tmp/import.sql', 'w') as f:
    for row in rows:
        # Escape single quotes
        escaped_row = []
        for item in row:
            if item is None:
                escaped_row.append('NULL')
            else:
                escaped_row.append("'" + str(item).replace("'", "''") + "'")
        
        f.write(f"INSERT INTO highlights (book_title, author, highlight_type, location, date_added, content, content_hash) VALUES ({', '.join(escaped_row)});\n")

conn.close()
EOF
    
    # Import the SQL into DuckDB
    if [[ -f "/tmp/import.sql" ]]; then
        # Execute the INSERT statements in DuckDB
        grep "INSERT INTO" /tmp/import.sql > /tmp/inserts_only.sql
        duckdb "$db_path" < /tmp/inserts_only.sql
        count=$(grep -c "INSERT INTO" /tmp/import.sql)
        
        # Clean up
        rm -f /tmp/temp_import.db /tmp/import.sql /tmp/inserts_only.sql
    else
        echo "Error: Failed to generate SQL imports"
        rm -f "$temp_sql"
        return 1
    fi
    
    rm -f "$temp_sql"
    
    # Clean up
    rm -f "$temp_json"
    
    echo -e "${GREEN}✅ Import completed:${NC}"
    echo "   - $count new highlights imported"
    echo "   - $duplicates duplicates skipped"
    
    # Show database stats
    local total_count
    total_count=$(duckdb "$db_path" "SELECT COUNT(*) FROM highlights;" | tail -n 1)
    echo "   - $total_count total highlights in database"
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
            import|show)
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
            local input_file="$INPUT_FILE"
            
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
                        input_file="$1"
                        shift
                        ;;
                esac
            done
            
            import_highlights "$input_file" "$DATABASE_PATH"
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
            
        *)
            echo -e "${RED}Error: Unknown subcommand '$1'${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"