#!/bin/dash
# A secure, atomic, and robust BOM/CRLF batch cleaner for PHP, HTML, CSS, JS, and text files - engineered for modern, team-based development with CI/CD and pre-commit support.
# Author: Mikhail Deynekin (mid1977@gmail.com)
# Website: https://deynekin.com
# Date: 2025-09-18 16:39 MSK
# Version: 2.01.0
# Key changes:
#   - Preserve file timestamp when no changes detected
#   - After cleaning, restore original modification time
#   - Improved dependency checks and error handling

# Strict execution environment
set -euf
export LANG=C LC_ALL=C

# Readonly script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_PID="$$"
readonly VERSION="2.01.0"
readonly SUPPORTED_EXTENSIONS="php css js txt xml htm html"
readonly MAX_FILE_SIZE=$((100 * 1024 * 1024))   # 100 MB safety limit
readonly TEMP_DIR="${TMPDIR:-/tmp}"

# Global state counters
VERBOSE=0
DRY_RUN=0
PROCESSED_COUNT=0
ERROR_COUNT=0

# Cleanup temporary files on exit or interrupt
cleanup() {
    local exit_code=${1:-$?}
    find "$TEMP_DIR" -name "${SCRIPT_NAME}.${SCRIPT_PID}.*" -type f -delete 2>/dev/null || true
    exit "$exit_code"
}
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup' EXIT

# Logging helpers
log_info()    { [ "$VERBOSE" -eq 1 ] && printf "[INFO] %s\n" "$*" >&2; }
log_warning() { [ "$VERBOSE" -eq 1 ] && printf "[WARN] %s\n" "$*" >&2; }
log_error()   { printf "[ERROR] %s\n" "$*" >&2; ERROR_COUNT=$((ERROR_COUNT + 1)); }

# Display usage
show_help() {
    cat << 'EOF'
UTF-8 BOM and Windows CRLF Cleaner
Usage: clean-bom-senior.sh [OPTIONS] [FILE...]
Options:
  -h, --help       Show this help message
  -v, --verbose    Enable detailed output
  -n, --dry-run    Preview which files would be processed
  -V, --version    Show script version
EOF
}

# Display version
show_version() {
    printf "%s version %s\n" "$SCRIPT_NAME" "$VERSION"
}

# Verify required commands and temp directory
check_dependencies() {
    local missing=""
    for cmd in find sed od grep stat mv cp touch; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] || { log_error "Missing dependencies:$missing"; return 2; }
    [ -w "$TEMP_DIR" ] || { log_error "No write access to temp dir:$TEMP_DIR"; return 3; }
    return 0
}

# Detect BOM or Windows CRLF in a file
has_bom_or_crlf() {
    local file="$1" size
    [ -r "$file" ] || return 1
    size=$(stat -c%s "$file" 2>/dev/null) || return 1
    [ "$size" -le "$MAX_FILE_SIZE" ] || return 1

    # Check UTF-8 BOM in first 3 bytes
    if od -An -tx1 -N3 "$file" 2>/dev/null | tr -d ' ' | grep -q '^efbbbf$'; then
        return 0
    fi
    # Check CRLF within first 1024 bytes
    od -An -tx1 -N1024 "$file" 2>/dev/null | tr -d ' \n' | grep -q '0d0a' && return 0

    return 1
}

# Clean a single file atomically, preserving timestamps
clean_file() {
    local file="$1"
    # Skip if not readable/writable
    if [ ! -r "$file" ] || [ ! -w "$file" ]; then
        log_error "No access to file:$file"
        return 3
    fi
    # Skip if no BOM/CRLF
    if ! has_bom_or_crlf "$file"; then
        log_info "Skip (no BOM/CRLF): $file"
        return 0
    fi

    # Prepare temp and backup
    local backup="${file}.bak.${SCRIPT_PID}"
    local temp="${TEMP_DIR}/${SCRIPT_NAME}.${SCRIPT_PID}.$$"
    umask 077 && :> "$temp"
    cp -p "$file" "$backup"

    # Perform cleaning: remove CRLF, strip BOM on first line
    sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//' "$backup" > "$temp"

    # Replace original, restore timestamp, cleanup
    if mv "$temp" "$file"; then
        touch -r "$backup" "$file"
        rm -f "$backup"
        log_info "Processed: $file"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        return 0
    else
        mv "$backup" "$file" 2>/dev/null || true
        rm -f "$temp"
        log_error "Failed processing: $file"
        return 1
    fi
}

# Find target files by supported extensions, null-delimited
find_target_files() {
    local ext expr first=1
    for ext in $SUPPORTED_EXTENSIONS; do
        if [ "$first" -eq 1 ]; then
            expr="-iname '*.$ext'"
            first=0
        else
            expr="$expr -o -iname '*.$ext'"
        fi
    done
    eval "find . -type f -size +0c -size -${MAX_FILE_SIZE}c \\( $expr \\) -print0"
}

# Parse CLI arguments and flags
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)    show_help; exit 0;;
            -V|--version) show_version; exit 0;;
            -v|--verbose) VERBOSE=1;;
            -n|--dry-run) DRY_RUN=1; VERBOSE=1;;
            --) shift; break;;
            -*) log_error "Unknown option:$1"; exit 2;;
            *) break;;
        esac
        shift
    done
    printf "%s" "$*"
}

# Main workflow
main() {
    local EXIT=0
    check_dependencies || exit $?
    set -- $(parse_arguments "$@")

    if [ $# -gt 0 ]; then
        # Process specified files
        for file in "$@"; do
            if [ "$DRY_RUN" -eq 1 ]; then
                has_bom_or_crlf "$file" && printf "Would process: %s\n" "$file"
            else
                clean_file "$file" || EXIT=1
            fi
        done
    else
        # Process all found files recursively
        while IFS= read -r -d '' file; do
            if [ "$DRY_RUN" -eq 1 ]; then
                has_bom_or_crlf "$file" && printf "Would process: %s\n" "$file"
            else
                clean_file "$file" || EXIT=1
            fi
        done < <(find_target_files)
    fi

    # Summary in verbose or dry-run mode
    [ "$VERBOSE" -eq 1 ] && printf "\nSummary: Processed=%d Errors=%d\n" \
        "$PROCESSED_COUNT" "$ERROR_COUNT"

    exit $EXIT
}

# Execute
main "$@"
