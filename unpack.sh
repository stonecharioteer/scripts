#!/usr/bin/env bash

set -euo pipefail

# --- Constants ---
readonly PROG_NAME="${0##*/}"

# --- Help Message ---
show_help() {
cat << EOF
Usage: $PROG_NAME [-o|--output <dir>] <archive>

Unpacks a wide variety of archive files.

Options:
  -o, --output <dir>  Specify the output directory for extraction.
  -h, --help          Display this help and exit.

Supported formats:
  .zip, .jar, .war
  .tar, .tar.gz, .tgz, .tar.bz2, .tbz, .tbz2, .tar.xz, .txz
  .rar
  .7z
EOF
}

# --- Dependency Checker ---
check_deps() {
  local missing_deps=()
  for dep in "$@"; do
    if ! command -v "$dep" &>/dev/null; then
      missing_deps+=("$dep")
    fi
  done

  if [ ${#missing_deps[@]} -gt 0 ]; then
    printf "Error: Missing required dependencies: %s\n" "${missing_deps[*]}" >&2
    return 1
  fi
}

# --- Main Logic ---
main() {
  local output_dir=""
  local archive_file=""

  # --- Argument Parsing ---
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        show_help
        exit 0
        ;;
      -o | --output)
        if [[ -z "${2-}" ]]; then
          printf "Error: --output option requires an argument.\n" >&2
          exit 1
        fi
        output_dir="$2"
        shift 2
        ;;
      -*)
        printf "Error: Unknown option: %s\n" "$1" >&2
        show_help >&2
        exit 1
        ;;
      *)
        if [[ -n "$archive_file" ]]; then
          printf "Error: Only one archive file can be specified.\n" >&2
          show_help >&2
          exit 1
        fi
        archive_file="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$archive_file" ]]; then
    printf "Error: No archive file specified.\n" >&2
    show_help >&2
    exit 1
  fi

  if [[ ! -f "$archive_file" ]]; then
    printf "Error: File not found: %s\n" "$archive_file" >&2
    exit 1
  fi

  # --- Extraction Logic ---
  local filename
  filename=$(basename -- "$archive_file")

  local extraction_cmd=()
  local required_dep=""

  case "$filename" in
    *.tar.gz | *.tgz | *.tar.bz2 | *.tbz | *.tbz2 | *.tar.xz | *.txz | *.tar)
      required_dep="tar"
      extraction_cmd=("tar" "xf" "$archive_file")
      ;;
    *.zip | *.jar | *.war)
      required_dep="unzip"
      extraction_cmd=("unzip" "$archive_file")
      ;;
    *.rar)
      required_dep="unrar"
      extraction_cmd=("unrar" "x" "$archive_file")
      ;;
    *.7z)
      required_dep="7z"
      extraction_cmd=("7z" "x" "$archive_file")
      ;;
    *)
      printf "Error: Unsupported archive format for '%s'\n" "$filename" >&2
      exit 1
      ;;
  esac

  check_deps "$required_dep"

  if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    case "$required_dep" in
      tar)
        extraction_cmd+=("-C" "$output_dir")
        ;;
      unzip)
        extraction_cmd+=("-d" "$output_dir")
        ;;
      unrar)
        # unrar creates a directory by default, so we move the contents
        local temp_dir
        temp_dir=$(mktemp -d)
        printf "Running command: %s\n" "${extraction_cmd[*]}"
        if (cd "$temp_dir" && "${extraction_cmd[@]}"); then
            mv "$temp_dir"/* "$output_dir"/
            rmdir "$temp_dir"
        else
            printf "Error: Failed to extract with unrar.\n" >&2
            exit 1
        fi
        extraction_cmd=() # Command already executed
        ;;
      7z)
        extraction_cmd+=("-o$output_dir")
        ;;
    esac
  fi

  printf "Unpacking '%s'...\n" "$filename"
  if [[ ${#extraction_cmd[@]} -gt 0 ]]; then
    printf "Running command: %s\n" "${extraction_cmd[*]}"
    if ! "${extraction_cmd[@]}"; then
      printf "Error: Failed to unpack '%s'.\n" "$filename" >&2
      exit 1
    fi
  fi
  printf "Successfully unpacked '%s'.\n" "$filename"
}

main "$@"