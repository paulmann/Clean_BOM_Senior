#!/usr/bin/env bash
#===============================================================================
# Clean BOM Senior — UTF-8 BOM & CRLF Cleaner with Smart BOM Policy
#===============================================================================
#
# File:         clean-bom-senior.sh   (reference implementation)
# Version:      3.0.0
# Author:       Mikhail Deynekin <mid1977@gmail.com>
# Website:      https://deynekin.com
# Repository:   https://github.com/paulmann/Clean_BOM_Senior
# License:      MIT
#
# DESCRIPTION
#   Detects and removes invisible UTF-8 Byte Order Marks (BOM) and normalises
#   Windows CRLF line endings in text/source files — without ever corrupting a
#   file for which the BOM is load-bearing.
#
#   v3 introduces the Smart BOM Policy (see `--help bom-policy` and
#   docs/SMART-BOM.md): before stripping anything, the tool classifies the
#   file by its ACTUAL BYTES —
#     • UTF-16/UTF-32 BOMs are structurally required → file is never touched;
#     • binary files (NUL bytes)                     → never touched;
#     • invalid UTF-8                                → never touched unless
#                                                      --force is given;
#     • UTF-8 BOM in "sensitive" text (txt/csv/ps1…, non-ASCII content) may be
#       required by Excel, legacy Notepad or Windows PowerShell 5.1 → kept by
#       default, with an explanation; --force strips it;
#     • UTF-8 BOM in code (php/js/css/html/xml…) is harmful or useless →
#       stripped.
#
#   Detection is byte-exact over the WHOLE file. (v2 probed fixed hex windows,
#   which produced both false positives and false negatives — CHANGELOG.md.)
#
# PORTABILITY
#   bash >= 3.2 (the default bash on macOS works), GNU and BSD userland:
#   Linux, macOS, *BSD, WSL, Git Bash/MSYS. No associative arrays, no
#   bash-4-only expansions.
#   Required: find sed awk od grep stat tail wc tr mv cp touch chmod mktemp
#             date basename dirname id
#   Optional: iconv (UTF-8 validation), chown (root only), curl|wget
#             (--update/--check-update), git (--git), node (--self-test JSON
#             validation nicety).
#
# EXIT CODES
#   0   success (nothing to do, or everything cleaned)
#   1   finished, but some files could not be processed (per-file errors),
#       or --strict saw kept/protected files
#   2   invalid command line usage
#   3   environment problem (missing dependency, unusable temp dir, network
#       failure during --check-update, npm-managed install during --update)
#   4   critical internal error
#   10  --check mode: issues found (files need cleaning) — CI gate
#   11  --check-update: a newer version is available
#
# OUTPUT STREAMS
#   stderr : human log + summary (the v2 contract)
#   stdout : machine output only (--json, --help, --version, --completion)
#
#===============================================================================

set -euo pipefail
export LC_ALL=C LANG=C

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------
VERSION="3.0.0"
SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_PID="$$"
REPO_SLUG_DEFAULT="paulmann/Clean_BOM_Senior"

# Extensions cleaned by default (v2-compatible set).
EXTENSIONS_DEFAULT="php css js txt xml htm html"

# Extensions whose UTF-8 BOM may be REQUIRED by mainstream Windows consumers
# (Excel / legacy Notepad / csv readers; Windows PowerShell 5.1). For these,
# the BOM is kept by default when the content is non-ASCII. Overrides:
# --force, --bom-policy=strip, --sensitive-ext "".
SENSITIVE_DEFAULT="txt csv tsv ps1 psm1 psd1"

# Extensions where a UTF-8 BOM is known-harmful or useless: always safe to
# strip (parsers of these formats either reject or ignore the BOM).
STRIP_ALWAYS="php phtml phps inc php3 php4 php5 php7 php8 \
js mjs cjs jsx ts tsx vue json jsonc json5 \
css scss sass less htm html xhtml xml svg xsl xslt \
mustache hbs twig blade sh bash zsh fish py rb pl lua sql yaml yml toml"

# Directories never descended into by default (VCS internals / dependencies).
EXCLUDE_DIRS_DEFAULT=".git .svn .hg node_modules"

MAX_SIZE_DEFAULT=$((100 * 1024 * 1024))

EXIT_OK=0
EXIT_FILE_ERRORS=1
EXIT_USAGE=2
EXIT_ENV=3
EXIT_INTERNAL=4
EXIT_CHECK_FOUND=10
EXIT_UPDATE_AVAILABLE=11

# A literal CR byte, used to build byte-exact grep/sed patterns. Portable
# alternative to '\r' escapes, which BSD sed does not understand.
CR_BYTE="$(printf '\rX')"
CR_BYTE="${CR_BYTE%X}"

#------------------------------------------------------------------------------
# Runtime state (globals; bash 3.2 compatible — no associative arrays)
#------------------------------------------------------------------------------
VERBOSE=0
QUIET=0
SILENT=0
DRY_RUN=0
CHECK_MODE=0
JSON_OUT=0
FORCE=0
STRICT=0
SHOW_HELP=0
HELP_TOPIC=""
SHOW_VERSION=0
SHOW_COMPLETION=0
SELF_TEST=0
DO_CHECK_UPDATE=0
DO_UPDATE=0

BOM_POLICY="auto"                 # auto | strip | keep
NO_BOM_CLEAR=0                    # v2 compat: --no-bom-clear
NO_CRLF_NORMALIZE=0               # v2 compat: --no-rn-normalize / --no-crlf-normalize
EXTENSIONS="$EXTENSIONS_DEFAULT"
SENSITIVE_EXTS="$SENSITIVE_DEFAULT"
USER_EXCLUDE_DIRS=""              # --exclude-dir values (survive --no-default-excludes)
EXCLUDE_PATTERNS=""               # newline-separated globs (--exclude)
EXCLUDE_DIRS="$EXCLUDE_DIRS_DEFAULT"
USE_DEFAULT_EXCLUDES=1
MAX_SIZE="$MAX_SIZE_DEFAULT"
GIT_MODE=0
COLOR_MODE="auto"                 # auto | always | never
LOG_FILE=""
BACKUP=0
BACKUP_DIR=""
KEEP_MTIME=1                      # preserve timestamps of modified files (contract)

# Counters
SCANNED_COUNT=0
CHANGED_COUNT=0
WOULD_CHANGE_COUNT=0
CLEAN_COUNT=0
KEPT_BOM_COUNT=0
PROTECTED_UTF16_COUNT=0
PROTECTED_BINARY_COUNT=0
PROTECTED_INVALID_COUNT=0
SKIPPED_SIZE_COUNT=0
BOM_REMOVED_COUNT=0
CRLF_FIXED_COUNT=0
ERROR_COUNT=0
ERR_ACCESS=0
ERR_PROCESSING=0
ERR_OTHER=0
FILE_ERRORS=0
START_TIME=0
START_TIME_ISO=""

# Aggregates built as newline-separated strings (bash 3.2 safe).
CHANGED_EXT_LINES=""              # one extension per changed file
AFFECTED_FILES=""                 # changed / would-change paths
JSON_ENTRIES=""                     # one compact JSON object per line
TEMP_FILES=""                     # temp files to remove on exit

WARNED_ICONV=0

# Per-file analysis results (set by analyze_file)
A_ENC="none"          # none|utf8-bom|utf16le|utf16be|utf32le|utf32be
A_HAS_CRLF=0
A_BINARY=0
A_VALID_UTF8=1
A_NON_ASCII=0
A_CANDIDATE=0
A_OVERSIZE=0
A_SIZE=0
A_EXT=""
A_EXT_CLASS="unknown" # strip|sensitive|unknown

# Per-file plan (set by plan_file)
P_STRIP_BOM=0
P_FIX_CRLF=0
P_BOM_KEPT=0
P_STATUS="clean"      # clean|change|keep|protect|skip-size
P_REASON=""

# Colors (populated by color_init; empty when disabled)
COL_RED="" COL_GREEN="" COL_YELLOW="" COL_BLUE="" COL_MAGENTA="" COL_CYAN="" COL_RESET=""

# find(1) expression fragments (filled by build_find_expr / build_prune_expr)
FIND_EXPR=()
PRUNE_EXPR=()
# git pathspec (filled from positional args in --git mode)
GIT_PATHSPEC=()
# positional paths (files and/or directories)
POSITIONAL=()
# resolved path of the running script (for --update and --self-test)
SELF_PATH="$0"
SCRIPT_PATH_RESOLVED=""

#------------------------------------------------------------------------------
# Cleanup / signals
#------------------------------------------------------------------------------
cleanup() {
	local rc=${1:-0}
	local t
	if [ -n "$TEMP_FILES" ]; then
		while IFS= read -r t; do
			if [ -n "$t" ]; then
				rm -f -- "$t" 2>/dev/null || true
			fi
		done <<EOF
$TEMP_FILES
EOF
	fi
	exit "$rc"
}
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup "$?"' EXIT

register_temp() {
	TEMP_FILES="${TEMP_FILES}${1}
"
}

die_usage() {
	log_error "$1"
	printf 'Try "%s --help" for more information.\n' "$SCRIPT_NAME" >&2
	cleanup "$EXIT_USAGE"
}

die_env() {
	log_error "$1"
	cleanup "$EXIT_ENV"
}

die_internal() {
	log_error "$1"
	cleanup "$EXIT_INTERNAL"
}

#------------------------------------------------------------------------------
# Logging (stderr; optionally tee'd to --log-file). Line format is the v2
# contract: [YYYY-MM-DD HH:MM:SS LEVEL] message
#------------------------------------------------------------------------------
get_timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log_raw() {
	# $1 = color, $2 = level, rest = message
	local color="$1" level="$2" ts
	shift 2
	ts="$(get_timestamp)"
	if [ "$SILENT" -eq 1 ] && [ "$level" != "ERROR" ]; then
		return 0
	fi
	printf '%b[%s %s]%b %s\n' "$color" "$ts" "$level" "$COL_RESET" "$*" >&2
	if [ -n "$LOG_FILE" ]; then
		printf '[%s %s] %s\n' "$ts" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
	fi
}

log_info() {
	[ "$QUIET" -eq 1 ] && return 0
	log_raw "$COL_BLUE" "INFO" "$@"
}

# v3: warnings are visible by default (v2 hid them behind --verbose, which is
# exactly why the "protected" cases must never be silent).
log_warn() {
	log_raw "$COL_YELLOW" "WARN" "$@"
}

log_error() {
	log_raw "$COL_RED" "ERROR" "$@"
	ERROR_COUNT=$((ERROR_COUNT + 1))
}

log_success() {
	[ "$VERBOSE" -eq 1 ] || return 0
	log_raw "$COL_GREEN" "SUCCESS" "$@"
}

log_processing() {
	[ "$VERBOSE" -eq 1 ] || return 0
	log_raw "$COL_CYAN" "PROCESSING" "$@"
}

#------------------------------------------------------------------------------
# Color initialisation (NO_COLOR / CLICOLOR_FORCE / --color are honoured)
#------------------------------------------------------------------------------
color_init() {
	local use_color=0
	case "$COLOR_MODE" in
		always) use_color=1 ;;
		never)  use_color=0 ;;
		auto)
			use_color=0
			if [ -n "${NO_COLOR:-}" ]; then
				use_color=0
			elif [ "${CLICOLOR_FORCE:-0}" != "0" ] && [ -n "${CLICOLOR_FORCE:-}" ]; then
				use_color=1
			elif [ -t 2 ]; then
				use_color=1
			fi
			;;
		*) die_usage "Invalid --color value: $COLOR_MODE (expected auto|always|never)" ;;
	esac
	if [ "$use_color" -eq 1 ]; then
		# Real ESC characters (not escape-string literals): every printf,
		# whether %s or %b, emits true ANSI then.
		COL_RED=$'\033[0;31m'
		COL_GREEN=$'\033[0;32m'
		COL_YELLOW=$'\033[1;33m'
		COL_BLUE=$'\033[0;34m'
		COL_MAGENTA=$'\033[0;35m'
		COL_CYAN=$'\033[0;36m'
		COL_RESET=$'\033[0m'
	fi
}

#------------------------------------------------------------------------------
# Portability shims (GNU vs BSD userland). v2 called `stat -c` unconditionally:
# on macOS every probe failed and the tool SILENTLY SKIPPED ALL FILES.
#------------------------------------------------------------------------------
STAT_FLAVOR=""

stat_probe() {
	if stat -c %s /dev/null >/dev/null 2>&1; then
		STAT_FLAVOR="gnu"
	elif stat -f %z /dev/null >/dev/null 2>&1; then
		STAT_FLAVOR="bsd"
	else
		die_env "stat(1) is neither GNU nor BSD flavour — unsupported platform"
	fi
}

file_size() {
	if [ "$STAT_FLAVOR" = "gnu" ]; then
		stat -c %s -- "$1" 2>/dev/null
	else
		stat -f %z -- "$1" 2>/dev/null
	fi
}

file_nlink() {
	if [ "$STAT_FLAVOR" = "gnu" ]; then
		stat -c %h -- "$1" 2>/dev/null || printf '1'
	else
		stat -f %l -- "$1" 2>/dev/null || printf '1'
	fi
}

file_inode() {
	stat -c %i -- "$1" 2>/dev/null || stat -f %i -- "$1" 2>/dev/null || printf '0'
}

# Prints "uid gid mode(octal)"
file_attrs() {
	if [ "$STAT_FLAVOR" = "gnu" ]; then
		stat -c '%u %g %a' -- "$1" 2>/dev/null
	else
		stat -f '%u %g %p' -- "$1" 2>/dev/null
	fi
}

resolve_path() {
	# Canonicalise (follow symlinks). readlink -f: GNU, macOS >= 12.3,
	# Git Bash. Portable fallback: canonicalise the directory, keep the leaf.
	local target="$1" d b
	if d="$(readlink -f -- "$target" 2>/dev/null)" && [ -n "$d" ]; then
		printf '%s\n' "$d"
	else
		d="$(dirname -- "$target")"
		b="$(basename -- "$target")"
		if [ -d "$d" ]; then
			printf '%s/%s\n' "$(cd -- "$d" && pwd -P)" "$b"
		else
			printf '%s\n' "$target"
		fi
	fi
}

have() {
	command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
	local missing="" cmd
	for cmd in find sed awk od grep stat tail wc tr mv cp touch chmod mktemp date basename dirname id; do
		have "$cmd" || missing="$missing $cmd"
	done
	if [ -n "$missing" ]; then
		log_error "Missing required commands:$missing"
		return "$EXIT_ENV"
	fi
	local probe_dir probe
	probe_dir="${TMPDIR:-/tmp}"
	if [ ! -w "$probe_dir" ]; then
		log_error "No write access to temp directory: $probe_dir"
		return "$EXIT_ENV"
	fi
	if ! probe="$(mktemp "${probe_dir}/${SCRIPT_NAME}.${SCRIPT_PID}.XXXXXX" 2>/dev/null)"; then
		log_error "Cannot create probe file in temp directory: $probe_dir"
		return "$EXIT_ENV"
	fi
	rm -f -- "$probe"
	return 0
}

#------------------------------------------------------------------------------
# Byte-exact encoding analysis
#------------------------------------------------------------------------------

# First 4 bytes as a lowercase hex string ("" for empty files). Reading from
# offset 0 keeps every hex pair byte-aligned, so prefix matching is exact.
read_magic() {
	od -An -tx1 -N4 -- "$1" 2>/dev/null | tr -d ' \n' || true
}

# Classify the BOM. Order matters: FF FE 00 00 (UTF-32LE) must be tested
# before FF FE (UTF-16LE) because the former extends the latter.
classify_bom() {
	case "$1" in
		efbbbf*)   A_ENC="utf8-bom" ;;
		fffe0000*) A_ENC="utf32le" ;;
		fffe*)     A_ENC="utf16le" ;;
		feff*)     A_ENC="utf16be" ;;
		0000feff*) A_ENC="utf32be" ;;
		*)         A_ENC="none" ;;
	esac
}

# True when the file contains at least one REAL CRLF pair (CR immediately
# before LF), scanned over the whole file — byte-exact, none of the hex-window
# false positives/negatives v2 had.
#
# A CR as the very LAST byte of a file that does not end with LF is NOT a
# CRLF and never flags the file (CR-only "old Mac" files stay untouched).
# When a file IS rewritten because of real CRLFs, a trailing CR at EOF follows
# the documented v2 sed semantics and is removed too (AGENTS.md invariant 7).
#
# WHY HEX AND NOT grep/awk/sed ON THE FILE ITSELF
#   Every line-oriented tool defines "end of line" by the LF byte, so it
#   cannot tell a CR that is *immediately* followed by LF from a CR that merely
#   ends an LF-delimited line. The difference is invisible in text and decisive
#   in bytes: UTF-16LE encodes CR as `0D 00` and LF as `00 0A`, so `... 0D 00
#   0A` has a CR at end-of-line but NO `0D 0A` pair. The line-based probe this
#   function used before reported such a file as a modification candidate,
#   which inflated the protected-UTF-16 counters and warned about files that
#   needed nothing (AGENTS.md invariant 3 requires the byte pair).
#   `od -tx1` renders the file as byte-aligned hex, so `0d0a` in that stream is
#   exactly the byte pair, NUL bytes included. Unlike v2's fixed 1024-byte
#   window, the WHOLE file is rendered and the pairs stay aligned, which is
#   what removed both of v2's failure modes.
has_crlf() {
	local f="$1" carry
	# Fast reject: no CR byte anywhere means no CRLF pair. This is exact for
	# the negative answer and cheap, because tr exits after a fixed number of
	# output lines.
	#
	# It must NOT be written with grep: grep works on LF-delimited lines and
	# therefore cannot tell a CR immediately followed by LF from a CR that
	# merely ends a line - which is exactly the ambiguity that made the
	# previous line-based probe report UTF-16LE `0D 00 0A` as a CRLF. On top of
	# that, grep is text-mode by default: under MSYS/Git Bash it strips CR bytes
	# before matching, so `grep -c <CR>` reports 0 for a file full of CRLF
	# (measured on Git Bash 5.3.15: grep 0, grep -U 2, tr -dc <CR> | wc -c 2)
	# and the reject branch swallowed every CRLF file. `grep -U` would fix it
	# on GNU but is not portable to BSD grep, and this file must run on macOS.
	# tr -dc deletes everything that is not a CR, so it is byte-oriented by
	# construction, and the count is the number of CR bytes in the file.
	# `head -c 1` bounds the command substitution on large files; on a file
	# with no CR at all tr reads to EOF and writes nothing, which is the cheap
	# answer, and no SIGPIPE arm is reachable (head reads its single byte).
	# `wc -c` reads its input to EOF and the counted digits below are parsed as
	# text, so the producer is never killed by SIGPIPE and no early-exiting
	# consumer (the `cmd | head` trap noted in do_update) is involved.
	case "$(tr -dc "${CR_BYTE}" <"$f" 2>/dev/null | wc -c)" in
		*[1-9]*) : ;;
		*) return 1 ;;
	esac
	carry=""
	# Byte-exact answer: od renders the file as byte-aligned hex, so "0d0a" in
	# that stream IS the byte pair, NUL bytes included. tr collapses od's
	# separators; the one-character carry reconnects a pair split across two
	# lines. awk reads to EOF (no early exit), so there is no SIGPIPE for
	# pipefail to trip over and the pipeline status is the verdict.
	od -An -v -tx1 -- "$f" 2>/dev/null | tr -d ' \n\t' | awk -v carry="$carry" '
		{
			s = carry $0
			if (index(s, "0d0a")) { found = 1 }
			carry = substr(s, length(s), 1)
		}
		END { exit !found }
	' 2>/dev/null
}

# True when the file contains NUL bytes (binary data, or UTF-16/32 without a
# BOM). Byte-exact: compare raw length against length with NULs deleted.
has_nul() {
	local f="$1" s1 s2
	s1="$(wc -c <"$f" 2>/dev/null | tr -d '[:space:]')" || return 1
	s2="$(tr -d '\000' <"$f" 2>/dev/null | wc -c | tr -d '[:space:]')" || return 1
	[ -n "$s1" ] && [ "$s1" != "$s2" ]
}

# True when the whole file is valid UTF-8 (a leading UTF-8 BOM is valid
# UTF-8 — it decodes to U+FEFF). Without iconv we cannot validate: the check
# passes and a one-shot warning explains the reduced strictness.
is_valid_utf8() {
	if ! have iconv; then
		if [ "$WARNED_ICONV" -eq 0 ]; then
			WARNED_ICONV=1
			log_warn "iconv not available: UTF-8 validation disabled (proceeding as valid)"
		fi
		return 0
	fi
	iconv -f UTF-8 -t UTF-8 -- "$1" >/dev/null 2>&1
}

# True when the content (AFTER a UTF-8 BOM, if present) contains non-ASCII
# bytes. Used by the Smart BOM Policy for sensitive extensions.
has_non_ascii() {
	local f="$1" n
	if [ "$A_ENC" = "utf8-bom" ]; then
		n="$(tail -c +4 -- "$f" | tr -d '\000-\177' | wc -c | tr -d '[:space:]')"
	else
		n="$(tr -d '\000-\177' <"$f" | wc -c | tr -d '[:space:]')"
	fi
	[ "${n:-0}" -gt 0 ]
}

get_extension() {
	local base ext
	base="$(basename -- "$1")"
	case "$base" in
		*.*) ext="${base##*.}" ;;
		*)   ext="" ;;
	esac
	printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

in_list() {
	# $1 = needle, $2 = space-separated list
	local x
	for x in $2; do
		if [ "$x" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

ext_class() {
	# strip | sensitive | unknown   (unknown behaves as sensitive while a
	# sensitive list exists — the safe default for user-supplied extensions
	# we have no consumer knowledge about; --sensitive-ext '' disables
	# sensitivity entirely, including for unknown extensions)
	if [ -n "$SENSITIVE_EXTS" ] && in_list "$1" "$SENSITIVE_EXTS"; then
		printf 'sensitive'
	elif in_list "$1" "$STRIP_ALWAYS"; then
		printf 'strip'
	else
		printf 'unknown'
	fi
}

# True when the extension's UTF-8 BOM deserves the "may be required" treatment.
class_is_sensitive() {
	case "$1" in
		sensitive) return 0 ;;
		unknown)   [ -n "$SENSITIVE_EXTS" ] && return 0; return 1 ;;
		*)         return 1 ;;
	esac
}

#------------------------------------------------------------------------------
# Full-file analysis: fills A_* globals. Always returns 0; verdicts live in
# the globals so the caller never confuses "status" with "failure".
#------------------------------------------------------------------------------
analyze_file() {
	local f="$1" magic bom_actionable crlf_actionable
	A_ENC="none"; A_HAS_CRLF=0; A_BINARY=0; A_VALID_UTF8=1
	A_NON_ASCII=0; A_CANDIDATE=0; A_OVERSIZE=0
	A_SIZE=0; A_EXT=""; A_EXT_CLASS="unknown"

	A_SIZE="$(file_size "$f" 2>/dev/null || printf '0')"
	if [ "${A_SIZE:-0}" -gt "$MAX_SIZE" ]; then
		A_OVERSIZE=1
		return 0
	fi

	A_EXT="$(get_extension "$f")"
	A_EXT_CLASS="$(ext_class "$A_EXT")"

	magic="$(read_magic "$f")"
	classify_bom "$magic"

	bom_actionable=0
	if [ "$A_ENC" = "utf8-bom" ] && [ "$NO_BOM_CLEAR" -eq 0 ]; then
		bom_actionable=1
	fi
	crlf_actionable=$((1 - NO_CRLF_NORMALIZE))

	# UTF-16/UTF-32: the BOM is part of the format. The file becomes a
	# candidate ONLY if a real CRLF was detected (then it must be protected,
	# because v2-style byte tools would corrupt it); otherwise it is clean
	# and stays silent.
	case "$A_ENC" in
		utf16le|utf16be|utf32le|utf32be)
			if [ "$crlf_actionable" -eq 1 ] && has_crlf "$f"; then
				A_HAS_CRLF=1
				A_CANDIDATE=1
			fi
			return 0
			;;
	esac

	if [ "$bom_actionable" -eq 0 ] && [ "$crlf_actionable" -eq 0 ]; then
		return 0 # every transformation disabled — nothing can happen
	fi

	if [ "$crlf_actionable" -eq 1 ] && has_crlf "$f"; then
		A_HAS_CRLF=1
	fi

	if [ "$bom_actionable" -eq 0 ] && [ "$A_HAS_CRLF" -eq 0 ]; then
		return 0 # clean fast path: no deep scans on a clean tree
	fi
	A_CANDIDATE=1

	# Deep safety checks run ONLY for modification candidates.
	if has_nul "$f"; then
		A_BINARY=1
		return 0
	fi
	if ! is_valid_utf8 "$f"; then
		A_VALID_UTF8=0
		return 0
	fi
	if [ "$bom_actionable" -eq 1 ] && class_is_sensitive "$A_EXT_CLASS"; then
		if has_non_ascii "$f"; then
			A_NON_ASCII=1
		fi
	fi
	return 0
}

#------------------------------------------------------------------------------
# Policy engine: fills P_* globals from A_* + CLI flags.
# The decision table is documented in docs/SMART-BOM.md — keep both in sync.
#------------------------------------------------------------------------------
plan_file() {
	P_STRIP_BOM=0; P_FIX_CRLF=0; P_BOM_KEPT=0; P_STATUS="clean"; P_REASON=""

	if [ "$A_OVERSIZE" -eq 1 ]; then
		P_STATUS="skip-size"
		P_REASON="larger than --max-size ($(fmt_size "$MAX_SIZE"))"
		return 0
	fi
	if [ "$A_CANDIDATE" -eq 0 ]; then
		return 0
	fi

	# --- Hard refusals: NEVER modified, not even under --force -------------
	case "$A_ENC" in
		utf16le|utf16be|utf32le|utf32be)
			P_STATUS="protect"
			P_REASON="bom-required-$A_ENC"
			return 0
			;;
	esac
	if [ "$A_BINARY" -eq 1 ]; then
		P_STATUS="protect"
		P_REASON="binary-nul-bytes"
		return 0
	fi
	if [ "$A_VALID_UTF8" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
		P_STATUS="protect"
		P_REASON="invalid-utf8"
		return 0
	fi

	# --- BOM action ---------------------------------------------------------
	if [ "$A_ENC" = "utf8-bom" ] && [ "$NO_BOM_CLEAR" -eq 0 ]; then
		case "$BOM_POLICY" in
			keep)
				P_STRIP_BOM=0
				P_BOM_KEPT=1
				P_REASON="bom-policy-keep"
				;;
			strip)
				P_STRIP_BOM=1
				;;
			auto)
				if [ "$FORCE" -eq 1 ]; then
					P_STRIP_BOM=1
				elif class_is_sensitive "$A_EXT_CLASS" && [ "$A_NON_ASCII" -eq 1 ]; then
					# The BOM may be load-bearing for this file type
					# (Excel / legacy Notepad / csv tools; Windows PowerShell
					# 5.1 parses BOM-less non-ASCII scripts as ANSI).
					P_STRIP_BOM=0
					P_BOM_KEPT=1
					P_REASON="bom-may-be-required"
				else
					P_STRIP_BOM=1
				fi
				;;
		esac
	fi

	# --- CRLF action --------------------------------------------------------
	if [ "$A_HAS_CRLF" -eq 1 ] && [ "$NO_CRLF_NORMALIZE" -eq 0 ]; then
		case "$A_ENC" in
			utf16le|utf16be|utf32le|utf32be) : ;; # unreachable: refused above
			*) P_FIX_CRLF=1 ;;
		esac
	fi

	# --- Verdict ------------------------------------------------------------
	if [ "$P_STRIP_BOM" -eq 1 ] || [ "$P_FIX_CRLF" -eq 1 ]; then
		P_STATUS="change"
	elif [ "$P_BOM_KEPT" -eq 1 ]; then
		P_STATUS="keep"
	elif [ "$A_VALID_UTF8" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
		P_STATUS="protect"
		P_REASON="invalid-utf8"
	fi
	return 0
}

fmt_size() {
	local b="$1"
	if [ "$b" -ge $((1024 * 1024 * 1024)) ] && [ $((b % (1024 * 1024 * 1024))) -eq 0 ]; then
		printf '%dG' "$((b / 1024 / 1024 / 1024))"
	elif [ "$b" -ge $((1024 * 1024)) ] && [ $((b % (1024 * 1024))) -eq 0 ]; then
		printf '%dM' "$((b / 1024 / 1024))"
	elif [ "$b" -ge 1024 ] && [ $((b % 1024)) -eq 0 ]; then
		printf '%dK' "$((b / 1024))"
	else
		printf '%dB' "$b"
	fi
}

#------------------------------------------------------------------------------
# JSON helpers (stdout is the machine channel; entries are buffered per line)
#------------------------------------------------------------------------------
json_escape() {
	# Escapes \, ", control bytes and embedded newlines. Paths with NULs are
	# impossible on POSIX; everything else round-trips.
	printf '%s' "$1" | awk '
		BEGIN {
			FS = ""
			for (i = 0; i < 32; i++) {
				ctrl[sprintf("%c", i)] = sprintf("\\u%04x", i)
			}
		}
		{
			if (NR > 1) { printf "\\n" }
			for (i = 1; i <= NF; i++) {
				c = substr($0, i, 1)
				if      (c == "\\") { printf "\\\\" }
				else if (c == "\"") { printf "\\\"" }
				else if (c in ctrl) { printf "%s", ctrl[c] }
				else                { printf "%s", c }
			}
		}
	'
}

json_bool() {
	if [ "$1" -eq 1 ]; then printf 'true'; else printf 'false'; fi
}

json_add_entry() {
	# $1=path $2=status $3=encoding $4=reason $5=actions(csv) $6=bomKept(0/1)
	local path="$1" status="$2" enc="$3" reason="$4" actions="$5" bom_kept="$6"
	local actions_json="" a first=1
	local -a arr=()
	if [ -n "$actions" ]; then
		IFS=',' read -r -a arr <<<"$actions"
		if [ "${#arr[@]}" -gt 0 ]; then
			for a in ${arr[@]+"${arr[@]}"}; do
				if [ "$first" -eq 1 ]; then first=0; else actions_json="${actions_json}, "; fi
				actions_json="${actions_json}\"$a\""
			done
		fi
	fi
	local reason_json="null"
	if [ -n "$reason" ]; then
		reason_json="\"$(json_escape "$reason")\""
	fi
	JSON_ENTRIES="${JSON_ENTRIES}{\"path\": \"$(json_escape "$path")\", \"status\": \"${status}\", \"encoding\": \"${enc}\", \"actions\": [${actions_json}], \"bomKept\": $(json_bool "$bom_kept"), \"reason\": ${reason_json}}
"
}

json_report() {
	local dur mode_str
	dur=$(( $(date +%s) - START_TIME ))
	if [ "$CHECK_MODE" -eq 1 ]; then
		mode_str="check"
	elif [ "$DRY_RUN" -eq 1 ]; then
		mode_str="dry-run"
	else
		mode_str="fix"
	fi
	printf '{\n'
	printf '  "tool": "clean-bom-senior",\n'
	printf '  "version": "%s",\n' "$VERSION"
	printf '  "mode": "%s",\n' "$mode_str"
	printf '  "startedAt": "%s",\n' "$START_TIME_ISO"
	printf '  "durationSeconds": %d,\n' "$dur"
	printf '  "cwd": "%s",\n' "$(json_escape "$(pwd)")"
	printf '  "options": {\n'
	printf '    "bomPolicy": "%s",\n' "$BOM_POLICY"
	printf '    "noBomClear": %s,\n' "$(json_bool "$NO_BOM_CLEAR")"
	printf '    "noCrlfNormalize": %s,\n' "$(json_bool "$NO_CRLF_NORMALIZE")"
	printf '    "force": %s,\n' "$(json_bool "$FORCE")"
	printf '    "extensions": "%s",\n' "$(json_escape "$EXTENSIONS")"
	printf '    "sensitiveExtensions": "%s",\n' "$(json_escape "$SENSITIVE_EXTS")"
	printf '    "maxSizeBytes": %d,\n' "$MAX_SIZE"
	printf '    "keepMtime": %s\n' "$(json_bool "$KEEP_MTIME")"
	printf '  },\n'
	printf '  "summary": {\n'
	printf '    "scanned": %d,\n' "$SCANNED_COUNT"
	printf '    "changed": %d,\n' "$CHANGED_COUNT"
	printf '    "wouldChange": %d,\n' "$WOULD_CHANGE_COUNT"
	printf '    "clean": %d,\n' "$CLEAN_COUNT"
	printf '    "bomKept": %d,\n' "$KEPT_BOM_COUNT"
	printf '    "bomRemoved": %d,\n' "$BOM_REMOVED_COUNT"
	printf '    "crlfFixed": %d,\n' "$CRLF_FIXED_COUNT"
	printf '    "protectedUtf16or32": %d,\n' "$PROTECTED_UTF16_COUNT"
	printf '    "protectedBinary": %d,\n' "$PROTECTED_BINARY_COUNT"
	printf '    "protectedInvalidUtf8": %d,\n' "$PROTECTED_INVALID_COUNT"
	printf '    "skippedOversize": %d,\n' "$SKIPPED_SIZE_COUNT"
	printf '    "errors": %d\n' "$ERROR_COUNT"
	printf '  },\n'
	printf '  "files": [\n'
	if [ -n "$JSON_ENTRIES" ]; then
		printf '%s' "$JSON_ENTRIES" | awk '
			NF { lines[n++] = $0 }
			END { for (i = 0; i < n; i++) printf "    %s%s\n", lines[i], (i < n - 1 ? "," : "") }
		'
	fi
	printf '  ]\n'
	printf '}\n'
}

#------------------------------------------------------------------------------
# Transformation (atomic, attribute-preserving, verified, with rollback)
#------------------------------------------------------------------------------

# Build cleaned content into $2 from $1 according to the P_* plan.
build_clean_content() {
	local src="$1" dst="$2" skip=0 line ended_with_lf first
	if [ "$P_STRIP_BOM" -eq 1 ]; then
		skip=3
	fi
	if [ "$P_FIX_CRLF" -eq 1 ]; then
		# Delete every CR that terminates a line, and a CR at EOF.
		# A RUN of CRs before the LF collapses to that one LF, so the output
		# contains no CR immediately before a LF. The sed form used before
		# this (`s/CR$//`, one CR per line) was NOT idempotent on such a run:
		# `CR CR LF` came back as `CR LF`, which the post-write verification
		# then rejected - the tool threw away a file it should have cleaned.
		# Measured on all three implementations before the fix: sh wrote the
		# bad bytes, node and the PowerShell port refused to write at all
		# ("Verification failed after cleaning"). Collapsing the whole run is
		# also what makes a second run a no-op, so the summary's "CRLF fixed:
		# 0" stays honest for a tree this tool has already processed.
		#
		# Stripping happens ONE CR per iteration through a glob, never through
		# a character class: CR is not whitespace to a `${line%% }`-style trim,
		# and BSD sed (macOS) has no `\r`, which is why this is not sed.
		# Reading line by line means the last line arrives without its LF, so
		# the EOF CR is handled by the very same rule - the documented sed
		# `s/\r$//` semantics, applied uniformly. The line separators are
		# re-emitted explicitly and a final LF is added only when the source
		# had one, because contract 7.1 forbids adding or removing a trailing
		# newline (a `printf '%s\n'` per line would silently append one).
		ended_with_lf=0
		if [ "$(tail -c 1 -- "$src" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')" = "0a" ]; then
			ended_with_lf=1
		fi
		first=1
		while IFS= read -r line || [ -n "$line" ]; do
			while :; do
				case "$line" in
					*"${CR_BYTE}") line="${line%"${CR_BYTE}"}" ;;
					*) break ;;
				esac
			done
			if [ "$first" -eq 1 ]; then
				printf '%s' "$line"
				first=0
			else
				printf '\n%s' "$line"
			fi
		done < <(if [ "$skip" -gt 0 ]; then tail -c +4 -- "$src"; else cat -- "$src"; fi) >"$dst"
		if [ "$ended_with_lf" -eq 1 ]; then
			printf '\n' >>"$dst"
		fi
	elif [ "$skip" -gt 0 ]; then
		# Byte-exact copy without the first 3 bytes — no sed involved, so
		# MSYS/Git-Bash text-mode CR stripping cannot happen (v2 defect:
		# --no-rn-normalize still normalised CRLF under MSYS).
		tail -c +4 -- "$src" >"$dst"
	else
		cp -- "$src" "$dst"
	fi
}

# Defence in depth: never install content that still violates the plan.
verify_clean_content() {
	local dst="$1" magic
	if [ "$P_STRIP_BOM" -eq 1 ]; then
		magic="$(read_magic "$dst")"
		case "$magic" in
			efbbbf*) return 1 ;;
		esac
	fi
	if [ "$P_FIX_CRLF" -eq 1 ] && has_crlf "$dst"; then
		return 1
	fi
	return 0
}

apply_attrs_to() {
	# $1 = attribute donor (the original), $2 = destination (temp file)
	local attrs uid gid mode
	attrs="$(file_attrs "$1")" || return 1
	read -r uid gid mode <<<"$attrs"
	[ -n "$mode" ] || return 1
	chmod "$mode" -- "$2" 2>/dev/null || log_warn "Could not set permissions ($mode) on: $2"
	if [ "$(id -u)" -eq 0 ] && have chown; then
		chown "$uid:$gid" -- "$2" 2>/dev/null || log_warn "Could not set ownership ($uid:$gid) on: $2"
	fi
	if [ "$KEEP_MTIME" -eq 1 ]; then
		# Copy atime+mtime from the ORIGINAL onto the temp file BEFORE the
		# atomic rename, so the replacement inode carries the old times.
		# (v2 did `touch -r $backup` where $backup was a fresh copy — i.e.
		# it stamped "now" and the documented preservation never happened.)
		touch -r "$1" -- "$2" 2>/dev/null || log_warn "Could not preserve timestamps on: $2"
	fi
	return 0
}

make_backup_copy() {
	local f="$1" dest
	if [ -n "$BACKUP_DIR" ]; then
		dest="${BACKUP_DIR%/}/${f#./}"
		mkdir -p -- "$(dirname -- "$dest")" 2>/dev/null || true
	else
		dest="${f}.bak.${SCRIPT_PID}"
	fi
	if cp -p -- "$f" "$dest" 2>/dev/null; then
		log_processing "Backup saved: $dest"
	else
		log_warn "Could not create backup for: $f (continuing without it)"
	fi
}

# In-place rewrite preserving the inode (hard-linked files; fallback when the
# parent directory is not writable). Keeps a rollback copy until success.
write_in_place() {
	local f="$1" content="$2" rollback
	if ! rollback="$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}.rb.XXXXXX" 2>/dev/null)"; then
		die_internal "Cannot create rollback temp file in ${TMPDIR:-/tmp}"
	fi
	register_temp "$rollback"
	if ! cp -p -- "$f" "$rollback" 2>/dev/null; then
		rm -f -- "$rollback"
		return 1
	fi
	if cat -- "$content" >"$f" 2>/dev/null; then
		if [ "$KEEP_MTIME" -eq 1 ]; then
			touch -r "$rollback" -- "$f" 2>/dev/null || true
		fi
		rm -f -- "$rollback"
		return 0
	fi
	cat -- "$rollback" >"$f" 2>/dev/null || true # rollback
	rm -f -- "$rollback"
	return 1
}

transform_file() {
	# $1 = REAL path of the file to rewrite (plan globals already set).
	local f="$1" dir temp nlink
	dir="$(dirname -- "$f")"

	if ! temp="$(mktemp "${dir}/.cleanbom.${SCRIPT_PID}.XXXXXX" 2>/dev/null)"; then
		# Directory not writable — fall back to a guarded in-place rewrite.
		if [ -w "$f" ]; then
			log_warn "Directory not writable, rewriting in place (non-atomic): $f"
			if ! temp="$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}.ct.XXXXXX" 2>/dev/null)"; then
				die_internal "Cannot create temp file in ${TMPDIR:-/tmp}"
			fi
			register_temp "$temp"
			if ! build_clean_content "$f" "$temp"; then
				log_error "Failed to process file content: $f"
				ERR_PROCESSING=$((ERR_PROCESSING + 1))
				return 1
			fi
			if ! verify_clean_content "$temp"; then
				log_error "Verification failed after cleaning (file NOT modified): $f"
				ERR_PROCESSING=$((ERR_PROCESSING + 1))
				return 1
			fi
			if [ "$BACKUP" -eq 1 ]; then
				make_backup_copy "$f"
			fi
			if write_in_place "$f" "$temp"; then
				rm -f -- "$temp"
				return 0
			fi
			log_error "In-place rewrite failed (original restored): $f"
			ERR_PROCESSING=$((ERR_PROCESSING + 1))
			return 1
		fi
		log_error "Cannot create temp file next to: $f (directory not writable)"
		ERR_ACCESS=$((ERR_ACCESS + 1))
		return 1
	fi
	register_temp "$temp"

	if ! build_clean_content "$f" "$temp"; then
		log_error "Failed to process file content: $f"
		ERR_PROCESSING=$((ERR_PROCESSING + 1))
		rm -f -- "$temp"
		return 1
	fi
	if ! verify_clean_content "$temp"; then
		log_error "Verification failed after cleaning (file NOT modified): $f"
		ERR_PROCESSING=$((ERR_PROCESSING + 1))
		rm -f -- "$temp"
		return 1
	fi

	if [ "$BACKUP" -eq 1 ]; then
		make_backup_copy "$f"
	fi

	nlink="$(file_nlink "$f" 2>/dev/null || printf '1')"
	if [ "${nlink:-1}" -gt 1 ]; then
		# Hard-linked: an atomic rename would silently detach the other
		# links. Rewrite through the inode so every link sees the fix.
		log_warn "File has $nlink hard links — rewriting in place to keep them intact: $f"
		if write_in_place "$f" "$temp"; then
			rm -f -- "$temp"
			return 0
		fi
		log_error "In-place rewrite failed (original restored): $f"
		ERR_PROCESSING=$((ERR_PROCESSING + 1))
		rm -f -- "$temp"
		return 1
	fi

	apply_attrs_to "$f" "$temp" || true

	if mv -f -- "$temp" "$f" 2>/dev/null; then
		rm -f -- "$temp"
		return 0
	fi

	# Atomic rename failed (e.g. permissions flipped under us): try in place.
	if [ -w "$f" ]; then
		log_warn "Atomic replace failed, retrying in place: $f"
		if write_in_place "$f" "$temp"; then
			rm -f -- "$temp"
			return 0
		fi
	fi
	log_error "Failed to replace file (original untouched): $f"
	ERR_PROCESSING=$((ERR_PROCESSING + 1))
	rm -f -- "$temp"
	return 1
}

#------------------------------------------------------------------------------
# Per-file driver
#------------------------------------------------------------------------------
handle_file() {
	# $1 = path as displayed/logged; $2 = real path to operate on (usually the
	# same; differs for symlink arguments, which are resolved to their target).
	local disp="$1" f="$2"
	local actions="" a

	SCANNED_COUNT=$((SCANNED_COUNT + 1))

	if [ ! -f "$f" ]; then
		log_error "File not found: $disp"
		ERR_ACCESS=$((ERR_ACCESS + 1))
		return 1
	fi
	if [ ! -r "$f" ]; then
		log_error "Cannot read file: $disp"
		ERR_ACCESS=$((ERR_ACCESS + 1))
		return 1
	fi

	analyze_file "$f"
	plan_file

	case "$P_STATUS" in
		clean)
			CLEAN_COUNT=$((CLEAN_COUNT + 1))
			log_processing "No issues detected, skipping: $disp"
			return 0
			;;
		skip-size)
			SKIPPED_SIZE_COUNT=$((SKIPPED_SIZE_COUNT + 1))
			log_info "Skipped (oversize, $(fmt_size "${A_SIZE:-0}") > $(fmt_size "$MAX_SIZE")): $disp"
			json_add_entry "$disp" "skipped-size" "$A_ENC" "$P_REASON" "" 0
			return 0
			;;
		protect)
			case "$P_REASON" in
				bom-required-*)
					PROTECTED_UTF16_COUNT=$((PROTECTED_UTF16_COUNT + 1))
					log_warn "NOT touched — ${A_ENC} BOM is structurally required; stripping it would corrupt the file (convert with iconv if UTF-8 is needed): $disp"
					;;
				binary-nul-bytes)
					PROTECTED_BINARY_COUNT=$((PROTECTED_BINARY_COUNT + 1))
					log_warn "NOT touched — contains NUL bytes (binary data or BOM-less UTF-16): $disp"
					;;
				invalid-utf8)
					PROTECTED_INVALID_COUNT=$((PROTECTED_INVALID_COUNT + 1))
					log_warn "NOT touched — content is not valid UTF-8; pass --force for byte-level cleaning: $disp"
					;;
			esac
			json_add_entry "$disp" "protected" "$A_ENC" "$P_REASON" "" 0
			return 0
			;;
		keep)
			KEPT_BOM_COUNT=$((KEPT_BOM_COUNT + 1))
			log_info "BOM kept (may be required for .$A_EXT with non-ASCII content; --force strips it): $disp"
			json_add_entry "$disp" "kept" "$A_ENC" "$P_REASON" "" 1
			return 0
			;;
	esac

	# P_STATUS == change ------------------------------------------------------
	actions=""
	if [ "$P_STRIP_BOM" -eq 1 ]; then
		actions="strip-bom"
	fi
	if [ "$P_FIX_CRLF" -eq 1 ]; then
		actions="${actions:+$actions,}crlf-to-lf"
	fi

	if [ "$DRY_RUN" -eq 1 ] || [ "$CHECK_MODE" -eq 1 ]; then
		WOULD_CHANGE_COUNT=$((WOULD_CHANGE_COUNT + 1))
		if [ "$P_BOM_KEPT" -eq 1 ]; then
			KEPT_BOM_COUNT=$((KEPT_BOM_COUNT + 1))
		fi
		AFFECTED_FILES="${AFFECTED_FILES}${disp}
"
		if [ "$VERBOSE" -eq 1 ]; then
			printf 'Would process: %s (actions: %s; encoding: %s%s)\n' \
				"$disp" "${actions//,/ + }" "$A_ENC" \
				"$([ "$P_BOM_KEPT" -eq 1 ] && printf '; BOM kept: may be required')" >&2
		fi
		json_add_entry "$disp" "would-change" "$A_ENC" "$P_REASON" "$actions" "$P_BOM_KEPT"
		return 0
	fi

	log_processing "Processing: $disp (actions: ${actions//,/ + }, encoding: $A_ENC)"
	if [ "$A_VALID_UTF8" -eq 0 ]; then
		log_warn "--force: byte-level cleaning of invalid-UTF-8 file: $disp"
	fi

	if transform_file "$f"; then
		CHANGED_COUNT=$((CHANGED_COUNT + 1))
		if [ "$P_STRIP_BOM" -eq 1 ]; then
			BOM_REMOVED_COUNT=$((BOM_REMOVED_COUNT + 1))
		fi
		if [ "$P_FIX_CRLF" -eq 1 ]; then
			CRLF_FIXED_COUNT=$((CRLF_FIXED_COUNT + 1))
		fi
		if [ "$P_BOM_KEPT" -eq 1 ]; then
			KEPT_BOM_COUNT=$((KEPT_BOM_COUNT + 1))
			log_info "BOM kept (may be required for .$A_EXT); CRLF normalised: $disp"
		fi
		a="${A_EXT:-other}"
		CHANGED_EXT_LINES="${CHANGED_EXT_LINES}${a:-other}
"
		AFFECTED_FILES="${AFFECTED_FILES}${disp}
"
		json_add_entry "$disp" "changed" "$A_ENC" "$P_REASON" "$actions" "$P_BOM_KEPT"
		log_success "Successfully processed: $disp (${actions//,/ + })"
		return 0
	fi

	json_add_entry "$disp" "error" "$A_ENC" "transform-failed" "$actions" "$P_BOM_KEPT"
	return 1
}

#------------------------------------------------------------------------------
# Selection / walking
#------------------------------------------------------------------------------
path_excluded() {
	local p="$1" pat d p2
	p2="${p#./}" # users write --exclude 'dist/*', find prints './dist/x'
	if [ -n "$EXCLUDE_PATTERNS" ]; then
		while IFS= read -r pat; do
			if [ -n "$pat" ]; then
				# shellcheck disable=SC2254 # deliberate glob matching on $pat
				case "$p" in
					$pat) return 0 ;;
				esac
				# shellcheck disable=SC2254 # deliberate glob matching on $pat
				case "$p2" in
					$pat) return 0 ;;
				esac
			fi
		done <<EOF
$EXCLUDE_PATTERNS
EOF
	fi
	for d in $EXCLUDE_DIRS; do
		case "/$p/" in
			*"/$d/"*) return 0 ;;
		esac
	done
	return 1
}

has_supported_extension() {
	in_list "$(get_extension "$1")" "$EXTENSIONS"
}

build_find_expr() {
	local ext first=1
	FIND_EXPR=( -type f \( )
	for ext in $EXTENSIONS; do
		if [ "$first" -eq 1 ]; then
			FIND_EXPR+=( -iname "*.$ext" )
			first=0
		else
			FIND_EXPR+=( -o -iname "*.$ext" )
		fi
	done
	FIND_EXPR+=( \) )
}

build_prune_expr() {
	local d first=1
	PRUNE_EXPR=()
	[ -n "$EXCLUDE_DIRS" ] || return 0
	PRUNE_EXPR+=( \( )
	for d in $EXCLUDE_DIRS; do
		if [ "$first" -eq 1 ]; then
			PRUNE_EXPR+=( -name "$d" )
			first=0
		else
			PRUNE_EXPR+=( -o -name "$d" )
		fi
	done
	PRUNE_EXPR+=( \) -prune -o )
}

scan_directory() {
	local dir="$1" f
	build_find_expr
	build_prune_expr
	log_processing "Scanning directory: $dir"
	while IFS= read -r -d '' f; do
		if path_excluded "$f"; then
			continue
		fi
		handle_file "$f" "$f" || FILE_ERRORS=1
	done < <(
		if [ "${#PRUNE_EXPR[@]}" -gt 0 ]; then
			find "$dir" "${PRUNE_EXPR[@]}" "${FIND_EXPR[@]}" -size +0c -print0 2>/dev/null
		else
			find "$dir" "${FIND_EXPR[@]}" -size +0c -print0 2>/dev/null
		fi | sort -z
	)
}

scan_git_tracked() {
	local f
	if ! have git; then
		die_env "--git requires git(1) in PATH"
	fi
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		die_env "--git: current directory is not inside a git work tree"
	fi
	log_info "Git mode: processing tracked files only"
	while IFS= read -r -d '' f; do
		if [ -z "$f" ] || [ ! -f "$f" ]; then
			continue
		fi
		if ! has_supported_extension "$f"; then
			continue
		fi
		if path_excluded "$f"; then
			continue
		fi
		handle_file "$f" "$f" || FILE_ERRORS=1
	done < <(git ls-files -z -- ${GIT_PATHSPEC[@]+"${GIT_PATHSPEC[@]}"} 2>/dev/null | sort -z)
}

#------------------------------------------------------------------------------
# Reports
#------------------------------------------------------------------------------
print_ext_distribution() {
	local cnt ext
	[ -n "$CHANGED_EXT_LINES" ] || return 0
	printf '%s' "$CHANGED_EXT_LINES" | sort | uniq -c | while read -r cnt ext; do
		if [ -z "$ext" ] || [ "$ext" = "other" ]; then
			printf 'Other files: %d\n' "$cnt" >&2
		else
			printf '.%s files: %d\n' "$ext" "$cnt" >&2
		fi
	done
}

display_statistics() {
	local elapsed kept_total
	elapsed=$(( $(date +%s) - START_TIME ))

	printf '\n%s=== PROCESSING SUMMARY ===%s\n' "$COL_MAGENTA" "$COL_RESET" >&2
	printf 'Execution time: %d seconds\n' "$elapsed" >&2
	printf 'Files scanned: %d\n' "$SCANNED_COUNT" >&2
	if [ "$DRY_RUN" -eq 1 ] || [ "$CHECK_MODE" -eq 1 ]; then
		printf 'Files that would be processed: %d\n' "$WOULD_CHANGE_COUNT" >&2
	else
		printf 'Files processed: %d\n' "$CHANGED_COUNT" >&2
	fi
	printf 'Files skipped (clean): %d\n' "$CLEAN_COUNT" >&2
	printf 'Errors encountered: %d\n' "$ERROR_COUNT" >&2

	if [ "$CHANGED_COUNT" -gt 0 ]; then
		printf '\n%s--- Issues Fixed ---%s\n' "$COL_CYAN" "$COL_RESET" >&2
		printf 'BOM signatures removed: %d\n' "$BOM_REMOVED_COUNT" >&2
		printf 'CRLF line endings fixed: %d\n' "$CRLF_FIXED_COUNT" >&2
		printf '\n%s--- File Type Distribution ---%s\n' "$COL_CYAN" "$COL_RESET" >&2
		print_ext_distribution
	fi

	kept_total=$((KEPT_BOM_COUNT + PROTECTED_UTF16_COUNT + PROTECTED_BINARY_COUNT +
	              PROTECTED_INVALID_COUNT + SKIPPED_SIZE_COUNT))
	if [ "$kept_total" -gt 0 ]; then
		printf '\n%s--- Protected / Kept Unchanged (Smart BOM Policy) ---%s\n' "$COL_YELLOW" "$COL_RESET" >&2
		if [ "$KEPT_BOM_COUNT" -gt 0 ]; then
			printf 'UTF-8 BOM kept (may be required): %d\n' "$KEPT_BOM_COUNT" >&2
		fi
		if [ "$PROTECTED_UTF16_COUNT" -gt 0 ]; then
			printf 'UTF-16/UTF-32 files (BOM required): %d\n' "$PROTECTED_UTF16_COUNT" >&2
		fi
		if [ "$PROTECTED_BINARY_COUNT" -gt 0 ]; then
			printf 'Binary files (NUL bytes): %d\n' "$PROTECTED_BINARY_COUNT" >&2
		fi
		if [ "$PROTECTED_INVALID_COUNT" -gt 0 ]; then
			printf 'Invalid UTF-8 files: %d\n' "$PROTECTED_INVALID_COUNT" >&2
		fi
		if [ "$SKIPPED_SIZE_COUNT" -gt 0 ]; then
			printf 'Oversize files skipped: %d\n' "$SKIPPED_SIZE_COUNT" >&2
		fi
	fi

	if [ "$ERROR_COUNT" -gt 0 ]; then
		printf '\n%s--- Error Breakdown ---%s\n' "$COL_RED" "$COL_RESET" >&2
		printf 'Access errors: %d\n' "$ERR_ACCESS" >&2
		printf 'Processing errors: %d\n' "$ERR_PROCESSING" >&2
		printf 'Other errors: %d\n' "$ERR_OTHER" >&2
	fi

	if { [ "$DRY_RUN" -eq 1 ] || [ "$CHECK_MODE" -eq 1 ]; } && [ "$WOULD_CHANGE_COUNT" -gt 0 ]; then
		printf '\n%s--- Files That Would Be Processed ---%s\n' "$COL_YELLOW" "$COL_RESET" >&2
		printf '%s' "$AFFECTED_FILES" >&2
	fi

	printf '\n%sProcessing completed at: %s%s\n' "$COL_GREEN" "$(get_timestamp)" "$COL_RESET" >&2
}

show_greeting() {
	printf '\n%s=== UTF-8 BOM & CRLF Cleaner v%s ===%s\n' "$COL_MAGENTA" "$VERSION" "$COL_RESET" >&2
	printf '%sAuthor:%s Mikhail Deynekin (mid1977@gmail.com)\n' "$COL_BLUE" "$COL_RESET" >&2
	printf '%sWebsite:%s https://deynekin.com\n' "$COL_BLUE" "$COL_RESET" >&2
	printf '%sStarted:%s %s\n' "$COL_BLUE" "$COL_RESET" "$(get_timestamp)" >&2
	printf '\n%s--- Configuration ---%s\n' "$COL_CYAN" "$COL_RESET" >&2
	printf 'Verbose mode: %s\n' "$([ "$VERBOSE" -eq 1 ] && echo ENABLED || echo DISABLED)" >&2
	if [ "$CHECK_MODE" -eq 1 ]; then
		printf 'Check mode: ENABLED (no files will be modified)\n' >&2
	elif [ "$DRY_RUN" -eq 1 ]; then
		printf 'Dry-run mode: ENABLED (no files will be modified)\n' >&2
	fi
	printf 'BOM removal: %s\n' "$([ "$NO_BOM_CLEAR" -eq 1 ] && echo DISABLED || echo ENABLED)" >&2
	printf 'CRLF normalization: %s\n' "$([ "$NO_CRLF_NORMALIZE" -eq 1 ] && echo DISABLED || echo ENABLED)" >&2
	if [ "$BOM_POLICY" = "auto" ]; then
		printf 'BOM policy: auto (smart: keep BOM where it may be required)\n' >&2
	else
		printf 'BOM policy: %s\n' "$BOM_POLICY" >&2
	fi
	printf 'Force mode: %s\n' "$([ "$FORCE" -eq 1 ] && echo ENABLED || echo DISABLED)" >&2
	printf 'Timestamps of modified files: %s\n' "$([ "$KEEP_MTIME" -eq 1 ] && echo PRESERVED || echo UPDATED)" >&2
	printf 'Supported extensions: %s\n' "$EXTENSIONS" >&2
	printf 'Maximum file size: %s\n' "$(fmt_size "$MAX_SIZE")" >&2
	if [ -n "$EXCLUDE_DIRS" ]; then
		printf 'Excluded directories: %s\n' "$EXCLUDE_DIRS" >&2
	fi
	printf '\n%sStarting file processing...%s\n\n' "$COL_GREEN" "$COL_RESET" >&2
}

#------------------------------------------------------------------------------
# Help system ( --help [TOPIC] )
#------------------------------------------------------------------------------
help_topics_list() {
	printf '%s' "usage options bom-policy safety exit-codes examples env ci update files json compatibility"
}

help_header() {
	printf 'Clean BOM Senior v%s — UTF-8 BOM & CRLF Cleaner with Smart BOM Policy\n' "$VERSION"
	printf 'Repository: https://github.com/paulmann/Clean_BOM_Senior\n\n'
}

help_usage() {
	cat <<EOF
USAGE
    $SCRIPT_NAME [OPTIONS] [PATH...]

    PATH may be a file or a directory (directories are scanned recursively).
    With no PATH, the current directory is scanned recursively.
    Default exclusions: .git, .svn, .hg, node_modules (--no-default-excludes
    to lift them; --exclude / --exclude-dir to add your own).

QUICK START
    $SCRIPT_NAME                     clean the current tree (smart, safe defaults)
    $SCRIPT_NAME --check             CI gate: exit 10 when anything needs cleaning
    $SCRIPT_NAME --dry-run           preview: what would change, and why
    $SCRIPT_NAME --json              machine-readable report on stdout
    $SCRIPT_NAME src index.php       clean a directory and a file
    $SCRIPT_NAME --help bom-policy   the Smart BOM Policy in detail
EOF
}

help_options() {
	cat <<'EOF'
OPTIONS
  Operation
    -n, --dry-run            Analyse and report, modify nothing (implies -v)
    -c, --check              CI gate: like --dry-run but terse; exit 10 if any
                             file needs cleaning, 0 if the tree is clean
    -f, --fix                Clean (the default mode; exists for explicitness)
    -v, --verbose            Per-file processing log
    -q, --quiet              No greeting/summary; warnings and errors only
        --silent             Errors only
    -j, --json               JSON report on stdout (schema: --help json)
        --color WHEN         auto | always | never (honours NO_COLOR,
                             CLICOLOR_FORCE)
        --no-color           Alias for --color=never
        --log-file FILE      Append the full log to FILE

  Selection
        --ext LIST           Comma-separated extensions REPLACING the defaults
                             (default: php,css,js,txt,xml,htm,html)
        --add-ext LIST       Comma-separated extensions ADDED to the defaults
        --exclude GLOB       Repeatable; skip paths matching GLOB
                             (e.g. --exclude 'dist/*' --exclude '*/vendor/*')
        --exclude-dir NAME   Repeatable; never descend into directory NAME
        --no-default-excludes  Descend into .git/.svn/.hg/node_modules too
        --max-size SPEC      Skip files larger than SPEC (default 100M;
                             accepts 512K, 10M, 1G, or a byte count)
        --git                Process only git-tracked files (needs git; PATH
                             arguments become git pathspecs)

  Smart BOM Policy (the safety core — details: --help bom-policy)
        --bom-policy POL     auto (default) | strip | keep
        --sensitive-ext LIST Comma-separated; extensions whose UTF-8 BOM may be
                             required (default: txt,csv,tsv,ps1,psm1,psd1;
                             an empty list disables sensitivity)
        --force              Strip "may-be-required" BOMs anyway and clean
                             invalid-UTF-8 files at byte level. NEVER
                             overrides hard refusals (UTF-16/32, NUL-binary).

  Transformation
        --no-bom-clear       Do not remove any BOM (v2 compatible)
        --no-rn-normalize    Do not normalise CRLF (v2 compatible name)
        --no-crlf-normalize  Same flag, clearer name
        --update-mtime       Set a fresh mtime on modified files (default:
        --no-keep-mtime      original timestamps are preserved)
        --backup             Keep a backup of every modified file
                             (<file>.bak.<pid> next to the original)
        --backup-dir DIR     Implies --backup; copies mirror the tree in DIR

  Information / maintenance
    -h, --help               Full help; --help TOPIC for one section
        --help TOPIC         Topics: usage options bom-policy safety
                             exit-codes examples env ci update files json
                             compatibility
    -V, --version            Version information
        --check-update       Query the repository; exit 11 if a newer version
                             exists, 0 if up to date
        --update             Self-update from the repository (--help update)
        --self-test          Run the built-in fixture test-suite and report
        --completion         Print a bash completion script
        --strict             Exit 1 if anything was kept/protected/skipped
                             (CI gate for "the tree is fully cleanable")
    --                       End of options (paths may start with '-')
EOF
}

help_bom_policy() {
	cat <<'EOF'
SMART BOM POLICY — "does this file actually NEED cleaning, and is its BOM
perhaps load-bearing?"   (full rationale: docs/SMART-BOM.md)

Before touching a file, v3 classifies it by its actual bytes and answers two
questions: (1) is cleaning needed at all? (2) is the BOM safe to remove?

DECISION TABLE (top-down, first match wins)
  1. Oversize (> --max-size)
       → skipped, counted separately, never read in full.
  2. UTF-16/UTF-32 BOM (FF FE, FE FF, FF FE 00 00, 00 00 FE FF)
       → NEVER TOUCHED. For these encodings the BOM is part of the format:
         removing it makes the file unreadable or misinterpreted, and byte-
         level CRLF tools would corrupt UTF-16 content. Such a file is only
         reported when something (a CRLF match) would otherwise have made the
         tool rewrite it. Convert with iconv first if you really need UTF-8.
  3. NUL bytes anywhere in the file
       → NEVER TOUCHED (binary data, or UTF-16 without BOM). Reported as
         "binary-nul-bytes". v2 rewrote such files — a corruption risk.
  4. Content is not valid UTF-8
       → NOT TOUCHED by default (the file is not what its BOM/extension
         claims; rewriting could destroy data). Reported as "invalid-utf8".
         --force enables byte-level cleaning: BOM-strip and CRLF→LF are safe
         byte operations for ASCII-compatible encodings (cp1251, latin-1…).
  5. UTF-8 BOM present, extension is SENSITIVE (default: txt csv tsv ps1 psm1
     psd1 — plus any extension not in the known-code table), and the content
     after the BOM is NON-ASCII
       → BOM KEPT by default, with an explanation. Rationale: Excel and legacy
         Windows Notepad render BOM-less UTF-8 as ANSI (mojibake); Windows
         PowerShell 5.1 parses BOM-less non-ASCII .ps1 as ANSI (broken
         scripts). Here the BOM is a feature, not dirt.
         Strip anyway with --force or --bom-policy=strip.
         CRLF in the same file IS still normalised (the BOM stays intact).
  6. UTF-8 BOM present; extension is code (php js css html xml …) or the
     content is pure ASCII
       → BOM REMOVED. In PHP a BOM is outright harmful (breaks header(),
         causes "headers already sent", interferes with declare/namespace in
         edge cases); for a pure-ASCII file the BOM carries zero information,
         so removal is lossless for every consumer, Excel and Notepad
         included.
  7. No BOM, no CRLF
       → File is CLEAN: not rewritten at all — inode, timestamps and hard
         links stay byte-for-byte intact.

OVERRIDES
  --bom-policy=strip   strip every UTF-8 BOM (still never UTF-16/32 or binary)
  --bom-policy=keep    never strip any BOM (CRLF is still normalised)
  --force              = strip policy + byte-level cleaning of invalid UTF-8
  --sensitive-ext LST  redefine the sensitive set ("" disables sensitivity)
  --no-bom-clear       v2-compatible global BOM switch-off

Every keep/protect decision is logged with its reason and appears in --json
("status": "kept"|"protected", "reason": …). Nothing is ever modified
silently, and files that need no modification are never rewritten.
EOF
}

help_safety() {
	cat <<'EOF'
SAFETY GUARANTEES
  • Atomic replace: cleaned content is built in a temp file in the SAME
    directory (same filesystem), verified (BOM gone / CRLF gone / no new
    trailing newline), then rename(2)d over the original. A crash mid-way can
    never leave a half-written file.
  • Hard links: detected (nlink > 1) and rewritten IN PLACE through the inode,
    so linked copies stay linked. A warning is logged.
  • Symlink arguments are resolved to their targets; the recursive walk never
    follows symlinks (files or directories).
  • Ownership/permissions are transferred to the new inode; timestamps of
    MODIFIED files are preserved by default (opt out: --update-mtime). Clean
    files are never rewritten at all, so their mtime never changes.
  • Read-only directories: automatic fallback to a guarded in-place rewrite
    (rollback copy kept until the write succeeds).
  • Backups: --backup keeps <file>.bak.<pid>; --backup-dir DIR mirrors the
    tree. The atomic replace itself needs no backup — the original stays
    intact until the verified rename.
  • Self-update replaces the script via rename(2): the running process keeps
    its old inode — updating mid-run is safe.
  • The tool never deletes files and never creates files other than temps,
    requested backups and the log file.
EOF
}

help_exit_codes() {
	cat <<'EOF'
EXIT CODES
  0   Success (tree clean, or everything cleaned)
  1   Completed, but some files had processing errors (see Error Breakdown),
      or --strict saw kept/protected/skipped files
  2   Invalid command line usage
  3   Environment problem: missing dependency, unusable temp dir, network
      failure during --check-update, or --update attempted on an npm-managed
      installation (use: npm install -g clean-bom-senior@latest)
  4   Critical internal error
  10  --check: at least one file needs cleaning (CI gate)
  11  --check-update: a newer version exists in the repository

Precedence when several apply: 2/3/4 (fatal) > 1 (file errors / strict) >
10 (check findings) > 0.
EOF
}

help_examples() {
	cat <<EOF
EXAMPLES
    $SCRIPT_NAME                            clean current tree, smart defaults
    $SCRIPT_NAME /path/to/project src       clean specific directories
    $SCRIPT_NAME --check                    CI gate (exit 10 = needs cleaning)
    $SCRIPT_NAME --check --json > r.json    machine-readable CI report
    $SCRIPT_NAME --dry-run -v               explain every decision
    $SCRIPT_NAME --git                      only git-tracked files
    $SCRIPT_NAME --ext php,phtml,inc        custom extension set
    $SCRIPT_NAME --add-ext md,json          extend the default set
    $SCRIPT_NAME --exclude 'dist/*' --exclude-dir build
    $SCRIPT_NAME --force notes.txt          strip a "may-be-required" BOM
    $SCRIPT_NAME --bom-policy=keep          CRLF only, never touch BOMs
    $SCRIPT_NAME --no-bom-clear             v2-compatible: CRLF only
    $SCRIPT_NAME --backup --backup-dir /tmp/bak   keep mirrored backups
    $SCRIPT_NAME --check-update             is there a new release? (exit 11)
    $SCRIPT_NAME --update                   self-update from the repository
    $SCRIPT_NAME --self-test                verify the tool on this machine

GIT PRE-COMMIT HOOK  (.git/hooks/pre-commit, chmod +x)
    #!/bin/sh
    clean-bom-senior.sh --check --git --quiet || {
      echo "BOM/CRLF issues found. Run: clean-bom-senior.sh --git" >&2
      exit 1
    }
EOF
}

help_env() {
	cat <<'EOF'
ENVIRONMENT
  CLEAN_BOM_OPTS        Extra options prepended to argv (CI-wide defaults,
                        e.g. CLEAN_BOM_OPTS="--quiet --strict"). Simple
                        whitespace splitting — no quoting inside.
  CLEAN_BOM_GITHUB_REPO Repository slug used by --check-update/--update
                        (default: paulmann/Clean_BOM_Senior)
  CLEAN_BOM_UPDATE_URL  Base URL override for updates (mirrors / air-gapped
                        setups). Must serve VERSION and clean-bom-senior.sh;
                        file:// URLs work (used by the test-suite).
  NO_COLOR              Any value disables colours (https://no-color.org)
  CLICOLOR_FORCE=1      Force colours even when stderr is not a TTY
  TMPDIR                Temp directory for rollback copies (default /tmp)
EOF
}

help_ci() {
	cat <<'EOF'
CI / CD RECIPES
  Gate (fail the build when the tree is dirty):
      clean-bom-senior.sh --check --quiet          # exit 10 = dirty
  Gate + machine report as an artifact:
      clean-bom-senior.sh --check --json > bom-report.json; rc=$?
  Auto-fix job:
      clean-bom-senior.sh --quiet && git diff --exit-code
  Strict policy ("no protected/kept files may exist in this repo"):
      clean-bom-senior.sh --check --strict
  Updates: never run --update inside CI; pin the release tag instead.
  GitHub Actions: see .github/workflows/ci.yml for a ready-made job.
EOF
}

help_update() {
	cat <<EOF
AUTO-UPDATE
    $SCRIPT_NAME --check-update    compare local v$VERSION with the repository
    $SCRIPT_NAME --update          download and replace this script

  How it works:
    1. Fetch VERSION from the repository (release tag first, default branch
       as fallback; base URL overridable via CLEAN_BOM_UPDATE_URL).
    2. Compare numeric major.minor.patch against the running version.
    3. --update downloads clean-bom-senior.sh of that release, verifies it
       (shebang + embedded version stamp), then replaces the running file
       atomically via rename(2) — safe while this process keeps the old inode.

  Notes:
    • Requires curl or wget. There is no telemetry: nothing is fetched unless
      you explicitly pass --check-update / --update.
    • npm-managed installations are detected and refused (exit 3) — update
      those with: npm install -g clean-bom-senior@latest
    • Read-only install locations: re-run with sufficient privileges, or
      download manually:
      https://raw.githubusercontent.com/$REPO_SLUG_DEFAULT/main/clean-bom-senior.sh
EOF
}

help_files() {
	cat <<EOF
FILE TYPES & LIMITS
  Default extensions cleaned:   $EXTENSIONS_DEFAULT
  Always-safe-to-strip (code):  $STRIP_ALWAYS
  Sensitive (UTF-8 BOM may be required; kept when content is non-ASCII):
                                $SENSITIVE_DEFAULT
  Unknown extensions added via --ext/--add-ext are treated as sensitive
  (the safe default). Redefine with --sensitive-ext / --bom-policy.
  Max file size:                $(fmt_size "$MAX_SIZE_DEFAULT") by default (--max-size)
  Empty files:                  skipped by the walk (nothing to clean)
  UTF-16/UTF-32 files:          never modified (their BOM is part of the format)
  Binary (NUL) files:           never modified
EOF
}

help_json() {
	cat <<'EOF'
JSON REPORT (--json, printed on stdout)
  {
    "tool": "clean-bom-senior", "version": "3.0.0",
    "mode": "fix|dry-run|check",
    "startedAt": "<ISO-8601 UTC>", "durationSeconds": N, "cwd": "...",
    "options": { bomPolicy, noBomClear, noCrlfNormalize, force, extensions,
                 sensitiveExtensions, maxSizeBytes, keepMtime },
    "summary": { scanned, changed, wouldChange, clean, bomKept, bomRemoved,
                 crlfFixed, protectedUtf16or32, protectedBinary,
                 protectedInvalidUtf8, skippedOversize, errors },
    "files": [ { "path", "status", "encoding", "actions", "bomKept",
                 "reason" } ]
  }
  file.status ∈ changed | would-change | kept | protected | skipped-size |
                error
  Clean files are counted in summary.clean but NOT listed in "files" (keeps
  reports small on big trees). Logs stay on stderr — stdout is pure JSON.
EOF
}

help_compatibility() {
	cat <<'EOF'
COMPATIBILITY & IMPLEMENTATIONS
  All v2 flags are supported: -h -V -v -n --no-bom-clear --no-rn-normalize
  -- and the "FILES..." positional form. Behavioural upgrades in v3 (details
  in CHANGELOG.md): byte-exact detection, real timestamp preservation, a
  working --no-rn-normalize under MSYS, binary/UTF-16 protection, Smart BOM
  Policy, default exclusion of .git/node_modules, directory arguments,
  consistent exit codes, macOS (BSD stat) support.

  Implementation matrix:
    clean-bom-senior.sh   3.x    reference (Linux/macOS/WSL/Git Bash)
    bin/bom.js (npm CLI)  3.x    native Node.js — all platforms incl. Windows
    clean-bom-senior.ps1  3.x    PowerShell 7.6+ (Windows/Linux/macOS)
    clean-bom-senior.bat  2.07   legacy cmd.exe port (v2 contract, frozen)
  On Windows, use the npm CLI or the PowerShell port for v3 features:
      npm i -g clean-bom-senior
      ./clean-bom-senior.ps1 --help
  The first three are pinned to each other by differential tests
  (tests/node, tests/ps); the cmd.exe port is frozen — see docs/BAT-PORT.md.
EOF
}

show_help() {
	local topic="${1:-}"
	help_header
	case "$topic" in
		"")
			help_usage;          printf '\n'
			help_options;        printf '\n'
			help_bom_policy;     printf '\n'
			help_safety;         printf '\n'
			help_exit_codes;     printf '\n'
			help_examples;       printf '\n'
			help_env;            printf '\n'
			printf 'Topic help: %s --help TOPIC\nTopics: %s\n' "$SCRIPT_NAME" "$(help_topics_list)"
			;;
		usage)             help_usage ;;
		options|selection) help_options ;;
		bom-policy|bom|policy) help_bom_policy ;;
		safety)            help_safety ;;
		exit-codes|exit)   help_exit_codes ;;
		examples)          help_examples ;;
		env|environment)   help_env ;;
		ci)                help_ci ;;
		update)            help_update ;;
		files)             help_files ;;
		json)              help_json ;;
		compatibility|compat) help_compatibility ;;
		topics)            printf 'Topics: %s\n' "$(help_topics_list)" ;;
		*)
			printf 'Unknown help topic: %s\nTopics: %s\n' "$topic" "$(help_topics_list)" >&2
			cleanup "$EXIT_USAGE"
			;;
	esac
}

show_version() {
	printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"
	printf 'Author: Mikhail Deynekin <mid1977@gmail.com>\n'
	printf 'Website: https://deynekin.com\n'
}

show_completion() {
	cat <<'EOF'
# bash completion for clean-bom-senior — source this output:
#   eval "$(clean-bom-senior.sh --completion)"
_clean_bom_senior() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-h --help -V --version -v --verbose -n --dry-run -c --check -f --fix
          -q --quiet --silent -j --json --color --no-color --log-file
          --ext --add-ext --exclude --exclude-dir --no-default-excludes
          --max-size --git --bom-policy --sensitive-ext --force --strict
          --no-bom-clear --no-rn-normalize --no-crlf-normalize --update-mtime
          --no-keep-mtime --backup --backup-dir --check-update --update
          --self-test --completion"
    case "$prev" in
        --color)      COMPREPLY=( $(compgen -W "auto always never" -- "$cur") ); return 0 ;;
        --bom-policy) COMPREPLY=( $(compgen -W "auto strip keep" -- "$cur") ); return 0 ;;
        --help)       COMPREPLY=( $(compgen -W "usage options bom-policy safety exit-codes examples env ci update files json compatibility" -- "$cur") ); return 0 ;;
        --log-file|--backup-dir) COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    else
        COMPREPLY=( $(compgen -f -- "$cur") )
    fi
    return 0
}
complete -F _clean_bom_senior clean-bom-senior
complete -F _clean_bom_senior clean-bom-senior.sh
complete -F _clean_bom_senior bom
EOF
}

#------------------------------------------------------------------------------
# Self-test: proves THIS installation works on THIS machine (no repo needed).
#------------------------------------------------------------------------------
self_test() {
	local td pass=0 fail=0 rc tool
	if ! td="$(mktemp -d "${TMPDIR:-/tmp}/cleanbom-selftest.XXXXXX" 2>/dev/null)"; then
		die_internal "Cannot create self-test directory"
	fi
	tool="$SCRIPT_PATH_RESOLVED"
	hex() { od -An -tx1 -- "$1" 2>/dev/null | tr -d ' \n'; }
	st_check() { # name expected_hex file
		if [ "$(hex "$3")" = "$2" ]; then
			pass=$((pass + 1)); printf 'ok   %s\n' "$1"
		else
			fail=$((fail + 1)); printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$(hex "$3")" "$2"
		fi
	}

	printf '\xef\xbb\xbf<?php\r\necho 1;\r\n' >"$td/t1.php"
	rc=0; ( cd "$td" && "$tool" --quiet t1.php >/dev/null 2>&1 ) || rc=$?
	st_check "t1 php: BOM stripped, CRLF→LF" "3c3f7068700a6563686f20313b0a" "$td/t1.php"

	printf '\xff\xfeh\x00i\x00\r\x00\n\x00' >"$td/t2.txt"
	rc=0; ( cd "$td" && "$tool" --quiet t2.txt >/dev/null 2>&1 ) || rc=$?
	st_check "t2 utf16le: never touched" "fffe680069000d000a00" "$td/t2.txt"

	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$td/t3.txt"
	rc=0; ( cd "$td" && "$tool" --quiet t3.txt >/dev/null 2>&1 ) || rc=$?
	st_check "t3 sensitive txt: BOM kept, CRLF fixed" "efbbbf636166c3a90a" "$td/t3.txt"

	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$td/t4.txt"
	rc=0; ( cd "$td" && "$tool" --quiet --force t4.txt >/dev/null 2>&1 ) || rc=$?
	st_check "t4 --force strips sensitive BOM" "636166c3a90a" "$td/t4.txt"

	printf '\xef\xbb\xbfplain ascii\r\n' >"$td/t5.txt"
	rc=0; ( cd "$td" && "$tool" --quiet t5.txt >/dev/null 2>&1 ) || rc=$?
	st_check "t5 ascii-only txt: BOM stripped" "706c61696e2061736369690a" "$td/t5.txt"

	printf 'BIN\x00ARY\r\n' >"$td/t6.js"
	rc=0; ( cd "$td" && "$tool" --quiet t6.js >/dev/null 2>&1 ) || rc=$?
	st_check "t6 binary (NUL): never touched" "42494e004152590d0a" "$td/t6.js"

	printf 'clean file\r\n' >"$td/t7.css"
	rc=0; ( cd "$td" && "$tool" --quiet t7.css >/dev/null 2>&1 ) || rc=$?
	local ino1 ino2
	ino1="$(file_inode "$td/t7.css")"
	rc=0; ( cd "$td" && "$tool" --quiet t7.css >/dev/null 2>&1 ) || rc=$?
	ino2="$(file_inode "$td/t7.css")"
	if [ "$ino1" = "$ino2" ] && [ "$(hex "$td/t7.css")" = "636c65616e2066696c650a" ]; then
		pass=$((pass + 1)); printf 'ok   t7 clean file not rewritten (inode stable)\n'
	else
		fail=$((fail + 1)); printf 'FAIL t7\n'
	fi

	printf 'x\r\n' >"$td/t8.php"
	rc=0; ( cd "$td" && "$tool" --check t8.php >/dev/null 2>&1 ) || rc=$?
	if [ "$rc" -eq 10 ]; then
		pass=$((pass + 1)); printf 'ok   t8 --check exit 10 on dirty file\n'
	else
		fail=$((fail + 1)); printf 'FAIL t8 (rc=%s)\n' "$rc"
	fi
	rc=0; ( cd "$td" && "$tool" --quiet t8.php >/dev/null 2>&1 ) || rc=$?
	rc=0; ( cd "$td" && "$tool" --check t8.php >/dev/null 2>&1 ) || rc=$?
	if [ "$rc" -eq 0 ]; then
		pass=$((pass + 1)); printf 'ok   t9 --check exit 0 when clean\n'
	else
		fail=$((fail + 1)); printf 'FAIL t9 (rc=%s)\n' "$rc"
	fi

	rc=0; ( cd "$td" && "$tool" --json t8.php 2>/dev/null >"$td/out.json" ) || rc=$?
	if have node; then
		if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$td/out.json" >/dev/null 2>&1; then
			pass=$((pass + 1)); printf 'ok   t10 --json emits valid JSON\n'
		else
			fail=$((fail + 1)); printf 'FAIL t10\n'
		fi
	else
		if grep -q '"tool": "clean-bom-senior"' "$td/out.json"; then
			pass=$((pass + 1)); printf 'ok   t10 --json structure (node unavailable — grep check)\n'
		else
			fail=$((fail + 1)); printf 'FAIL t10\n'
		fi
	fi

	rm -rf -- "$td"
	printf '\nself-test: %d passed, %d failed\n' "$pass" "$fail"
	if [ "$fail" -eq 0 ]; then
		cleanup "$EXIT_OK"
	fi
	cleanup "$EXIT_FILE_ERRORS"
}

#------------------------------------------------------------------------------
# Update machinery (--check-update / --update)
#------------------------------------------------------------------------------
http_get() {
	# $1 = URL → stdout. curl preferred, wget fallback.
	if have curl; then
		curl -fsSL --connect-timeout 10 --max-time 60 -- "$1"
	elif have wget; then
		wget -q --timeout=15 --tries=2 -O - -- "$1"
	else
		log_error "Neither curl nor wget found — cannot perform network operations"
		return "$EXIT_ENV"
	fi
}

update_base_url() {
	if [ -n "${CLEAN_BOM_UPDATE_URL:-}" ]; then
		printf '%s' "${CLEAN_BOM_UPDATE_URL%/}"
	else
		printf 'https://raw.githubusercontent.com/%s/refs/heads/main' \
			"${CLEAN_BOM_GITHUB_REPO:-$REPO_SLUG_DEFAULT}"
	fi
}

fetch_remote_version() {
	local out
	out="$(http_get "$(update_base_url)/VERSION" 2>/dev/null | sed -n '1p' | tr -d '[:space:]' || true)"
	case "$out" in
		[0-9]*.[0-9]*.[0-9]*) printf '%s' "$out" ;;
		*) return 1 ;;
	esac
}

semver_gt() {
	# True when $1 > $2 (numeric major.minor.patch; any suffix is ignored).
	local a1 a2 a3 b1 b2 b3
	IFS='.' read -r a1 a2 a3 <<<"$(printf '%s' "$1" | sed 's/[^0-9.].*$//')"
	IFS='.' read -r b1 b2 b3 <<<"$(printf '%s' "$2" | sed 's/[^0-9.].*$//')"
	a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
	b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
	if [ "$a1" -ne "$b1" ]; then
		[ "$a1" -gt "$b1" ]
	elif [ "$a2" -ne "$b2" ]; then
		[ "$a2" -gt "$b2" ]
	else
		[ "$a3" -gt "$b3" ]
	fi
}

do_check_update() {
	local remote
	if ! remote="$(fetch_remote_version)"; then
		log_error "Could not determine the latest version from: $(update_base_url)"
		cleanup "$EXIT_ENV"
	fi
	if semver_gt "$remote" "$VERSION"; then
		log_warn "Update available: $VERSION -> $remote (run: $SCRIPT_NAME --update)"
		cleanup "$EXIT_UPDATE_AVAILABLE"
	fi
	log_info "Up to date (local $VERSION, remote $remote)"
	cleanup "$EXIT_OK"
}

do_update() {
	local remote resolved tag_url main_url content tmp target_dir
	if ! remote="$(fetch_remote_version)"; then
		log_error "Could not determine the latest version from: $(update_base_url)"
		cleanup "$EXIT_ENV"
	fi
	if ! semver_gt "$remote" "$VERSION"; then
		log_info "Already up to date (local $VERSION, remote $remote)"
		cleanup "$EXIT_OK"
	fi

	resolved="$(resolve_path "$SELF_PATH")"
	case "$resolved" in
		*/node_modules/*)
			log_error "This installation is npm-managed: $resolved"
			log_error "Update it with: npm install -g clean-bom-senior@latest"
			cleanup "$EXIT_ENV"
			;;
	esac
	if [ ! -w "$resolved" ]; then
		log_error "Cannot write to $resolved — re-run with sufficient privileges,"
		log_error "or download manually: https://raw.githubusercontent.com/${CLEAN_BOM_GITHUB_REPO:-$REPO_SLUG_DEFAULT}/refs/tags/v${remote}/clean-bom-senior.sh"
		cleanup "$EXIT_ENV"
	fi

	# Prefer the release tag; fall back to the default branch / mirror.
	content=""
	if [ -z "${CLEAN_BOM_UPDATE_URL:-}" ]; then
		tag_url="https://raw.githubusercontent.com/${CLEAN_BOM_GITHUB_REPO:-$REPO_SLUG_DEFAULT}/refs/tags/v${remote}/clean-bom-senior.sh"
		content="$(http_get "$tag_url" 2>/dev/null || true)"
	fi
	if [ -z "$content" ]; then
		main_url="$(update_base_url)/clean-bom-senior.sh"
		content="$(http_get "$main_url" 2>/dev/null || true)"
	fi
	if [ -z "$content" ]; then
		log_error "Download failed (tried the release tag and $(update_base_url))"
		cleanup "$EXIT_ENV"
	fi

	# Verify what we are about to install: shebang + version stamp.
	case "$content" in
		'#!/usr/bin/env bash'*) : ;;
		*)
			log_error "Downloaded content failed verification (bad shebang) — refusing to install"
			cleanup "$EXIT_ENV"
			;;
	esac
	# The consumer MUST read its input to EOF. `printf ... | grep -q` does not:
	# grep -q exits on the first match, the producer is still writing, and with
	# `set -o pipefail` the SIGPIPE on the producer becomes the status of the
	# whole pipeline - 141, which this `if !` reads as "stamp not found".
	# Measured on Git Bash 5.3.15 with an 80 631-byte published script against a
	# 64 KiB pipe buffer: PIPESTATUS was `141 0` (grep matched, printf was
	# killed), so --update refused to install a perfectly valid release. macOS
	# pipe buffers are 16 KiB, so this is not limited to MSYS - it is a defect of
	# this release's own updater, and it stayed invisible in v2 only because that
	# script was 23 KB, below any of those buffers.
	# awk reads to EOF, so there is no SIGPIPE; `index() == 1` is the "starts
	# with" test, and being a literal substring match it does not let the dots
	# in `${remote}` act as regex wildcards the way `grep '^VERSION="..."'` did.
	if ! printf '%s' "$content" | awk -v want="VERSION=\"${remote}\"" '
		index($0, want) == 1 { found = 1 }
		END { exit !found }
	'; then
		log_error "Downloaded content failed verification (version stamp != $remote) — refusing to install"
		cleanup "$EXIT_ENV"
	fi

	target_dir="$(dirname -- "$resolved")"
	if ! tmp="$(mktemp "${target_dir}/.cleanbom-update.XXXXXX" 2>/dev/null)"; then
		die_internal "Cannot create update temp file in $target_dir"
	fi
	register_temp "$tmp"
	printf '%s\n' "$content" >"$tmp"
	chmod 755 -- "$tmp"
	mv -f -- "$tmp" "$resolved"
	printf 'Updated %s: %s -> %s (%s)\n' "$SCRIPT_NAME" "$VERSION" "$remote" "$resolved" >&2
	cleanup "$EXIT_OK"
}

#------------------------------------------------------------------------------
# Argument parsing (GNU-style interspersed; every v2 flag preserved)
#------------------------------------------------------------------------------
normalize_ext_list() {
	# "PHP, .Js ,,ts" → "php js ts"
	printf '%s' "$1" | tr ',.' '  ' | tr '[:upper:]' '[:lower:]' |
		tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

parse_size() {
	local spec="$1" num unit
	num="$(printf '%s' "$spec" | sed 's/[^0-9].*$//')"
	unit="$(printf '%s' "$spec" | sed "s/^${num}//" | tr '[:lower:]' '[:upper:]')"
	[ -n "$num" ] || return 1
	case "$unit" in
		""|B)   printf '%s' "$num" ;;
		K|KB)   printf '%s' "$((num * 1024))" ;;
		M|MB)   printf '%s' "$((num * 1024 * 1024))" ;;
		G|GB)   printf '%s' "$((num * 1024 * 1024 * 1024))" ;;
		*)      return 1 ;;
	esac
}

parse_arguments() {
	local size_parsed add_ext_tmp
	while [ $# -gt 0 ]; do
		case "$1" in
			-h|--help)
				SHOW_HELP=1
				if [ $# -ge 2 ]; then
					case "$2" in
						-*) : ;;
						*)  HELP_TOPIC="$2"; shift ;;
					esac
				fi
				;;
			-V|--version)      SHOW_VERSION=1 ;;
			-v|--verbose)      VERBOSE=1 ;;
			-n|--dry-run)      DRY_RUN=1; VERBOSE=1 ;;
			-c|--check)        CHECK_MODE=1; QUIET=1 ;;
			-f|--fix)          : ;; # default mode; accepted for explicitness
			-q|--quiet)        QUIET=1 ;;
			--silent)          QUIET=1; SILENT=1 ;;
			-j|--json)         JSON_OUT=1 ;;
			--color)           shift; [ $# -ge 1 ] || die_usage "--color requires a value (auto|always|never)"; COLOR_MODE="$1" ;;
			--color=*)         COLOR_MODE="${1#--color=}" ;;
			--no-color)        COLOR_MODE="never" ;;
			--log-file)        shift; [ $# -ge 1 ] || die_usage "--log-file requires a value"; LOG_FILE="$1" ;;
			--log-file=*)      LOG_FILE="${1#--log-file=}" ;;
			--ext)             shift; [ $# -ge 1 ] || die_usage "--ext requires a value"; EXTENSIONS="$(normalize_ext_list "$1")" ;;
			--ext=*)           EXTENSIONS="$(normalize_ext_list "${1#--ext=}")" ;;
			--add-ext)         shift; [ $# -ge 1 ] || die_usage "--add-ext requires a value"; add_ext_tmp="$(normalize_ext_list "$1")"; EXTENSIONS="$(normalize_ext_list "$EXTENSIONS $add_ext_tmp")" ;;
			--add-ext=*)       add_ext_tmp="$(normalize_ext_list "${1#--add-ext=}")"; EXTENSIONS="$(normalize_ext_list "$EXTENSIONS $add_ext_tmp")" ;;
			--sensitive-ext)   shift; [ $# -ge 1 ] || die_usage "--sensitive-ext requires a value (use '' to disable)"; SENSITIVE_EXTS="$(normalize_ext_list "$1")" ;;
			--sensitive-ext=*) SENSITIVE_EXTS="$(normalize_ext_list "${1#--sensitive-ext=}")" ;;
			--exclude)         shift; [ $# -ge 1 ] || die_usage "--exclude requires a pattern"
			                   EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}${1}
" ;;
			--exclude=*)       EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}${1#--exclude=}
" ;;
			--exclude-dir)     shift; [ $# -ge 1 ] || die_usage "--exclude-dir requires a name"
			                   EXCLUDE_DIRS="$EXCLUDE_DIRS $1"; USER_EXCLUDE_DIRS="$USER_EXCLUDE_DIRS $1" ;;
			--exclude-dir=*)   EXCLUDE_DIRS="$EXCLUDE_DIRS ${1#--exclude-dir=}"
			                   USER_EXCLUDE_DIRS="$USER_EXCLUDE_DIRS ${1#--exclude-dir=}" ;;
			--no-default-excludes) USE_DEFAULT_EXCLUDES=0 ;;
			--max-size)        shift; [ $# -ge 1 ] || die_usage "--max-size requires a value"
			                   size_parsed="$(parse_size "$1")" || die_usage "Invalid --max-size: $1 (examples: 512K, 10M, 1G, 1048576)"; MAX_SIZE="$size_parsed" ;;
			--max-size=*)      size_parsed="$(parse_size "${1#--max-size=}")" || die_usage "Invalid --max-size: ${1#--max-size=}"; MAX_SIZE="$size_parsed" ;;
			--bom-policy)      shift; [ $# -ge 1 ] || die_usage "--bom-policy requires a value (auto|strip|keep)"; BOM_POLICY="$1" ;;
			--bom-policy=*)    BOM_POLICY="${1#--bom-policy=}" ;;
			--force)           FORCE=1 ;;
			--strict)          STRICT=1 ;;
			--git)             GIT_MODE=1 ;;
			--no-bom-clear)    NO_BOM_CLEAR=1 ;;
			--no-rn-normalize|--no-crlf-normalize) NO_CRLF_NORMALIZE=1 ;;
			--update-mtime|--no-keep-mtime) KEEP_MTIME=0 ;;
			--backup)          BACKUP=1 ;;
			--backup-dir)      shift; [ $# -ge 1 ] || die_usage "--backup-dir requires a directory"; BACKUP=1; BACKUP_DIR="$1" ;;
			--backup-dir=*)    BACKUP=1; BACKUP_DIR="${1#--backup-dir=}" ;;
			--check-update)    DO_CHECK_UPDATE=1 ;;
			--update)          DO_UPDATE=1 ;;
			--self-test)       SELF_TEST=1 ;;
			--completion)      SHOW_COMPLETION=1 ;;
			--)                shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
			-*)                log_error "Unknown option: $1"; cleanup "$EXIT_USAGE" ;;
			*)                 POSITIONAL+=("$1") ;;
		esac
		shift
	done

	case "$BOM_POLICY" in
		auto|strip|keep) : ;;
		*) die_usage "Invalid --bom-policy: $BOM_POLICY (expected auto|strip|keep)" ;;
	esac
	EXTENSIONS="$(normalize_ext_list "$EXTENSIONS")"
	if [ -z "$EXTENSIONS" ]; then
		die_usage "Extension list is empty — nothing to do (check --ext/--add-ext)"
	fi
	if [ "$USE_DEFAULT_EXCLUDES" -eq 0 ]; then
		EXCLUDE_DIRS="$(printf '%s' "$USER_EXCLUDE_DIRS" | tr -s ' ' ' ' | sed 's/^ //; s/ $//')"
	fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
	local rc=0 arg target
	START_TIME="$(date +%s)"
	START_TIME_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	SELF_PATH="$0"
	SCRIPT_PATH_RESOLVED="$(resolve_path "$0")"

	# CLEAN_BOM_OPTS: CI-wide default options (see --help env).
	if [ -n "${CLEAN_BOM_OPTS:-}" ]; then
		local -a extra_opts=()
		read -r -a extra_opts <<<"${CLEAN_BOM_OPTS}" || true
		if [ "${#extra_opts[@]}" -gt 0 ]; then
			parse_arguments "${extra_opts[@]}" "$@"
		else
			parse_arguments "$@"
		fi
	else
		parse_arguments "$@"
	fi

	color_init

	if [ -n "$LOG_FILE" ]; then
		if ! : >>"$LOG_FILE" 2>/dev/null; then
			die_env "Cannot write to log file: $LOG_FILE"
		fi
		printf '\n===== %s v%s run at %s =====\n' "$SCRIPT_NAME" "$VERSION" "$(get_timestamp)" >>"$LOG_FILE"
	fi

	# Information modes short-circuit everything else.
	if [ "$SHOW_COMPLETION" -eq 1 ]; then
		show_completion
		cleanup "$EXIT_OK"
	fi
	if [ "$SHOW_HELP" -eq 1 ]; then
		show_help "$HELP_TOPIC"
		cleanup "$EXIT_OK"
	fi
	if [ "$SHOW_VERSION" -eq 1 ]; then
		show_version
		cleanup "$EXIT_OK"
	fi

	check_dependencies || cleanup $?
	stat_probe

	if [ "$SELF_TEST" -eq 1 ]; then
		self_test
	fi
	if [ "$DO_CHECK_UPDATE" -eq 1 ]; then
		do_check_update
	fi
	if [ "$DO_UPDATE" -eq 1 ]; then
		do_update
	fi

	if [ "$CHECK_MODE" -eq 0 ] && [ "$QUIET" -eq 0 ] && [ "$JSON_OUT" -eq 0 ]; then
		show_greeting
	fi

	if [ "$GIT_MODE" -eq 1 ]; then
		if [ "${#POSITIONAL[@]}" -gt 0 ]; then
			GIT_PATHSPEC=("${POSITIONAL[@]}")
		fi
		scan_git_tracked
	elif [ "${#POSITIONAL[@]}" -eq 0 ]; then
		log_info "Recursive mode: scanning '.' for extensions: $EXTENSIONS"
		scan_directory "."
	else
		for arg in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do
			if [ -d "$arg" ] && [ ! -L "$arg" ]; then
				log_info "Directory mode: scanning '$arg' for extensions: $EXTENSIONS"
				scan_directory "$arg"
			elif [ -L "$arg" ] && [ -d "$arg" ]; then
				log_info "Directory mode (symlink resolved): scanning '$arg'"
				scan_directory "$(resolve_path "$arg")"
			elif [ -f "$arg" ] || [ -L "$arg" ]; then
				if [ -L "$arg" ]; then
					target="$(resolve_path "$arg")"
					log_info "Symlink argument resolved: $arg -> $target"
					handle_file "$arg" "$target" || FILE_ERRORS=1
				else
					handle_file "$arg" "$arg" || FILE_ERRORS=1
				fi
			else
				log_error "File not found: $arg"
				ERR_ACCESS=$((ERR_ACCESS + 1))
				FILE_ERRORS=1
			fi
		done
	fi

	# ---- reporting ---------------------------------------------------------
	if [ "$JSON_OUT" -eq 1 ]; then
		json_report
	fi
	if [ "$CHECK_MODE" -eq 1 ]; then
		if [ "$QUIET" -eq 1 ] && [ "$VERBOSE" -eq 0 ]; then
			printf 'check: %d file(s) need cleaning, %d kept/protected, %d error(s)\n' \
				"$WOULD_CHANGE_COUNT" \
				$((KEPT_BOM_COUNT + PROTECTED_UTF16_COUNT + PROTECTED_BINARY_COUNT + PROTECTED_INVALID_COUNT)) \
				"$ERROR_COUNT" >&2
		else
			display_statistics
		fi
	elif [ "$QUIET" -eq 0 ] && [ "$SILENT" -eq 0 ]; then
		display_statistics
	fi

	# ---- exit code ---------------------------------------------------------
	if [ "$FILE_ERRORS" -eq 1 ] || [ "$ERROR_COUNT" -gt 0 ]; then
		rc="$EXIT_FILE_ERRORS"
	elif [ "$STRICT" -eq 1 ] &&
	     [ $((KEPT_BOM_COUNT + PROTECTED_UTF16_COUNT + PROTECTED_BINARY_COUNT +
	          PROTECTED_INVALID_COUNT + SKIPPED_SIZE_COUNT)) -gt 0 ]; then
		log_warn "--strict: $((KEPT_BOM_COUNT + PROTECTED_UTF16_COUNT + PROTECTED_BINARY_COUNT + PROTECTED_INVALID_COUNT + SKIPPED_SIZE_COUNT)) file(s) kept/protected/skipped"
		rc="$EXIT_FILE_ERRORS"
	elif [ "$CHECK_MODE" -eq 1 ] && [ "$WOULD_CHANGE_COUNT" -gt 0 ]; then
		rc="$EXIT_CHECK_FOUND"
	fi
	cleanup "$rc"
}

main "$@"
