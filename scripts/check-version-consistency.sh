#!/usr/bin/env bash
#===============================================================================
# check-version-consistency.sh — single-source-of-truth guard for releases.
#
# The v3 family must agree on one version:
#   VERSION, clean-bom-senior.sh, bin/bom.js, clean-bom-senior.ps1,
#   package.json, CHANGELOG.md
# The cmd.exe port is pinned deliberately and is checked against its own frozen
# contract version:
#   clean-bom-senior.bat  → 2.07.0
#
# Exit: 0 = consistent, 1 = mismatch.
#===============================================================================
# shellcheck disable=SC2015  # `[ x ] && note || err` is safe: note/err always succeed
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { printf '%s\n' "$*"; }
err()  { printf 'MISMATCH: %s\n' "$*" >&2; fail=1; }

# --- v3 family ---------------------------------------------------------------
EXPECTED="$(tr -d '[:space:]' < VERSION)"
note "VERSION file:            $EXPECTED"

SH_VER="$(sed -n 's/^VERSION="\([0-9][0-9.]*\)".*/\1/p' clean-bom-senior.sh | head -1)"
[ "$SH_VER" = "$EXPECTED" ] && note "clean-bom-senior.sh:     $SH_VER" || err "clean-bom-senior.sh has [$SH_VER], expected [$EXPECTED]"

JS_VER="$(sed -n "s/^const VERSION = '\([0-9][0-9.]*\)'.*/\1/p" bin/bom.js | head -1)"
[ "$JS_VER" = "$EXPECTED" ] && note "bin/bom.js:              $JS_VER" || err "bin/bom.js has [$JS_VER], expected [$EXPECTED]"

PKG_VER="$(sed -n 's/.*"version": *"\([0-9][0-9.]*\)".*/\1/p' package.json | head -1)"
[ "$PKG_VER" = "$EXPECTED" ] && note "package.json:            $PKG_VER" || err "package.json has [$PKG_VER], expected [$EXPECTED]"

# The PowerShell port declares its stamp with a trailing semicolon, mirroring
# bin/bom.js, so all three v3 implementations are checked the same way.
if [ -f clean-bom-senior.ps1 ]; then
	PS_VER="$(sed -n "s/^\\\$script:VERSION = '\([0-9][0-9.]*\)';.*/\1/p" clean-bom-senior.ps1 | head -1)"
	[ "$PS_VER" = "$EXPECTED" ] && note "clean-bom-senior.ps1:    $PS_VER" || err "clean-bom-senior.ps1 has [$PS_VER], expected [$EXPECTED]"
fi

if [ -f CHANGELOG.md ]; then
	CL_VER="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
	[ "$CL_VER" = "$EXPECTED" ] && note "CHANGELOG.md (top):      $CL_VER" || err "CHANGELOG.md top entry is [$CL_VER], expected [$EXPECTED]"
fi

# --- legacy family (frozen at the v2.07 contract) -----------------------------
LEGACY_EXPECTED="2.07.0"

if command -v grep >/dev/null; then
	BAT_VER="$(grep -oE 'set "VERSION=[0-9][0-9.]*"' clean-bom-senior.bat | head -1 | sed 's/set "VERSION=//; s/"//' || true)"
	if [ -n "${BAT_VER:-}" ]; then
		[ "$BAT_VER" = "$LEGACY_EXPECTED" ] && note "clean-bom-senior.bat:    $BAT_VER (legacy, pinned)" || err "clean-bom-senior.bat has [$BAT_VER], legacy pin is [$LEGACY_EXPECTED]"
	fi
fi

if [ "$fail" -eq 0 ]; then
	note "OK: all versions consistent."
	exit 0
fi
exit 1
