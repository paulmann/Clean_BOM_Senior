#!/bin/bash

#===============================================================================
# UTF-8 BOM and CRLF Cleaner - Professional Source Code Sanitizer
#===============================================================================
#
# File:         clean-bom-senior.sh
# Version:      2.06.4
# Date:         2025-09-28 22:55 MSK
# Author:       Mikhail Deynekin <mid1977@gmail.com>
# Website:      https://deynekin.com
# Repository:   https://github.com/paulmann/Clean_BOM_Senior
# License:      MIT License
#
# Description:
#   A robust, production-ready shell utility that safely detects and removes
#   invisible UTF-8 Byte Order Marks (BOM) and Windows CRLF line endings from
#   PHP, CSS, JS, TXT, XML, HTM, and HTML files. Designed for cross-platform
#   development teams and CI/CD environments.
#
# Key Features:
#   • Safe atomic operations with backup and rollback support
#   • Preserves original file ownership, permissions, and timestamps
#   • Recursive directory scanning with glob pattern support
#   • Comprehensive error handling and detailed logging
#   • Dry-run mode for preview without modifications
#   • Statistics tracking and file type categorization
#   • CI/CD and Git hooks integration ready
#   • POSIX-compliant shell script for maximum portability
#
# Use Cases:
#   • Prevent PHP fatal errors with namespace/declare(strict_types=1)
#   • Clean up mixed editor environments (Windows/Unix)
#   • Automated code hygiene in deployment pipelines
#   • Pre-commit hooks for consistent encoding standards
#
# Requirements:
#   • POSIX-compliant shell (bash, sh, dash)
#   • Standard Unix utilities (find, sed, od, grep, stat, mv, cp, touch, chown, chmod)
#   • Write access to temporary directory
#
# Installation:
#   chmod +x clean-bom-senior.sh
#   ./clean-bom-senior.sh --help
#
# Examples:
#   ./clean-bom-senior.sh                    # Process all supported files recursively
#   ./clean-bom-senior.sh --verbose          # Enable detailed output
#   ./clean-bom-senior.sh --dry-run          # Preview changes without modification
#   ./clean-bom-senior.sh file1.php file2.js # Process specific files
#   ./clean-bom-senior.sh -v src/            # Verbose mode on directory
#
# Exit Codes:
#   0 - Success, all files processed without errors
#   1 - Some files processed with errors (partial success)
#   2 - Invalid command line arguments
#   3 - Missing dependencies or insufficient permissions
#   4 - Critical system error (temp directory, etc.)
#
#===============================================================================

# Strict execution environment for reliability
set -euf
export LANG=C LC_ALL=C

# Color codes for enhanced terminal output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_RESET='\033[0m'

# Script metadata and configuration constants
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_PID="$$"
readonly VERSION="2.06.4"
readonly SUPPORTED_EXTENSIONS="php css js txt xml htm html"
readonly MAX_FILE_SIZE=$((100 * 1024 * 1024)) # 100 MB limit
readonly TEMP_DIR="${TMPDIR:-/tmp}"

# Global runtime flags and counters
VERBOSE=0
DRY_RUN=0
SHOW_HELP=0
SHOW_VERSION=0
PROCESSED_COUNT=0
ERROR_COUNT=0
BOM_REMOVED_COUNT=0
CRLF_FIXED_COUNT=0
SKIPPED_COUNT=0
START_TIME=0

# Associative arrays for detailed statistics tracking
declare -A FILE_TYPE_COUNTS
declare -A ERROR_TYPES
declare -a PROCESSED_FILES
declare -a REMAINING_ARGS

# Initialize all statistical counters to zero
initialize_statistics() {
	for ext in $SUPPORTED_EXTENSIONS; do
		FILE_TYPE_COUNTS["$ext"]=0
	done
	FILE_TYPE_COUNTS["other"]=0
	ERROR_TYPES["access"]=0
	ERROR_TYPES["size"]=0
	ERROR_TYPES["processing"]=0
	ERROR_TYPES["other"]=0
}

# Cleanup temporary files on exit or interrupt signals
cleanup() {
	local exit_code=${1:-$?}
	find "$TEMP_DIR" -name "${SCRIPT_NAME}.${SCRIPT_PID}.*" -type f -delete 2>/dev/null || true
	exit "$exit_code"
}

# Set up signal handlers for graceful cleanup
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup' EXIT

# Enhanced logging functions with timestamps and color coding
get_timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
	if [ -t 2 ]; then
		printf "${COLOR_BLUE}[%s INFO]${COLOR_RESET} %s\n" "$(get_timestamp)" "$*" >&2
	else
		printf "[%s INFO] %s\n" "$(get_timestamp)" "$*" >&2
	fi
}

log_warning() {
	if [ "$VERBOSE" -eq 1 ]; then
		if [ -t 2 ]; then
			printf "${COLOR_YELLOW}[%s WARN]${COLOR_RESET} %s\n" "$(get_timestamp)" "$*" >&2
		else
			printf "[%s WARN] %s\n" "$(get_timestamp)" "$*" >&2
		fi
	fi
}

log_error() {
	if [ -t 2 ]; then
		printf "${COLOR_RED}[%s ERROR]${COLOR_RESET} %s\n" "$(get_timestamp)" "$*" >&2
	else
		printf "[%s ERROR] %s\n" "$(get_timestamp)" "$*" >&2
	fi
	ERROR_COUNT=$((ERROR_COUNT + 1))
}

log_success() {
	if [ "$VERBOSE" -eq 1 ]; then
		if [ -t 2 ]; then
			printf "${COLOR_GREEN}[%s SUCCESS]${COLOR_RESET} %s\n" "$(get_timestamp)" "$*" >&2
		else
			printf "[%s SUCCESS] %s\n" "$(get_timestamp)" "$*" >&2
		fi
	fi
}

log_processing() {
	if [ "$VERBOSE" -eq 1 ]; then
		if [ -t 2 ]; then
			printf "${COLOR_CYAN}[%s PROCESSING]${COLOR_RESET} %s\n" "$(get_timestamp)" "$*" >&2
		else
			printf "[%s PROCESSING] %s\n" "$(get_timestamp)" "$*" >&2
		fi
	fi
}

# Display comprehensive help information
show_help() {
	cat << 'EOF'
UTF-8 BOM and Windows CRLF Cleaner - Professional Source Code Sanitizer

USAGE
    clean-bom-senior.sh [OPTIONS] [FILE...]

DESCRIPTION
    Safely detects and removes invisible UTF-8 Byte Order Marks (BOM) and 
    Windows CRLF line endings from source code and text files. Designed for
    PHP developers working in multi-editor, cross-platform environments.

OPTIONS
    -h, --help      Show this help message and exit
    -v, --verbose   Enable detailed output and processing logs
    -n, --dry-run   Preview which files would be processed (no modifications)
    -V, --version   Display script version information

SUPPORTED FILE TYPES
    Extensions: php, css, js, txt, xml, htm, html
    Max file size: 100 MB per file

EXAMPLES
    clean-bom-senior.sh                     Process all files recursively
    clean-bom-senior.sh --verbose           Verbose mode with detailed logs
    clean-bom-senior.sh --dry-run           Preview mode (no file changes)
    clean-bom-senior.sh file1.php file2.js Process specific files only
    clean-bom-senior.sh -v src/             Verbose processing of src/ directory

FILE PRESERVATION
    • Original file ownership (user/group) is preserved
    • File permissions (mode) remain unchanged
    • Timestamps are maintained for unmodified files
    • Atomic operations ensure data integrity

EXIT CODES
    0  Success - all files processed without errors
    1  Partial success - some files had processing errors
    2  Invalid command line arguments
    3  Missing dependencies or insufficient permissions

NOTES
    • Files are processed atomically with backup and rollback support
    • Only files containing BOM or CRLF are actually modified
    • Suitable for CI/CD integration and pre-commit hooks
    • Works with any user privileges (preserves original ownership)

For more information, visit: https://github.com/paulmann/Clean_BOM_Senior
EOF
}

# Display version and build information
show_version() {
	printf "%s version %s\n" "$SCRIPT_NAME" "$VERSION"
	printf "Author: Mikhail Deynekin <mid1977@gmail.com>\n"
	printf "Website: https://deynekin.com\n"
}

# Verify system dependencies and environment
check_dependencies() {
	local missing=""
	for cmd in find sed od grep stat mv cp touch chown chmod; do
		command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
	done
	if [ -n "$missing" ]; then
		log_error "Missing required commands:$missing"
		return 2
	fi
	if [ ! -w "$TEMP_DIR" ]; then
		log_error "No write access to temp directory: $TEMP_DIR"
		return 3
	fi
	return 0
}

# Extract file extension in lowercase
get_file_extension() {
	local file="$1"
	local extension="${file##*.}"
	printf "%s" "$extension" | tr '[:upper:]' '[:lower:]'
}

# Categorize file by supported extension types
categorize_file() {
	local file="$1"
	local extension
	extension=$(get_file_extension "$file")
	for ext in $SUPPORTED_EXTENSIONS; do
		if [ "$extension" = "$ext" ]; then
			printf "%s" "$ext"
			return 0
		fi
	done
	printf "other"
}

# Fast detection of BOM or CRLF presence in file
has_bom_or_crlf() {
	local file="$1" size bom_detected=0 crlf_detected=0
	if [ ! -r "$file" ]; then
		return 1
	fi
	size=$(stat -c%s "$file" 2>/dev/null) || return 1
	if [ "$size" -gt "$MAX_FILE_SIZE" ]; then
		return 1
	fi

	# Check UTF-8 BOM in first 3 bytes (EF BB BF)
	if od -An -tx1 -N3 "$file" 2>/dev/null | tr -d ' ' | grep -q '^efbbbf$'; then
		bom_detected=1
	fi

	# Check CRLF in first 1024 bytes (0D 0A pattern)
	if od -An -tx1 -N1024 "$file" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
		crlf_detected=1
	fi

	# Return true if either issue is found
	if [ "$bom_detected" -eq 1 ] || [ "$crlf_detected" -eq 1 ]; then
		return 0
	else
		return 1
	fi
}

# Generate detailed report of file encoding issues
get_file_issues() {
	local file="$1" issues=""

	# Check for UTF-8 BOM signature
	if od -An -tx1 -N3 "$file" 2>/dev/null | tr -d ' ' | grep -q '^efbbbf$'; then
		issues="BOM"
	fi

	# Check for Windows CRLF line endings
	if od -An -tx1 -N1024 "$file" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
		if [ -n "$issues" ]; then
			issues="${issues}+CRLF"
		else
			issues="CRLF"
		fi
	fi

	printf "%s" "$issues"
}

# Get file ownership and permission information
get_file_attributes() {
	local file="$1"
	local uid gid mode
	
	# Get file stats in format: uid gid mode
	if command -v stat >/dev/null 2>&1; then
		# Use stat command (works on most modern systems)
		uid=$(stat -c%u "$file" 2>/dev/null) || return 1
		gid=$(stat -c%g "$file" 2>/dev/null) || return 1  
		mode=$(stat -c%a "$file" 2>/dev/null) || return 1
	else
		# Fallback to ls parsing (less reliable but more portable)
		local ls_output
		ls_output=$(ls -ln "$file" 2>/dev/null) || return 1
		uid=$(echo "$ls_output" | awk '{print $3}')
		gid=$(echo "$ls_output" | awk '{print $4}')
		mode=$(echo "$ls_output" | awk '{print $1}' | tail -c4)
	fi
	
	printf "%s %s %s" "$uid" "$gid" "$mode"
}

# Restore file ownership and permissions
restore_file_attributes() {
	local file="$1" uid="$2" gid="$3" mode="$4"
	
	# Restore ownership (only if we have permission)
	if [ "$(id -u)" -eq 0 ] || [ "$(id -u)" -eq "$uid" ]; then
		chown "$uid:$gid" "$file" 2>/dev/null || {
			log_warning "Could not restore ownership for: $file"
		}
	fi
	
	# Restore permissions
	chmod "$mode" "$file" 2>/dev/null || {
		log_warning "Could not restore permissions for: $file"
	}
}

# Atomic file cleaning with full attribute preservation
clean_file() {
	local file="$1" file_category issues
	local orig_uid orig_gid orig_mode

	# Verify file accessibility
	if [ ! -r "$file" ]; then
		log_error "Cannot read file: $file"
		ERROR_TYPES["access"]=$((ERROR_TYPES["access"] + 1))
		return 3
	fi

	if [ ! -w "$file" ]; then
		log_error "Cannot write to file: $file"
		ERROR_TYPES["access"]=$((ERROR_TYPES["access"] + 1))
		return 3
	fi

	# Skip files without BOM/CRLF issues
	if ! has_bom_or_crlf "$file"; then
		log_processing "No issues detected, skipping: $file"
		SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
		return 0
	fi

	# Gather detailed issue information for logging
	issues=$(get_file_issues "$file")
	file_category=$(categorize_file "$file")
	log_processing "Processing: $file (Issues: $issues, Type: $file_category)"

	# Store original file attributes
	local attr_info
	attr_info=$(get_file_attributes "$file")
	if [ $? -ne 0 ]; then
		log_error "Cannot get file attributes: $file"
		ERROR_TYPES["processing"]=$((ERROR_TYPES["processing"] + 1))
		return 4
	fi
	
	read -r orig_uid orig_gid orig_mode <<< "$attr_info"

	# Prepare secure temporary and backup files
	local backup="${file}.bak.${SCRIPT_PID}"
	local temp="${TEMP_DIR}/${SCRIPT_NAME}.${SCRIPT_PID}.$$"

	# Create temporary file with secure permissions
	umask 077 && :> "$temp"

	# Create backup preserving attributes
	if ! cp "$file" "$backup"; then
		log_error "Failed to create backup: $file"
		ERROR_TYPES["processing"]=$((ERROR_TYPES["processing"] + 1))
		rm -f "$temp"
		return 4
	fi

	# Perform cleaning: remove CRLF endings, strip BOM from first line
	if ! sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//' "$backup" > "$temp"; then
		log_error "Failed to process file content: $file"
		ERROR_TYPES["processing"]=$((ERROR_TYPES["processing"] + 1))
		rm -f "$backup" "$temp"
		return 5
	fi

	# Atomic replacement with full attribute preservation
	if mv "$temp" "$file"; then
		# Restore all original attributes: ownership, permissions, timestamps
		restore_file_attributes "$file" "$orig_uid" "$orig_gid" "$orig_mode"
		touch -r "$backup" "$file"
		rm -f "$backup"

		# Update comprehensive statistics
		PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
		FILE_TYPE_COUNTS["$file_category"]=$((FILE_TYPE_COUNTS["$file_category"] + 1))
		PROCESSED_FILES+=("$file")

		# Track specific issue types fixed
		case "$issues" in
			*BOM*) BOM_REMOVED_COUNT=$((BOM_REMOVED_COUNT + 1)) ;;
		esac
		case "$issues" in
			*CRLF*) CRLF_FIXED_COUNT=$((CRLF_FIXED_COUNT + 1)) ;;
		esac

		log_success "Successfully processed: $file (Fixed: $issues)"
		return 0
	else
		# Rollback on failure
		mv "$backup" "$file" 2>/dev/null || true
		rm -f "$temp"
		log_error "Failed to replace original file: $file"
		ERROR_TYPES["processing"]=$((ERROR_TYPES["processing"] + 1))
		return 1
	fi
}

# Find target files using supported extensions with size limits
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

# Parse and validate command line arguments - modifies global variables directly
parse_arguments() {
	# Clear the global remaining arguments array
	REMAINING_ARGS=()
	
	while [ $# -gt 0 ]; do
		case "$1" in
			-h|--help) 
				SHOW_HELP=1
				;;
			-V|--version) 
				SHOW_VERSION=1
				;;
			-v|--verbose) 
				VERBOSE=1
				;;
			-n|--dry-run) 
				DRY_RUN=1
				VERBOSE=1
				;;
			--) 
				shift
				# Safe array expansion - add all remaining arguments
				while [ $# -gt 0 ]; do
					REMAINING_ARGS+=("$1")
					shift
				done
				break
				;;
			-*) 
				log_error "Unknown option: $1"
				exit 2
				;;
			*) 
				# Add all remaining arguments to array
				while [ $# -gt 0 ]; do
					REMAINING_ARGS+=("$1")
					shift
				done
				break
				;;
		esac
		shift
	done
}

# Display comprehensive processing statistics and summary
display_statistics() {
	local elapsed end_time
	end_time=$(date +%s)
	elapsed=$((end_time - START_TIME))

	# Use colors only if output is to terminal
	if [ -t 2 ]; then
		printf "\n${COLOR_MAGENTA}=== PROCESSING SUMMARY ===${COLOR_RESET}\n" >&2
	else
		printf "\n=== PROCESSING SUMMARY ===\n" >&2
	fi
	
	printf "Execution time: %d seconds\n" "$elapsed" >&2
	printf "Files processed: %d\n" "$PROCESSED_COUNT" >&2
	printf "Files skipped (clean): %d\n" "$SKIPPED_COUNT" >&2
	printf "Errors encountered: %d\n" "$ERROR_COUNT" >&2

	if [ "$PROCESSED_COUNT" -gt 0 ]; then
		if [ -t 2 ]; then
			printf "\n${COLOR_CYAN}--- Issues Fixed ---${COLOR_RESET}\n" >&2
		else
			printf "\n--- Issues Fixed ---\n" >&2
		fi
		printf "BOM signatures removed: %d\n" "$BOM_REMOVED_COUNT" >&2
		printf "CRLF line endings fixed: %d\n" "$CRLF_FIXED_COUNT" >&2

		if [ -t 2 ]; then
			printf "\n${COLOR_CYAN}--- File Type Distribution ---${COLOR_RESET}\n" >&2
		else
			printf "\n--- File Type Distribution ---\n" >&2
		fi
		for ext in $SUPPORTED_EXTENSIONS; do
			if [ "${FILE_TYPE_COUNTS["$ext"]}" -gt 0 ]; then
				printf ".%s files: %d\n" "$ext" "${FILE_TYPE_COUNTS["$ext"]}" >&2
			fi
		done
		if [ "${FILE_TYPE_COUNTS["other"]}" -gt 0 ]; then
			printf "Other files: %d\n" "${FILE_TYPE_COUNTS["other"]}" >&2
		fi
	fi

	if [ "$ERROR_COUNT" -gt 0 ]; then
		if [ -t 2 ]; then
			printf "\n${COLOR_RED}--- Error Breakdown ---${COLOR_RESET}\n" >&2
		else
			printf "\n--- Error Breakdown ---\n" >&2
		fi
		printf "Access errors: %d\n" "${ERROR_TYPES["access"]}" >&2
		printf "File size errors: %d\n" "${ERROR_TYPES["size"]}" >&2
		printf "Processing errors: %d\n" "${ERROR_TYPES["processing"]}" >&2
		printf "Other errors: %d\n" "${ERROR_TYPES["other"]}" >&2
	fi

	if [ "$DRY_RUN" -eq 1 ] && [ "$PROCESSED_COUNT" -gt 0 ]; then
		if [ -t 2 ]; then
			printf "\n${COLOR_YELLOW}--- Files That Would Be Processed ---${COLOR_RESET}\n" >&2
		else
			printf "\n--- Files That Would Be Processed ---\n" >&2
		fi
		printf "%s\n" "${PROCESSED_FILES[@]}" >&2
	fi

	if [ -t 2 ]; then
		printf "\n${COLOR_GREEN}Processing completed at: %s${COLOR_RESET}\n" "$(get_timestamp)" >&2
	else
		printf "\nProcessing completed at: %s\n" "$(get_timestamp)" >&2
	fi
}

# Display startup greeting and configuration information
show_greeting() {
	if [ -t 2 ]; then
		printf "\n${COLOR_MAGENTA}=== UTF-8 BOM & CRLF Cleaner v%s ===${COLOR_RESET}\n" "$VERSION" >&2
		printf "${COLOR_BLUE}Author:${COLOR_RESET} Mikhail Deynekin (mid1977@gmail.com)\n" >&2
		printf "${COLOR_BLUE}Website:${COLOR_RESET} https://deynekin.com\n" >&2
		printf "${COLOR_BLUE}Started:${COLOR_RESET} %s\n" "$(get_timestamp)" >&2
		
		printf "\n${COLOR_CYAN}--- Configuration ---${COLOR_RESET}\n" >&2
		printf "Verbose mode: %s\n" "$([ "$VERBOSE" -eq 1 ] && echo "ENABLED" || echo "DISABLED")" >&2
		printf "Dry-run mode: %s\n" "$([ "$DRY_RUN" -eq 1 ] && echo "ENABLED" || echo "DISABLED")" >&2
	else
		printf "\n=== UTF-8 BOM & CRLF Cleaner v%s ===\n" "$VERSION" >&2
		printf "Author: Mikhail Deynekin (mid1977@gmail.com)\n" >&2
		printf "Website: https://deynekin.com\n" >&2
		printf "Started: %s\n" "$(get_timestamp)" >&2
		
		printf "\n--- Configuration ---\n" >&2
		printf "Verbose mode: %s\n" "$([ "$VERBOSE" -eq 1 ] && echo "ENABLED" || echo "DISABLED")" >&2
		printf "Dry-run mode: %s\n" "$([ "$DRY_RUN" -eq 1 ] && echo "ENABLED" || echo "DISABLED")" >&2
	fi
	
	printf "Supported extensions: %s\n" "$SUPPORTED_EXTENSIONS" >&2
	printf "Maximum file size: %d MB\n" "$((MAX_FILE_SIZE / 1024 / 1024))" >&2
	
	if [ -t 2 ]; then
		printf "\n${COLOR_CYAN}--- Operation Mode ---${COLOR_RESET}\n" >&2
	else
		printf "\n--- Operation Mode ---\n" >&2
	fi
	
	if [ "$DRY_RUN" -eq 1 ]; then
		printf "• Scanning files for UTF-8 BOM and CRLF issues\n" >&2
		printf "• Showing which files need cleaning\n" >&2
		if [ -t 2 ]; then
			printf "• ${COLOR_YELLOW}NO FILES WILL BE MODIFIED${COLOR_RESET} (preview mode)\n" >&2
		else
			printf "• NO FILES WILL BE MODIFIED (preview mode)\n" >&2
		fi
	else
		printf "• Scanning files for UTF-8 BOM and CRLF issues\n" >&2
		printf "• Removing invisible UTF-8 BOM signatures\n" >&2
		printf "• Converting Windows CRLF to Unix LF\n" >&2
		printf "• Preserving file ownership, permissions, and timestamps\n" >&2
		printf "• Creating backup copies during processing\n" >&2
	fi
	
	if [ -t 2 ]; then
		printf "\n${COLOR_GREEN}Starting file processing...${COLOR_RESET}\n\n" >&2
	else
		printf "\nStarting file processing...\n\n" >&2
	fi
}

# Main processing workflow and entry point
main() {
	local EXIT=0
	
	START_TIME=$(date +%s)

	# Initialize statistics tracking
	initialize_statistics
	
	# Verify system requirements
	check_dependencies || exit $?
	
	# Parse command line arguments - this modifies global variables directly
	parse_arguments "$@"
	
	# Handle help and version requests first
	if [ "$SHOW_HELP" -eq 1 ]; then
		show_help
		exit 0
	fi
	
	if [ "$SHOW_VERSION" -eq 1 ]; then
		show_version
		exit 0
	fi

	# Display startup information
	show_greeting

	if [ "${#REMAINING_ARGS[@]}" -gt 0 ]; then
		# Process user-specified files
		log_info "Specific file mode: Processing ${#REMAINING_ARGS[@]} file(s)"
		
		for file in "${REMAINING_ARGS[@]}"; do
			if [ ! -f "$file" ]; then
				log_error "File not found: $file"
				ERROR_TYPES["access"]=$((ERROR_TYPES["access"] + 1))
				continue
			fi
			
			if [ "$DRY_RUN" -eq 1 ]; then
				if has_bom_or_crlf "$file"; then
					issues=$(get_file_issues "$file")
					file_category=$(categorize_file "$file")
					PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
					FILE_TYPE_COUNTS["$file_category"]=$((FILE_TYPE_COUNTS["$file_category"] + 1))
					PROCESSED_FILES+=("$file")
					printf "Would process: %s (Issues: %s, Type: %s)\n" "$file" "$issues" "$file_category" >&2
				else
					SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
					log_processing "Would skip (clean): $file"
				fi
			else
				clean_file "$file" || EXIT=1
			fi
		done
	else
		# Recursive processing of all supported files - FIXED: use process substitution
		log_info "Recursive mode: Scanning for files with extensions: $SUPPORTED_EXTENSIONS"
		
		local file_count=0
		
		# CRITICAL FIX: Use process substitution instead of pipe to preserve variables
		while IFS= read -r -d '' file; do
			file_count=$((file_count + 1))
			
			if [ "$DRY_RUN" -eq 1 ]; then
				if has_bom_or_crlf "$file"; then
					issues=$(get_file_issues "$file")
					file_category=$(categorize_file "$file")
					PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
					FILE_TYPE_COUNTS["$file_category"]=$((FILE_TYPE_COUNTS["$file_category"] + 1))
					PROCESSED_FILES+=("$file")
					printf "Would process: %s (Issues: %s, Type: %s)\n" "$file" "$issues" "$file_category" >&2
				else
					SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
				fi
			else
				clean_file "$file" || EXIT=1
			fi
		done < <(find_target_files)
		
		if [ "$file_count" -eq 0 ]; then
			log_info "No files found with supported extensions for processing"
		fi
	fi

	# Display comprehensive final statistics
	display_statistics

	exit $EXIT
}

# Script execution entry point
main "$@"
