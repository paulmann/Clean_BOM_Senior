#!/usr/bin/env bash
#===============================================================================
# Clean BOM Senior v3 — reference (shell) test suite
#===============================================================================
# Portable bash >= 3.2, GNU/BSD userland. No external test framework.
#
#   Usage:  tests/sh/run-tests.sh [-k] [-v] [FILTER]
#             -k       keep the last workspace on failure
#             -v       verbose (stream tool stderr for failures)
#             FILTER   substring; run only tests whose name contains it
#
#   Exit:   0 = all tests passed, 1 = at least one failure, 2 = prerequisite
#           missing (bash, tool, node for JSON validation).
#
# Every test builds raw-byte fixtures in a fresh workspace, runs the tool as a
# user would (separate process, explicit working directory) and asserts the
# resulting BYTES, exit codes and report content. Fixtures are written with
# printf escapes only — never as "text" that an editor or git could normalise.
#===============================================================================
# Note for linters: every t_* function is invoked dynamically via run_test
# ("$fn"), so static analysis cannot see the calls (SC2317); and the
# `[ cond ] && ok || bad` idiom is safe because ok/bad never fail (SC2015).
# shellcheck disable=SC2317,SC2015,SC2016
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO_ROOT/clean-bom-senior.sh"

KEEP=0
VERBOSE_RUN=0
FILTER=""
while [ $# -gt 0 ]; do
	case "$1" in
		-k) KEEP=1 ;;
		-v) VERBOSE_RUN=1 ;;
		*)  FILTER="$1" ;;
	esac
	shift
done

[ -f "$TOOL" ] || { echo "FATAL: tool not found: $TOOL" >&2; exit 2; }
HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1
HAVE_GIT=0
command -v git >/dev/null 2>&1 && HAVE_GIT=1
HAVE_CURL=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# --- What this host can actually do ------------------------------------------
# These probes exist because asserting an environment capability the host does
# not have produces a red suite for a reason that has nothing to do with the
# tool. Each one was measured on Git Bash 5.3.15 (MSYS) before it was written:
#   chmod 640            -> 644        (no group bit in the MSYS permission map)
#   ln -s a b; [ -L b ]  -> false      (MSYS copies instead of linking)
#   ln a b (hard link)   -> works      (same inode)
#   curl file:///tmp/x   -> empty      (ucrt64 curl needs a native drive path)
# A capability that is missing is reported as SKIPPED with the reason, never as
# a pass, and never as a failure of the tool.
HARNESS_TMP="${TMPDIR:-/tmp}"
HAVE_SYMLINK=0
HAVE_POSIX_PERMS=0
HAVE_FILE_URL=0
if [ "$IS_ROOT" -eq 0 ] || [ "$(uname -s)" = "Linux" ] || [ "$(uname -s)" = "Darwin" ]; then
	_probe_dir="$HARNESS_TMP/cleanbom-probe.$$"
	mkdir -p "$_probe_dir" 2>/dev/null && {
		printf 'x\n' >"$_probe_dir/a" 2>/dev/null
		# A real symlink: MSYS only emulates it when the shell variable
		# MSYS=winsymlinks:nativestrict is set, which is not the default.
		ln -s a "$_probe_dir/b" 2>/dev/null
		[ -L "$_probe_dir/b" ] && HAVE_SYMLINK=1
		# A POSIX permission bit outside the MSYS map: chmod 640 yields 644.
		chmod 604 "$_probe_dir/a" 2>/dev/null
		[ "$(stat -c %a "$_probe_dir/a" 2>/dev/null || stat -f %Lp "$_probe_dir/a" 2>/dev/null)" = "604" ] && HAVE_POSIX_PERMS=1
		# curl has to resolve the path it is given; a native drive path is the
		# only form the ucrt64 build understands, even when the shell is POSIX.
		if [ "$HAVE_CURL" -eq 1 ]; then
			printf '0.0.1\n' >"$_probe_dir/VERSION" 2>/dev/null
			_probe_url="file://$_probe_dir/VERSION"
			if command -v cygpath >/dev/null 2>&1; then
				_probe_url="file://$(cygpath -m "$_probe_dir")/VERSION"
			fi
			[ "$(curl -fsS "$_probe_url" 2>/dev/null)" = "0.0.1" ] && HAVE_FILE_URL=1
		fi
	}
	rm -rf "$_probe_dir" 2>/dev/null
fi

PASS=0
FAIL=0
FAILED_NAMES=""
WS=""
LAST_LOG=""

# --- colors (only when stdout is a tty) --------------------------------------
if [ -t 1 ]; then
	C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[1;33m'; C_RST=$'\033[0m'
else
	C_RED=""; C_GRN=""; C_YLW=""; C_RST=""
fi

#------------------------------------------------------------------------------
# Harness
#------------------------------------------------------------------------------
new_ws() {
	[ -n "$WS" ] && rm -rf "$WS"
	WS="$(mktemp -d "${TMPDIR:-/tmp}/cleanbom-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
	mkdir -p "$WS/work"
	LAST_LOG="$WS/stderr.log"
}

tool() {
	# Run the tool inside $WS/work; stderr captured to $LAST_LOG, stdout passthrough
	# to the caller (redirect as needed). Returns the tool's exit code.
	local rc=0
	( cd "$WS/work" && bash "$TOOL" "$@" >"$WS/stdout.log" 2>"$LAST_LOG" ) || rc=$?
	return "$rc"
}

tool_stdout() { cat "$WS/stdout.log"; }
tool_stderr() { cat "$LAST_LOG"; }

hex() { od -An -v -tx1 -- "$1" 2>/dev/null | tr -d ' \n'; }  # -v: no '*' line compression

ok()   { PASS=$((PASS + 1)); printf '%sok%s   %s\n' "$C_GRN" "$C_RST" "$1"; }
bad()  {
	FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $1"
	printf '%sFAIL%s %s\n' "$C_RED" "$C_RST" "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
	if [ "$VERBOSE_RUN" -eq 1 ]; then
		printf '       --- tool stderr ---\n'
		sed 's/^/       | /' "$LAST_LOG" 2>/dev/null | head -30
	fi
}

assert_bytes() { # file expected_hex name
	local got
	got="$(hex "$1")"
	if [ "$got" = "$2" ]; then
		ok "$3"
	else
		bad "$3" "bytes of $1: got [$got] want [$2]"
	fi
}

assert_rc() { # actual expected name
	if [ "$1" -eq "$2" ]; then
		ok "$3 (rc=$1)"
	else
		bad "$3" "exit code: got $1 want $2"
	fi
}

assert_grep() { # file pattern name
	if grep -q -- "$2" "$1" 2>/dev/null; then
		ok "$3"
	else
		bad "$3" "pattern [$2] not found in $1"
	fi
}

assert_not_grep() { # file pattern name
	if grep -q -- "$2" "$1" 2>/dev/null; then
		bad "$3" "pattern [$2] unexpectedly found in $1"
	else
		ok "$3"
	fi
}

assert_file()  { if [ -f "$1" ]; then ok "$2"; else bad "$2" "missing file: $1"; fi; }
assert_nofile() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2" "unexpected file: $1"; fi; }

mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null; }
inode() { stat -c %i -- "$1" 2>/dev/null || stat -f %i -- "$1" 2>/dev/null; }

section() { printf '\n%s== %s ==%s\n' "$C_YLW" "$1" "$C_RST"; }

run_test() { # name function
	local name="$1" fn="$2"
	if [ -n "$FILTER" ]; then
		case "$name" in
			*"$FILTER"*) : ;;
			*) return 0 ;;
		esac
	fi
	new_ws
	# shellcheck disable=SC2086 # fn name is internal, never user input
	"$fn"
}

finish() {
	local rc=0
	printf '\n----------------------------------------\n'
	if [ "$FAIL" -eq 0 ]; then
		printf '%sALL PASSED%s: %d assertions\n' "$C_GRN" "$C_RST" "$PASS"
	else
		printf '%sFAILURES%s: %d passed, %d failed\n' "$C_RED" "$C_RST" "$PASS" "$FAIL"
		printf 'failed tests:%s\n' "$FAILED_NAMES"
		rc=1
	fi
	if [ "$KEEP" -eq 1 ] && [ "$FAIL" -gt 0 ]; then
		printf 'workspace kept: %s\n' "$WS"
	else
		[ -n "$WS" ] && rm -rf "$WS"
	fi
	exit "$rc"
}

#==============================================================================
# Byte fixtures (raw, via printf escapes)
#==============================================================================
mk_bom_crlf_php() { printf '\xef\xbb\xbf<?php\r\necho 1;\r\n' >"$WS/work/a.php"; }

#==============================================================================
# 1. Core cleaning
#==============================================================================
t_core_bom_crlf() {
	mk_bom_crlf_php
	tool --quiet a.php
	assert_rc $? 0 "core: exit 0"
	assert_bytes "$WS/work/a.php" "3c3f7068700a6563686f20313b0a" "core: BOM stripped + CRLF→LF"
}

t_core_bom_only() {
	printf '\xef\xbb\xbf<?php\n' >"$WS/work/b.php"
	tool --quiet b.php
	assert_bytes "$WS/work/b.php" "3c3f7068700a" "core: BOM-only stripped"
}

t_core_crlf_only() {
	printf 'x = 1;\r\ny = 2;\r\n' >"$WS/work/c.js"
	tool --quiet c.js
	assert_bytes "$WS/work/c.js" "78203d20313b0a79203d20323b0a" "core: CRLF-only normalized"
}

t_core_clean_untouched() {
	printf '<?php\necho 1;\n' >"$WS/work/d.php"
	touch -d '2019-05-05 05:05:05' "$WS/work/d.php" 2>/dev/null || touch -t 1905050505 "$WS/work/d.php"
	local i1 m1
	i1="$(inode "$WS/work/d.php")"; m1="$(mtime "$WS/work/d.php")"
	tool --quiet d.php
	local i2 m2
	i2="$(inode "$WS/work/d.php")"; m2="$(mtime "$WS/work/d.php")"
	[ "$i1" = "$i2" ] && ok "clean: inode stable (not rewritten)" || bad "clean: inode stable" "$i1 -> $i2"
	[ "$m1" = "$m2" ] && ok "clean: mtime stable" || bad "clean: mtime stable" "$m1 -> $m2"
}

t_core_empty_file() {
	: >"$WS/work/empty.xml"
	tool --quiet empty.xml
	assert_rc $? 0 "empty file: exit 0"
	assert_bytes "$WS/work/empty.xml" "" "empty file: still empty"
}

t_core_bom_only_3bytes() {
	printf '\xef\xbb\xbf' >"$WS/work/onlybom.htm"
	tool --quiet onlybom.htm
	assert_bytes "$WS/work/onlybom.htm" "" "3-byte BOM-only file becomes empty"
}

t_core_no_trailing_newline() {
	printf '\xef\xbb\xbfnoeol\r\nsecond' >"$WS/work/noeol.php"
	tool --quiet noeol.php
	assert_bytes "$WS/work/noeol.php" "6e6f656f6c0a7365636f6e64" "no-trailing-newline preserved (no \\n added)"
}

t_core_late_crlf_regression() {
	# v2 defect: CRLF beyond the first 1024 bytes was invisible.
	{ head -c 2000 /dev/zero | tr '\0' 'x'; printf 'y\r\nz\n'; } >"$WS/work/late.php"
	tool --quiet late.php
	assert_bytes "$WS/work/late.php" "$( { head -c 2000 /dev/zero | tr '\0' 'x'; printf 'y\nz\n'; } | od -An -v -tx1 | tr -d ' \n')" \
		"regression: CRLF past byte 1024 is found and fixed"
}

t_core_hex_false_positive_regression() {
	# v2 defect: hex-window detection flagged byte runs like 30 d0 a5 as "0d0a".
	printf '0\xd0\xa5tail\n' >"$WS/work/fp.php"
	local i1; i1="$(inode "$WS/work/fp.php")"
	tool --quiet fp.php
	local i2; i2="$(inode "$WS/work/fp.php")"
	[ "$i1" = "$i2" ] && ok "regression: no hex false positive (inode stable)" || bad "regression: hex false positive" "file was rewritten: $i1 -> $i2"
}

t_core_uppercase_ext() {
	printf '\xef\xbb\xbfX\r\n' >"$WS/work/UP.PHP"
	tool --quiet UP.PHP
	assert_bytes "$WS/work/UP.PHP" "580a" "uppercase extension .PHP processed"
}

t_core_crlf_at_eof_and_lone_cr() {
	# Documented semantics: lone CRs mid-line are preserved; when a file IS
	# rewritten for real CRLFs, a trailing CR at EOF is removed too (v2 sed
	# semantics, AGENTS invariant 7).
	printf 'a\rb\r\nc\r' >"$WS/work/mix.php"
	tool --quiet mix.php
	assert_bytes "$WS/work/mix.php" "610d620a63" "mixed: lone CR kept, CRLF fixed, EOF CR removed"
	# CR-only file (no LF at all) must never be flagged/rewritten:
	printf 'a\rb\rc\r' >"$WS/work/cronly.php"
	local i1; i1="$(inode "$WS/work/cronly.php")"
	tool --quiet cronly.php
	local i2; i2="$(inode "$WS/work/cronly.php")"
	[ "$i1" = "$i2" ] && ok "CR-only file untouched" || bad "CR-only file untouched" "inode changed"
	assert_bytes "$WS/work/cronly.php" "610d620d630d" "CR-only bytes intact"
}

t_core_cr_run_before_lf() {
	# A RUN of CRs before the LF collapses to that one LF. The single-CR rule
	# this guards (`s/CR$//` once per line) was NOT idempotent on a run: it left
	# `x CR CR LF` as `x LF CR LF`, which verify_clean_content then rejected, so
	# the tool reported "Verification failed after cleaning" and threw a valid
	# file away. Measured on all three implementations before the fix.
	printf 'x\r\r\ny\r\n' >"$WS/work/run.php"
	tool --quiet run.php
	assert_bytes "$WS/work/run.php" "780a790a" "CR run before LF collapses to one LF"
	# The collapsed result must be a no-op on the next run, otherwise the tool
	# would rewrite a tree it had already cleaned and report nonzero CRLF fixes.
	printf 'a\r\r\nb\r\r\n' >"$WS/work/many.php"
	tool --quiet many.php
	assert_bytes "$WS/work/many.php" "610a620a" "CR runs collapse on every line"
	local i1 i2
	i1="$(inode "$WS/work/many.php")"
	tool --quiet many.php
	i2="$(inode "$WS/work/many.php")"
	assert_bytes "$WS/work/many.php" "610a620a" "a second run changes nothing"
	[ "$i1" = "$i2" ] && ok "a second run does not rewrite (not a candidate)" || bad "CR run idempotence" "inode changed on the second run"
}

#==============================================================================
# 2. Smart BOM Policy — the safety core
#==============================================================================
t_policy_utf16le_protected() {
	printf '\xff\xfeh\x00i\x00\r\x00\n\x00' >"$WS/work/u16.txt"
	tool --quiet u16.txt
	assert_bytes "$WS/work/u16.txt" "fffe680069000d000a00" "utf16le: never touched"
	# A UTF-16 file that CONTAINS a literal ASCII CRLF pair must be refused too
	# (v2 would have rewritten it through sed):
	printf '\xff\xfeh\x00\r\nZZ' >"$WS/work/u16mix.txt"
	tool --quiet u16mix.txt
	assert_bytes "$WS/work/u16mix.txt" "fffe68000d0a5a5a" "utf16le with ASCII CRLF inside: still never touched"
	assert_grep "$LAST_LOG" "structurally required" "utf16: refusal is explained in the log"
}

t_policy_utf16be_utf32_protected() {
	printf '\xfe\xff\x00h\x00i\r\n' >"$WS/work/u16be.txt"
	printf '\xff\xfe\x00\x00h\x00\x00\x00\r\n' >"$WS/work/u32le.txt"
	printf '\x00\x00\xfe\xff\x00\x00\x00h\r\n' >"$WS/work/u32be.txt"
	tool --quiet u16be.txt u32le.txt u32be.txt
	assert_bytes "$WS/work/u16be.txt" "feff006800690d0a" "utf16be: never touched"
	assert_bytes "$WS/work/u32le.txt" "fffe0000680000000d0a" "utf32le: never touched"
	assert_bytes "$WS/work/u32be.txt" "0000feff000000680d0a" "utf32be: never touched"
	# Even --force must refuse (hard refusal):
	tool --quiet --force u16be.txt u32le.txt u32be.txt
	assert_bytes "$WS/work/u16be.txt" "feff006800690d0a" "utf16be: --force cannot override hard refusal"
	assert_bytes "$WS/work/u32le.txt" "fffe0000680000000d0a" "utf32le: --force cannot override hard refusal"
}

t_policy_utf16_crlf_detection_regression() {
	# REGRESSION: has_crlf used to be line-based (grep '<CR>$' / an awk
	# end-of-line test). Every line-oriented tool defines "end of line" by the
	# LF byte, so it cannot tell a CR that is IMMEDIATELY followed by LF from a
	# CR that merely ends an LF-delimited line. UTF-16LE encodes CR as 0D 00 and
	# LF as 00 0A, so `... 0D 00 0A` has a CR at end-of-line but no `0D 0A`
	# pair: such a file was flagged as a modification candidate and reported as
	# a protected UTF-16 file, inflating protectedUtf16or32 and warning about
	# files that needed nothing. That contradicts AGENTS.md invariant 3
	# ("CRLF = byte 0D immediately before 0A"), docs/SMART-BOM.md section 2 and
	# bin/bom.js, which was already byte-exact.
	#
	# The existing UTF-16 fixtures do not catch this: every one of them contains
	# a literal ASCII 0D 0A pair, so both detectors agree on them.
	printf '\xff\xfeh\x00i\x00\r\x00\n\x00' >"$WS/work/u16le_noncrlf.txt"
	printf '\xfe\xff\x00h\x00i\x00\x00\r\x00\n' >"$WS/work/u16be_noncrlf.xml"
	printf '\xff\xfe\x00\x00\x00h\x00\x00\x00i\r\x00\x00\x00\n' >"$WS/work/u32le_noncrlf.txt"
	tool --quiet u16le_noncrlf.txt u16be_noncrlf.xml u32le_noncrlf.txt
	assert_bytes "$WS/work/u16le_noncrlf.txt" "fffe680069000d000a00" "utf16le without a 0D0A pair: untouched"
	assert_bytes "$WS/work/u16be_noncrlf.xml" "feff0068006900000d000a" "utf16be without a 0D0A pair: untouched"
	assert_bytes "$WS/work/u32le_noncrlf.txt" "fffe00000068000000690d0000000a" "utf32le without a 0D0A pair: untouched"
	assert_not_grep "$LAST_LOG" "structurally required" "no UTF-16 refusal is logged for a file with no real CRLF"
	assert_not_grep "$LAST_LOG" "NOT touched" "nothing is reported as protected"
	tool --json --quiet u16le_noncrlf.txt u16be_noncrlf.xml u32le_noncrlf.txt
	assert_grep "$WS/stdout.log" '"protectedUtf16or32": 0' "protectedUtf16or32 stays 0"
	assert_grep "$WS/stdout.log" '"clean": 3' "all three are clean, not candidates"
	# A UTF-16 file that DOES contain a literal 0D 0A pair is still refused.
	printf '\xff\xfeh\x00\r\nZZ' >"$WS/work/u16le_realcrlf.txt"
	tool --quiet u16le_realcrlf.txt
	assert_bytes "$WS/work/u16le_realcrlf.txt" "fffe68000d0a5a5a" "utf16le WITH a real 0D0A pair: still never touched"
	assert_grep "$LAST_LOG" "structurally required" "the real-CRLF case is still refused and explained"
}

t_policy_binary_nul_protected() {
	printf '\xef\xbb\xbfBIN\x00ARY\r\n' >"$WS/work/bin1.txt"
	printf 'BIN\x00ARY\r\n' >"$WS/work/bin2.js"
	# NUL beyond the first 8 KiB (the v2-port probe window) must be found too:
	{ printf '\xef\xbb\xbf'; head -c 9000 /dev/zero | tr '\0' 'x'; printf '\x00\r\n'; } >"$WS/work/bin3.php"
	tool --quiet bin1.txt bin2.js bin3.php
	assert_bytes "$WS/work/bin1.txt" "efbbbf42494e004152590d0a" "binary with BOM: never touched"
	assert_bytes "$WS/work/bin2.js" "42494e004152590d0a" "binary no BOM + CRLF: never touched"
	assert_bytes "$WS/work/bin3.php" "efbbbf$(head -c 9000 /dev/zero | tr '\0' 'x' | od -An -v -tx1 | tr -d ' \n')000d0a" "binary with far NUL: never touched"
	assert_grep "$LAST_LOG" "NUL bytes" "binary: refusal is explained"
}

t_policy_invalid_utf8_protected() {
	# cp1251 text with a UTF-8 BOM: bytes c0 c1 are not valid UTF-8 sequences.
	printf '\xef\xbb\xbf\xc0\xc1\r\n' >"$WS/work/bad.php"
	tool --quiet bad.php
	local got; got="$(hex "$WS/work/bad.php")"
	if [ "$got" = "efbbbfc0c10d0a" ]; then
		ok "invalid UTF-8: untouched by default"
	else
		bad "invalid UTF-8: untouched by default" "got [$got]"
	fi
	assert_grep "$LAST_LOG" "not valid UTF-8" "invalid UTF-8: refusal explained + --force hint"
	# --force: byte-level cleaning is safe for ASCII-compatible encodings
	tool --quiet --force bad.php
	assert_bytes "$WS/work/bad.php" "c0c10a" "invalid UTF-8 + --force: BOM stripped, CRLF fixed (byte-level)"
}

t_policy_sensitive_txt_kept() {
	# Non-ASCII UTF-8 txt with BOM: Excel/Notepad/WinPS-5.1 may REQUIRE the BOM.
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/notes.txt"
	tool notes.txt
	assert_bytes "$WS/work/notes.txt" "efbbbf636166c3a90a" "sensitive txt: BOM KEPT, CRLF still fixed"
	assert_grep "$LAST_LOG" "BOM kept" "sensitive txt: keep is explained (INFO visible by default)"
}

t_policy_sensitive_force_strip() {
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/notes.txt"
	tool --quiet --force notes.txt
	assert_bytes "$WS/work/notes.txt" "636166c3a90a" "--force strips the sensitive BOM"
}

t_policy_sensitive_ascii_only_stripped() {
	# Pure-ASCII content: the BOM carries zero information — safe for everyone.
	printf '\xef\xbb\xbfplain ascii\r\n' >"$WS/work/ascii.txt"
	tool --quiet ascii.txt
	assert_bytes "$WS/work/ascii.txt" "706c61696e2061736369690a" "ascii-only txt: BOM stripped"
}

t_policy_bom_policy_flag() {
	printf '\xef\xbb\xbf<?php\r\n' >"$WS/work/p.php"
	printf '\xef\xbb\xbfplain\r\n' >"$WS/work/p.txt"
	tool --quiet --bom-policy=keep p.php p.txt
	local got1 got2
	got1="$(hex "$WS/work/p.php")"; got2="$(hex "$WS/work/p.txt")"
	[ "$got1" = "efbbbf3c3f7068700a" ] && ok "policy keep: php BOM untouched, CRLF fixed" || bad "policy keep: php" "[$got1]"
	[ "$got2" = "efbbbf706c61696e0a" ] && ok "policy keep: txt BOM untouched, CRLF fixed" || bad "policy keep: txt" "[$got2]"
	# strip policy defeats sensitivity:
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/s.txt"
	tool --quiet --bom-policy=strip s.txt
	assert_bytes "$WS/work/s.txt" "636166c3a90a" "policy strip: sensitive BOM stripped"
}

t_policy_sensitive_ext_custom() {
	# Unknown extension -> treated as sensitive by default:
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/data.dat"
	tool --quiet --ext dat data.dat
	assert_bytes "$WS/work/data.dat" "efbbbf636166c3a90a" "unknown ext: sensitive-by-default (BOM kept)"
	# --sensitive-ext '' disables sensitivity -> strip:
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/data2.dat"
	tool --quiet --ext dat --sensitive-ext '' data2.dat
	assert_bytes "$WS/work/data2.dat" "636166c3a90a" "--sensitive-ext '' : BOM stripped"
	# Custom sensitive list containing php:
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/sens.php"
	tool --quiet --sensitive-ext php sens.php
	assert_bytes "$WS/work/sens.php" "efbbbf636166c3a90a" "--sensitive-ext php: php becomes sensitive"
}

t_policy_no_bom_clear() {
	printf '\xef\xbb\xbfonlybom\n' >"$WS/work/nb.php"
	local i1; i1="$(inode "$WS/work/nb.php")"
	tool --quiet --no-bom-clear nb.php
	local i2; i2="$(inode "$WS/work/nb.php")"
	[ "$i1" = "$i2" ] && ok "--no-bom-clear: BOM-only file untouched" || bad "--no-bom-clear: BOM-only untouched" "inode changed"
	printf '\xef\xbb\xbfboth\r\n' >"$WS/work/nb2.php"
	tool --quiet --no-bom-clear nb2.php
	assert_bytes "$WS/work/nb2.php" "efbbbf626f74680a" "--no-bom-clear: CRLF fixed, BOM kept"
}

t_policy_no_rn_normalize() {
	printf 'crlf\r\nonly\r\n' >"$WS/work/nc.php"
	local i1; i1="$(inode "$WS/work/nc.php")"
	tool --quiet --no-rn-normalize nc.php
	local i2; i2="$(inode "$WS/work/nc.php")"
	[ "$i1" = "$i2" ] && ok "--no-rn-normalize: CRLF-only file untouched" || bad "--no-rn-normalize untouched" "inode changed"
	# v2/MSYS defect: with a BOM present, CRLFs were stripped ANYWAY.
	printf '\xef\xbb\xbfboth\r\n' >"$WS/work/nc2.php"
	tool --quiet --no-rn-normalize nc2.php
	assert_bytes "$WS/work/nc2.php" "626f74680d0a" "--no-rn-normalize: BOM stripped, CRLF really kept"
	# The clearer alias behaves identically:
	printf '\xef\xbb\xbfboth\r\n' >"$WS/work/nc3.php"
	tool --quiet --no-crlf-normalize nc3.php
	assert_bytes "$WS/work/nc3.php" "626f74680d0a" "--no-crlf-normalize alias works"
}

t_policy_both_disabled() {
	printf '\xef\xbb\xbfboth\r\n' >"$WS/work/x.php"
	local i1; i1="$(inode "$WS/work/x.php")"
	tool --quiet --no-bom-clear --no-rn-normalize x.php
	local i2; i2="$(inode "$WS/work/x.php")"
	[ "$i1" = "$i2" ] && ok "both disabled: nothing rewritten at all" || bad "both disabled: nothing rewritten" "inode changed"
}

#==============================================================================
# 3. Metadata & safety
#==============================================================================
t_meta_mtime_preserved() {
	printf '\xef\xbb\xbf<?php\n' >"$WS/work/m.php"
	touch -d '2020-01-01 00:00:00' "$WS/work/m.php" 2>/dev/null || touch -t 2001010000 "$WS/work/m.php"
	local m1; m1="$(mtime "$WS/work/m.php")"
	tool --quiet m.php
	local m2; m2="$(mtime "$WS/work/m.php")"
	[ "$m1" = "$m2" ] && ok "mtime preserved on modified file (v2 bug fixed)" || bad "mtime preserved" "$m1 -> $m2"
	# --update-mtime opts out:
	printf '\xef\xbb\xbf<?php\n' >"$WS/work/m2.php"
	touch -d '2020-01-01 00:00:00' "$WS/work/m2.php" 2>/dev/null || touch -t 2001010000 "$WS/work/m2.php"
	sleep 1
	tool --quiet --update-mtime m2.php
	local m3; m3="$(mtime "$WS/work/m2.php")"
	[ "$m3" != "1577836800" ] && ok "--update-mtime refreshes mtime" || bad "--update-mtime" "mtime unchanged"
}

t_meta_permissions_preserved() {
	# The MSYS permission map has no group bit: `chmod 640` produces 644, so an
	# assertion on the literal 640 tests the host, not the tool. The invariant
	# that matters is that cleaning MUTATES the mode by nothing at all, so the
	# mode is captured before and compared after; chmod 604 is used because it
	# is representable in every map (POSIX and MSYS alike) and is not a no-op.
	printf '\xef\xbb\xbf<?php\n' >"$WS/work/perm.php"
	chmod 604 "$WS/work/perm.php"
	local before after
	before="$(stat -c %a "$WS/work/perm.php" 2>/dev/null || stat -f %Lp "$WS/work/perm.php")"
	tool --quiet perm.php
	after="$(stat -c %a "$WS/work/perm.php" 2>/dev/null || stat -f %Lp "$WS/work/perm.php")"
	[ "$after" = "$before" ] && ok "permissions preserved ($before)" || bad "permissions preserved" "$before -> $after"
	if [ "$HAVE_POSIX_PERMS" -eq 1 ]; then
		printf '\xef\xbb\xbf<?php\n' >"$WS/work/perm2.php"
		chmod 755 "$WS/work/perm2.php"
		tool --quiet perm2.php
		local mode; mode="$(stat -c %a "$WS/work/perm2.php" 2>/dev/null || stat -f %Lp "$WS/work/perm2.php")"
		[ "$mode" = "755" ] && ok "permissions preserved (755 exec bit)" || bad "permissions preserved 755" "mode=$mode"
	else
		ok "permissions preserved 755: SKIPPED (this host's permission map has no exec bit for files)"
	fi
}

t_meta_hardlink_inplace() {
	printf '\xef\xbb\xbfhard\r\n' >"$WS/work/hl.php"
	ln "$WS/work/hl.php" "$WS/work/hl_link.php" 2>/dev/null
	if [ "$(inode "$WS/work/hl.php")" != "$(inode "$WS/work/hl_link.php")" ]; then
		ok "hardlink: SKIPPED (this host did not create a hard link)"; return 0
	fi
	local i1; i1="$(inode "$WS/work/hl.php")"
	tool --quiet hl.php
	local i2; i2="$(inode "$WS/work/hl.php")"
	[ "$i1" = "$i2" ] && ok "hardlink: inode preserved (in-place rewrite)" || bad "hardlink inode" "$i1 -> $i2"
	local got; got="$(hex "$WS/work/hl_link.php")"
	[ "$got" = "686172640a" ] && ok "hardlink: second link sees the cleaned content" || bad "hardlink content" "[$got]"
	assert_grep "$LAST_LOG" "hard links" "hardlink: warning logged"
}

t_meta_symlink_argument() {
	# On MSYS `ln -s` copies the file instead of linking it, so the fixture
	# would never be a symlink and the test would assert a property the host
	# cannot produce. linux and macOS run the full check.
	if [ "$HAVE_SYMLINK" -eq 0 ]; then
		ok "symlink arg: SKIPPED (this host does not create real symlinks)"; return 0
	fi
	printf '\xef\xbb\xbfreal\r\n' >"$WS/work/real.php"
	ln -s real.php "$WS/work/link.php"
	tool --quiet link.php
	assert_bytes "$WS/work/real.php" "7265616c0a" "symlink arg: target cleaned"
	if [ -L "$WS/work/link.php" ]; then
		ok "symlink arg: link itself intact (not replaced by a regular file)"
	else
		bad "symlink arg: link intact" "link was destroyed"
	fi
}

t_meta_backup() {
	printf '\xef\xbb\xbfold\r\n' >"$WS/work/bk.php"
	tool --quiet --backup bk.php
	local bak
	bak="$(echo "$WS/work/"bk.php.bak.* 2>/dev/null | tr ' ' '\n' | head -1)"
	assert_file "$bak" "--backup: backup file created"
	if [ -f "$bak" ]; then
		assert_bytes "$bak" "efbbbf6f6c640d0a" "--backup: original bytes kept in backup"
	fi
	printf '\xef\xbb\xbfold2\r\n' >"$WS/work/bk2.php"
	mkdir -p "$WS/baks"
	tool --quiet --backup-dir "$WS/baks" bk2.php
	assert_file "$WS/baks/bk2.php" "--backup-dir: copy created"
	assert_bytes "$WS/baks/bk2.php" "efbbbf6f6c64320d0a" "--backup-dir: original bytes"
}

t_meta_no_leftovers() {
	printf '\xef\xbb\xbfleak\r\n' >"$WS/work/l.php"
	tool --quiet l.php
	local n
	n="$(find "$WS/work" -name '.cleanbom.*' -o -name '*.bak.*' | wc -l | tr -d '[:space:]')"
	[ "$n" = "0" ] && ok "no temp/backup leftovers after a normal run" || bad "no leftovers" "found $n"
}

t_meta_idempotent() {
	mk_bom_crlf_php
	tool --quiet a.php
	local i1; i1="$(inode "$WS/work/a.php")"
	tool a.php
	local i2; i2="$(inode "$WS/work/a.php")"
	[ "$i1" = "$i2" ] && ok "idempotent: second run does not rewrite" || bad "idempotent" "inode changed on 2nd run"
	assert_grep "$LAST_LOG" "Files processed: 0" "idempotent: summary reports 0 processed"
	assert_grep "$LAST_LOG" "Files skipped (clean): 1" "idempotent: second run reports the file clean"
}

#==============================================================================
# 4. Modes: dry-run / check / json / strict / quiet
#==============================================================================
t_mode_dry_run() {
	mk_bom_crlf_php
	local i1; i1="$(inode "$WS/work/a.php")"
	tool --dry-run a.php
	assert_rc $? 0 "dry-run: exit 0"
	local i2; i2="$(inode "$WS/work/a.php")"
	[ "$i1" = "$i2" ] && ok "dry-run: file not modified" || bad "dry-run: file not modified" "inode changed"
	assert_bytes "$WS/work/a.php" "efbbbf3c3f7068700d0a6563686f20313b0d0a" "dry-run: bytes intact"
	assert_grep "$LAST_LOG" "Would process" "dry-run: reports what would happen"
}

t_mode_check() {
	mk_bom_crlf_php
	tool --check a.php
	assert_rc $? 10 "--check: exit 10 when dirty"
	assert_bytes "$WS/work/a.php" "efbbbf3c3f7068700d0a6563686f20313b0d0a" "--check: file NOT modified"
	tool --quiet a.php
	tool --check a.php
	assert_rc $? 0 "--check: exit 0 when clean"
}

t_mode_json() {
	printf '\xef\xbb\xbf<?php\r\n' >"$WS/work/j1.php"
	printf '\xff\xfez\x00\r\n' >"$WS/work/j2.txt"
	printf '\xef\xbb\xbfcaf\xc3\xa9\n' >"$WS/work/j3.txt"
	printf 'clean\n' >"$WS/work/j4.css"
	tool --json --check .
	local rc=$?
	assert_rc "$rc" 10 "--json --check: exit 10"
	if [ "$HAVE_NODE" -eq 1 ]; then
		if node -e '
			const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
			const s = j.summary;
			const byPath = Object.fromEntries(j.files.map(f => [f.path, f]));
			const want = (c, v) => { if (s[c] !== v) { console.error(`summary.${c}=${s[c]} want ${v}`); process.exit(1); } };
			want("wouldChange", 1); want("clean", 1); want("bomKept", 1); want("protectedUtf16or32", 1);
			const wf = Object.values(byPath).find(f => f.status === "would-change");
			if (!wf || !wf.actions.includes("strip-bom") || !wf.actions.includes("crlf-to-lf")) { console.error("would-change entry wrong"); process.exit(1); }
			const kept = Object.values(byPath).find(f => f.status === "kept");
			if (!kept || kept.bomKept !== true || kept.reason !== "bom-may-be-required") { console.error("kept entry wrong"); process.exit(1); }
			const prot = Object.values(byPath).find(f => f.status === "protected");
			if (!prot || prot.reason !== "bom-required-utf16le") { console.error("protected entry wrong"); process.exit(1); }
		' "$WS/stdout.log" 2>"$WS/jsonerr.log"; then
			ok "--json: valid JSON with correct schema and counters"
		else
			bad "--json schema" "$(cat "$WS/jsonerr.log")"
		fi
	else
		assert_grep "$WS/stdout.log" '"tool": "clean-bom-senior"' "--json: structure present (node unavailable)"
	fi
	assert_not_grep "$WS/stdout.log" "INFO" "--json: stdout is pure JSON (logs on stderr)"
}

t_mode_strict() {
	printf '\xef\xbb\xbfcaf\xc3\xa9\r\n' >"$WS/work/st.txt"
	tool --check --strict st.txt
	assert_rc $? 1 "--strict: kept BOM makes --check fail with 1"
	printf '\xef\xbb\xbfok\r\n' >"$WS/work/st2.php"
	tool --check --strict st2.php
	assert_rc $? 10 "--strict: ordinary dirty file still exits 10"
}

t_mode_quiet_silent() {
	mk_bom_crlf_php
	tool --quiet a.php
	assert_not_grep "$LAST_LOG" "PROCESSING SUMMARY" "--quiet: no summary"
	mk_bom_crlf_php
	tool --silent a.php
	local n; n="$(wc -l <"$LAST_LOG" | tr -d '[:space:]')"
	[ "$n" = "0" ] && ok "--silent: stderr completely empty on success" || bad "--silent empty" "$n lines"
}

t_mode_log_file() {
	mk_bom_crlf_php
	tool -v --log-file "$WS/run.log" a.php
	assert_file "$WS/run.log" "--log-file: created"
	assert_grep "$WS/run.log" "Successfully processed" "--log-file: contains processing records"
	assert_not_grep "$WS/run.log" "$(printf '\033')" "--log-file: no ANSI escapes"
}

#==============================================================================
# 5. Selection: directories, extensions, exclusions, size, git
#==============================================================================
t_select_directory_arg() {
	mkdir -p "$WS/work/src/deep"
	printf '\xef\xbb\xbf<?php\r\n' >"$WS/work/src/a.php"
	printf '\xef\xbb\xbf<?php\r\n' >"$WS/work/src/deep/b.php"
	printf '\xef\xbb\xbfvar x\r\n' >"$WS/work/outside.js"
	tool --quiet src
	assert_bytes "$WS/work/src/a.php" "3c3f7068700a" "directory arg: file cleaned"
	assert_bytes "$WS/work/src/deep/b.php" "3c3f7068700a" "directory arg: nested file cleaned"
	assert_bytes "$WS/work/outside.js" "efbbbf76617220780d0a" "directory arg: files outside untouched"
}

t_select_recursive_default() {
	mkdir -p "$WS/work/sub"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/sub/s.css"
	tool --quiet
	assert_bytes "$WS/work/sub/s.css" "780a" "no args: recursive scan from CWD"
}

t_select_ext_flags() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/e.php"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/e.md"
	tool --quiet --ext md .
	assert_bytes "$WS/work/e.php" "efbbbf780d0a" "--ext: replaces the default set (php untouched)"
	assert_bytes "$WS/work/e.md" "780a" "--ext: md processed"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/e2.md"
	tool --quiet --add-ext md .
	assert_bytes "$WS/work/e2.md" "780a" "--add-ext: extends the default set"
	assert_bytes "$WS/work/e.php" "780a" "--add-ext: defaults still processed"
}

t_select_exclusions() {
	mkdir -p "$WS/work/node_modules/pkg" "$WS/work/.git" "$WS/work/vendor" "$WS/work/dist"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/node_modules/pkg/i.js"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/.git/g.php"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/vendor/v.php"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/dist/d.js"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/ok.php"
	tool --quiet --exclude 'dist/*'
	assert_bytes "$WS/work/node_modules/pkg/i.js" "efbbbf780d0a" "default exclusion: node_modules untouched"
	assert_bytes "$WS/work/.git/g.php" "efbbbf780d0a" "default exclusion: .git untouched"
	assert_bytes "$WS/work/vendor/v.php" "780a" "vendor IS processed by default (first-party deploys)"
	assert_bytes "$WS/work/dist/d.js" "efbbbf780d0a" "--exclude glob: dist untouched"
	assert_bytes "$WS/work/ok.php" "780a" "normal file cleaned"
	tool --quiet --no-default-excludes
	assert_bytes "$WS/work/node_modules/pkg/i.js" "780a" "--no-default-excludes: node_modules processed"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/node_modules/pkg/i2.js"
	tool --quiet --exclude-dir node_modules --no-default-excludes
	assert_bytes "$WS/work/node_modules/pkg/i2.js" "efbbbf780d0a" "--exclude-dir survives --no-default-excludes"
}

t_select_max_size() {
	printf '\xef\xbb\xbf' >"$WS/work/big.php"
	dd if=/dev/zero bs=1024 count=20 2>/dev/null | tr '\0' 'x' >>"$WS/work/big.php"
	printf '\r\n' >>"$WS/work/big.php"
	tool --max-size 10K big.php
	assert_rc $? 0 "--max-size: exit 0"
	assert_grep "$LAST_LOG" "oversize" "--max-size: skip is reported (INFO)"
	local got; got="$(hex "$WS/work/big.php" | head -c 12)"
	[ "$got" = "efbbbf787878" ] && ok "--max-size: oversized file untouched" || bad "--max-size untouched" "[$got]"
	tool --quiet --max-size 100K big.php
	got="$(hex "$WS/work/big.php" | head -c 6)"
	[ "$got" = "787878" ] && ok "--max-size 100K: same file now cleaned" || bad "--max-size 100K cleaned" "[$got]"
	tool --quiet --max-size bogus big.php >/dev/null 2>&1
	assert_rc $? 2 "--max-size bogus: exit 2"
}

t_select_git_mode() {
	if [ "$HAVE_GIT" -eq 0 ]; then
		ok "--git: SKIPPED (git not available)"
		return 0
	fi
	(
		cd "$WS/work" || exit 1
		git init -q . 2>/dev/null
		git config user.email t@t.t; git config user.name t
		printf '\xef\xbb\xbftracked\r\n' >tracked.php
		printf '\xef\xbb\xbfuntracked\r\n' >untracked.php
		git add tracked.php >/dev/null 2>&1
		git -c commit.gpgsign=false commit -qm init >/dev/null 2>&1
	)
	tool --quiet --git
	assert_bytes "$WS/work/tracked.php" "747261636b65640a" "--git: tracked file cleaned"
	assert_bytes "$WS/work/untracked.php" "efbbbf756e747261636b65640d0a" "--git: untracked file untouched"
}

#==============================================================================
# 6. CLI contract, help, version, misc
#==============================================================================
t_cli_unknown_option() {
	tool --bogus-option
	assert_rc $? 2 "unknown long option: exit 2"
	assert_grep "$LAST_LOG" "Unknown option: --bogus-option" "unknown option: message"
	tool -
	assert_rc $? 2 "bare '-': exit 2 (v2 contract)"
	assert_grep "$LAST_LOG" "Unknown option: -$" "bare '-': message 'Unknown option: -'"
}

t_cli_double_dash() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/-weird-.php"
	tool --quiet -- "-weird-.php"
	assert_rc $? 0 "'--' terminator: exit 0"
	assert_bytes "$WS/work/-weird-.php" "780a" "'--' terminator: dash-prefixed filename processed"
}

t_cli_missing_file() {
	tool --quiet nope.php
	assert_rc $? 1 "missing file argument: exit 1 (v2 gave 0 — fixed)"
	assert_grep "$LAST_LOG" "File not found: nope.php" "missing file: message"
}

t_cli_mixed_success_failure() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/good.php"
	tool --quiet good.php missing.php
	assert_rc $? 1 "one good + one missing: exit 1"
	assert_bytes "$WS/work/good.php" "780a" "good file still processed"
}

t_cli_interspersed_options() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/i.php"
	# v3: options may follow positional paths (v2 stopped parsing at the first path)
	tool --quiet i.php --dry-run
	assert_rc $? 0 "interspersed: exit 0"
	assert_bytes "$WS/work/i.php" "efbbbf780d0a" "interspersed: --dry-run after path honored"
}

t_cli_help_version() {
	tool --help
	assert_rc $? 0 "--help: exit 0"
	assert_grep "$WS/stdout.log" "USAGE" "--help: contains USAGE"
	assert_grep "$WS/stdout.log" "SMART BOM POLICY" "--help: contains the Smart BOM Policy section"
	assert_grep "$WS/stdout.log" "EXIT CODES" "--help: contains EXIT CODES"
	tool --help bom-policy
	assert_rc $? 0 "--help bom-policy: exit 0"
	assert_grep "$WS/stdout.log" "DECISION TABLE" "--help bom-policy: decision table"
	tool --help nosuchtopic
	assert_rc $? 2 "--help nosuchtopic: exit 2"
	tool -h
	assert_rc $? 0 "-h: exit 0 (full help, v2 parity)"
	tool --version
	assert_rc $? 0 "--version: exit 0"
	assert_grep "$WS/stdout.log" "version 3.0.0" "--version: prints version"
	tool --completion
	assert_rc $? 0 "--completion: exit 0"
	assert_grep "$WS/stdout.log" "complete -F _clean_bom_senior" "--completion: valid bash completion"
}

t_cli_env_opts() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/env.php"
	CLEAN_BOM_OPTS="--dry-run" tool env.php
	assert_bytes "$WS/work/env.php" "efbbbf780d0a" "CLEAN_BOM_OPTS=--dry-run honored"
}

t_cli_color_modes() {
	mk_bom_crlf_php
	tool --color=always a.php 2>&1 || true
	assert_grep "$LAST_LOG" "$(printf '\033')" "--color=always: ANSI emitted even when piped"
	mk_bom_crlf_php
	tool --color=never a.php
	assert_not_grep "$LAST_LOG" "$(printf '\033')" "--color=never: no ANSI"
	mk_bom_crlf_php
	NO_COLOR=1 tool --color=always a.php
	assert_grep "$LAST_LOG" "$(printf '\033')" "--color=always beats NO_COLOR (explicit CLI wins)"
}

t_cli_summary_counts() {
	printf '\xef\xbb\xbfa\r\n' >"$WS/work/s1.php"   # changed
	printf 'clean\n' >"$WS/work/s2.php"               # clean
	printf '\xff\xfex\x00\r\n' >"$WS/work/s3.txt"     # protected utf16 (has ASCII CRLF inside)
	printf '\xef\xbb\xbfcaf\xc3\xa9\n' >"$WS/work/s4.txt" # kept
	tool .
	assert_grep "$LAST_LOG" "Files scanned: 4" "summary: scanned=4"
	assert_grep "$LAST_LOG" "Files processed: 1" "summary: processed=1"
	assert_grep "$LAST_LOG" "Files skipped (clean): 1" "summary: clean=1"
	assert_grep "$LAST_LOG" "BOM signatures removed: 1" "summary: bom removed=1"
	assert_grep "$LAST_LOG" "UTF-8 BOM kept (may be required): 1" "summary: kept=1"
	assert_grep "$LAST_LOG" "UTF-16/UTF-32 files (BOM required): 1" "summary: protected utf16=1"
}

t_cli_special_filenames() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/with space.php"
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/quote'file.php"
	tool --quiet "with space.php" "quote'file.php"
	assert_rc $? 0 "special filenames: exit 0"
	assert_bytes "$WS/work/with space.php" "780a" "filename with space processed"
	assert_bytes "$WS/work/quote'file.php" "780a" "filename with quote processed"
}

t_cli_json_escapes() {
	printf '\xef\xbb\xbfx\r\n' >"$WS/work/we\"ird.php" 2>/dev/null
	if [ ! -f "$WS/work/we\"ird.php" ]; then
		# Windows forbids a double quote in a file name, so MSYS cannot create
		# this fixture and the assertion would pass vacuously (empty tree).
		ok "json escaping: SKIPPED (this host cannot create a filename with a double quote)"; return 0
	fi
	tool --json --check . >/dev/null 2>&1 || true
	if [ "$HAVE_NODE" -eq 1 ]; then
		if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$WS/stdout.log" 2>/dev/null; then
			ok "json: filename with a double quote is escaped correctly"
		else
			bad "json escaping" "stdout was not valid JSON"
		fi
	else
		ok "json escaping: SKIPPED (no node)"
	fi
}

t_cli_self_test() {
	# The tool ships its own portable acceptance suite — run it.
	local rc=0
	( cd "$WS/work" && bash "$TOOL" --self-test ) >"$WS/st.log" 2>&1 || rc=$?
	assert_rc "$rc" 0 "--self-test: passes on this machine"
	assert_grep "$WS/st.log" "self-test: .* passed, 0 failed" "--self-test: all green"
}

#==============================================================================
# 7. Auto-update (against a local file:// "repository")
#==============================================================================
# The only URL form the curl build present on this host understands. MSYS curl
# is a ucrt64 binary: `file:///tmp/x` (a POSIX path) returns an empty body, while
# `file://C:/.../x` works. Reproduced before the change: the same fixture read
# through both forms. When curl cannot read its own file:// URL at all, the
# update tests are reported as SKIPPED rather than as failures of the tool.
file_url() { # $1 = a path as the shell sees it
	if command -v cygpath >/dev/null 2>&1; then
		printf 'file://%s' "$(cygpath -m -- "$1")"
	else
		printf 'file://%s' "$1"
	fi
}

make_fake_repo() { # $1 = version to publish, $2 = repo dir, $3 = script source version
	mkdir -p "$2"
	printf '%s\n' "$1" >"$2/VERSION"
	sed "s/^VERSION=\"[0-9.]*\"/VERSION=\"$1\"/" "$TOOL" >"$2/clean-bom-senior.sh"
	# For the tamper test the caller overwrites the script afterwards.
}

t_update_check_newer() {
	if [ "$HAVE_CURL" -eq 0 ]; then
		ok "update: SKIPPED (curl not available)"; return 0
	fi
	if [ "$HAVE_FILE_URL" -eq 0 ]; then
		ok "update: SKIPPED (this curl cannot read a local file:// URL)"; return 0
	fi
	make_fake_repo "9.9.9" "$WS/fakerepo"
	cp "$TOOL" "$WS/work/installed.sh"
	local rc=0
	( cd "$WS/work" && CLEAN_BOM_UPDATE_URL="$(file_url "$WS/fakerepo")" bash installed.sh --check-update ) >"$WS/out.log" 2>"$LAST_LOG" || rc=$?
	assert_rc "$rc" 11 "--check-update: exit 11 when a newer version exists"
	assert_grep "$LAST_LOG" "Update available: 3.0.0 -> 9.9.9" "--check-update: announces versions"
}

t_update_check_current() {
	if [ "$HAVE_CURL" -eq 0 ]; then
		ok "update: SKIPPED (curl not available)"; return 0
	fi
	if [ "$HAVE_FILE_URL" -eq 0 ]; then
		ok "update: SKIPPED (this curl cannot read a local file:// URL)"; return 0
	fi
	make_fake_repo "3.0.0" "$WS/fakerepo"
	cp "$TOOL" "$WS/work/installed.sh"
	local rc=0
	( cd "$WS/work" && CLEAN_BOM_UPDATE_URL="$(file_url "$WS/fakerepo")" bash installed.sh --check-update ) >"$WS/out.log" 2>"$LAST_LOG" || rc=$?
	assert_rc "$rc" 0 "--check-update: exit 0 when up to date"
}

t_update_apply() {
	if [ "$HAVE_CURL" -eq 0 ]; then
		ok "update: SKIPPED (curl not available)"; return 0
	fi
	if [ "$HAVE_FILE_URL" -eq 0 ]; then
		ok "update: SKIPPED (this curl cannot read a local file:// URL)"; return 0
	fi
	make_fake_repo "9.9.9" "$WS/fakerepo"
	cp "$TOOL" "$WS/work/installed.sh"
	chmod 755 "$WS/work/installed.sh"
	local rc=0
	( cd "$WS/work" && CLEAN_BOM_UPDATE_URL="$(file_url "$WS/fakerepo")" ./installed.sh --update ) >"$WS/out.log" 2>"$LAST_LOG" || rc=$?
	assert_rc "$rc" 0 "--update: exit 0"
	local v
	v="$(bash "$WS/work/installed.sh" --version | head -1)"
	case "$v" in
		*"9.9.9"*) ok "--update: script replaced with the new version" ;;
		*) bad "--update: version after update" "[$v]" ;;
	esac
	[ -x "$WS/work/installed.sh" ] && ok "--update: exec bit preserved" || bad "--update: exec bit" "not executable"
}

t_update_verify_rejects_tampered() {
	if [ "$HAVE_CURL" -eq 0 ]; then
		ok "update: SKIPPED (curl not available)"; return 0
	fi
	if [ "$HAVE_FILE_URL" -eq 0 ]; then
		ok "update: SKIPPED (this curl cannot read a local file:// URL)"; return 0
	fi
	make_fake_repo "9.9.8" "$WS/fakerepo"
	# The published script claims a DIFFERENT version internally -> must refuse.
	cp "$TOOL" "$WS/fakerepo/clean-bom-senior.sh"
	cp "$TOOL" "$WS/work/installed.sh"
	local rc=0 before after
	before="$(hex "$WS/work/installed.sh")"
	( cd "$WS/work" && CLEAN_BOM_UPDATE_URL="$(file_url "$WS/fakerepo")" ./installed.sh --update ) >"$WS/out.log" 2>"$LAST_LOG" || rc=$?
	assert_rc "$rc" 3 "--update: verification failure exits 3"
	assert_grep "$LAST_LOG" "refusing to install" "--update: refusal explained"
	after="$(hex "$WS/work/installed.sh")"
	[ "$before" = "$after" ] && ok "--update: failed update leaves the script byte-identical" || bad "--update: script unchanged on failure" "bytes differ"
}

#==============================================================================
# 8. Version consistency across the repository artifacts
#==============================================================================
t_repo_version_consistency() {
	local sh_ver pkg_ver version_file node_ver
	sh_ver="$(sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$TOOL" | head -1)"
	if [ -f "$REPO_ROOT/VERSION" ]; then
		version_file="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
		[ "$version_file" = "$sh_ver" ] && ok "VERSION file matches the shell reference ($sh_ver)" || bad "VERSION file" "[$version_file] != [$sh_ver]"
	fi
	if [ -f "$REPO_ROOT/package.json" ] && [ "$HAVE_NODE" -eq 1 ]; then
		# Local: without `local` this leaks into the next test's scope.
		local pkg_ver pkg_json
		# `node` is a Windows binary under Git Bash and cannot resolve an MSYS
		# path (/c/...), which made this assertion report an empty version. Ask
		# cygpath for the native form where it exists; elsewhere the path is
		# already what node expects.
		pkg_json="$REPO_ROOT/package.json"
		if command -v cygpath >/dev/null 2>&1; then
			pkg_json="$(cygpath -m -- "$REPO_ROOT")/package.json"
		fi
		pkg_ver="$(node -p "require('$pkg_json').version" 2>/dev/null)"
		[ "$pkg_ver" = "$sh_ver" ] && ok "package.json version matches ($pkg_ver)" || bad "package.json version" "[$pkg_ver] != [$sh_ver]"
	fi
	if [ -f "$REPO_ROOT/bin/bom.js" ]; then
		node_ver="$(sed -n "s/^const VERSION = '\([0-9.]*\)'.*/\1/p" "$REPO_ROOT/bin/bom.js" | head -1)"
		if [ -n "$node_ver" ]; then
			[ "$node_ver" = "$sh_ver" ] && ok "bin/bom.js version matches ($node_ver)" || bad "bin/bom.js version" "[$node_ver] != [$sh_ver]"
		fi
	fi
}

#==============================================================================
# Runner
#==============================================================================
TESTS="
t_core_bom_crlf
t_core_bom_only
t_core_crlf_only
t_core_clean_untouched
t_core_empty_file
t_core_bom_only_3bytes
t_core_no_trailing_newline
t_core_late_crlf_regression
t_core_hex_false_positive_regression
t_core_uppercase_ext
t_core_crlf_at_eof_and_lone_cr
t_core_cr_run_before_lf
t_policy_utf16le_protected
t_policy_utf16be_utf32_protected
t_policy_utf16_crlf_detection_regression
t_policy_binary_nul_protected
t_policy_invalid_utf8_protected
t_policy_sensitive_txt_kept
t_policy_sensitive_force_strip
t_policy_sensitive_ascii_only_stripped
t_policy_bom_policy_flag
t_policy_sensitive_ext_custom
t_policy_no_bom_clear
t_policy_no_rn_normalize
t_policy_both_disabled
t_meta_mtime_preserved
t_meta_permissions_preserved
t_meta_hardlink_inplace
t_meta_symlink_argument
t_meta_backup
t_meta_no_leftovers
t_meta_idempotent
t_mode_dry_run
t_mode_check
t_mode_json
t_mode_strict
t_mode_quiet_silent
t_mode_log_file
t_select_directory_arg
t_select_recursive_default
t_select_ext_flags
t_select_exclusions
t_select_max_size
t_select_git_mode
t_cli_unknown_option
t_cli_double_dash
t_cli_missing_file
t_cli_mixed_success_failure
t_cli_interspersed_options
t_cli_help_version
t_cli_env_opts
t_cli_color_modes
t_cli_summary_counts
t_cli_special_filenames
t_cli_json_escapes
t_cli_self_test
t_update_check_newer
t_update_check_current
t_update_apply
t_update_verify_rejects_tampered
t_repo_version_consistency
"

echo "Clean BOM Senior v3 — shell test suite"
echo "tool: $TOOL"
echo "node: $HAVE_NODE  git: $HAVE_GIT  curl: $HAVE_CURL  root: $IS_ROOT"
[ -n "$FILTER" ] && echo "filter: $FILTER"

for t in $TESTS; do
	run_test "$t" "$t"
done

finish
