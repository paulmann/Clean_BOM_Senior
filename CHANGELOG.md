# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] — 2026-10-08

Major release: a full refactor of the reference implementation, a new native
Node.js CLI, the Smart BOM Policy, auto-update, and production infrastructure.
The PowerShell port was carried to the full v3 contract; the cmd.exe port
remains **frozen as legacy** at v2.07 (see *Compatibility*).

### Added — Smart BOM Policy (the headline feature)

Before removing anything, the tool now proves that removal is safe. Every
decision is logged with a reason and exposed in `--json`:

- **UTF-16/UTF-32 files are never touched.** Their BOM (`FF FE`, `FE FF`,
  `FF FE 00 00`, `00 00 FE FF`) is structurally required: stripping it
  corrupts the file. v2 would rewrite such a file whenever its hex-window
  CRLF probe happened to match.
- **Binary files (NUL bytes anywhere) are never touched.** v2 had no binary
  detection at all and rewrote NUL-containing files (measured: a BOM+NUL+CRLF
  `.txt` lost 4 bytes).
- **Invalid UTF-8 is protected by default** (the file is not what its BOM or
  extension claims); `--force` enables safe byte-level cleaning.
- **"May-be-required" BOMs are kept**: for sensitive extensions (default
  `txt csv tsv ps1 psm1 psd1`, plus unknown extensions) with non-ASCII
  content, the UTF-8 BOM is preserved because Excel, legacy Notepad and
  Windows PowerShell 5.1 misread such files without it. CRLF in the same file
  is still normalised. `--force` / `--bom-policy=strip` override.
- Pure-ASCII files lose the BOM unconditionally (it carries zero information).
- New flags: `--bom-policy auto|strip|keep`, `--sensitive-ext LIST`, `--force`.

### Added — CLI

- `-c/--check` — CI gate: exit **10** when anything needs cleaning, no writes.
- `-j/--json` — machine-readable report on stdout (documented schema); stdout
  is now reserved for machine output, the log stays on stderr.
- **Directory arguments** (`tool src dist` — v2 answered "File not found").
- `--ext` / `--add-ext`, `--exclude GLOB`, `--exclude-dir NAME`,
  `--no-default-excludes`, `--max-size 512K|10M|1G|bytes`, `--git`
  (git-tracked files only).
- **Default exclusions**: `.git`, `.svn`, `.hg`, `node_modules` are no longer
  scanned (v2 happily rewrote your dependencies).
- `--update` / `--check-update` (exit **11**) — self-update from the
  repository with content verification; `CLEAN_BOM_UPDATE_URL` for mirrors;
  npm-managed installs are detected and refused with the right command.
- `--help TOPIC` — comprehensive built-in help: `usage`, `options`,
  `bom-policy`, `safety`, `exit-codes`, `examples`, `env`, `ci`, `update`,
  `files`, `json`, `compatibility`.
- `--quiet` / `--silent`, `--color auto|always|never` (+ `NO_COLOR`,
  `CLICOLOR_FORCE`), `--log-file FILE`, `--strict`, `--backup`,
  `--backup-dir DIR`, `--update-mtime` / `--no-keep-mtime`,
  `--no-crlf-normalize` (clear alias of `--no-rn-normalize`), `-f/--fix`.
- `--self-test` — built-in acceptance suite (10 fixtures) proving the
  installation works on the host machine.
- `--completion` — bash completion script.
- `CLEAN_BOM_OPTS` environment variable for CI-wide defaults.
- GNU-style interspersed options (`tool src --check`); `--` still ends
  parsing. All v2 flags keep working.

### Added — implementations & infrastructure

- **`bin/bom.js` is now a full native Node.js implementation** (was a
  `bash` wrapper). The npm package works on **Windows, macOS and Linux**
  without Git Bash; `package.json` no longer restricts `os`, engines
  `>=18`. Behaviour is byte-for-byte identical to the shell reference —
  proven by a differential test in the Node suite.
- **`clean-bom-senior.ps1` is now a full v3 implementation** (was a v2.07
  port). PowerShell 7.6+ on Windows, Linux and macOS, pure .NET byte I/O —
  **no external tool is required for cleaning**. Same analysis pipeline,
  same decision table, same log lines, same JSON schema, same exit codes;
  `docs/PS-PORT.md` documents the structure, the six deliberate divergences
  and every trap hit while writing it. Measured on a 6 MB LF-only PHP file:
  sh 1.7 s, ps1 0.7 s.
- **The PowerShell help text is generated, not copied.**
  `scripts/gen-ps-help.py` derives all twelve topics from the reference's
  here-docs and `--check` fails CI on drift. Hand-copying documentation
  between implementations is how they diverge.
- Test suites, all framework-free: `tests/sh/run-tests.sh` (164 assertions),
  `tests/node/run-tests.mjs` (161) and `tests/ps/run-tests.ps1` (238, 64
  groups).
- Two differential harnesses pin the implementations to each other:
  `node tests/node/run-tests.mjs differential` (sh↔node, 8 fixtures) and
  `tests/ps/differential.py` (sh↔ps1, **77 scenarios** — output bytes, file
  set, both normalised streams and the exit code).
- GitHub Actions CI: shellcheck, bash suites on Ubuntu+macOS, Node suite on
  {18,20,22}×{Ubuntu,macOS,Windows}, PowerShell suite on
  {Ubuntu,macOS,Windows}, both differentials + the help-sync gate, npm pack,
  version-consistency guard (`scripts/check-version-consistency.sh`).
- `VERSION` file — single source of truth used by `--update`.
- Docs: `docs/SMART-BOM.md`, `docs/CLI-CONTRACT.md`, `docs/UPDATE.md`,
  `docs/TESTING.md`, `docs/PS-PORT.md`, `CONTRIBUTING.md`, `SECURITY.md`.

### Fixed — defects of the v2.07 shell reference (all measured, all tested)

1. **macOS silently did nothing.** `stat -c` is GNU-only; on BSD/macOS every
   probe failed and all files were skipped as "clean". v3 has stat shims
   (GNU/BSD) and targets bash ≥ 3.2 (no associative arrays — the macOS
   system bash is 3.2).
2. **Timestamps were not preserved.** `touch -r "$backup"` referenced a fresh
   `cp` (mtime = now), re-stamping modified files despite the documented
   promise. v3 copies atime+mtime onto the temp file *before* the atomic
   rename (`--update-mtime` opts out).
3. **CRLF detection only probed the first 1024 bytes** — a CRLF at byte 2000
   was invisible (measured). v3 scans the whole file, byte-exact.
4. **Hex-window false positives.** v2 grepped the hex dump for the substring
   `0d0a`, which matches across byte boundaries (e.g. bytes `30 D0 A5`):
   clean files were needlessly rewritten (new inode, fresh mtime — breaking
   hard links and `make`-style caching). v3 matches real `CR LF` byte pairs.
5. **Binary files were rewritten.** No NUL detection existed; a
   BOM+NUL+CRLF `.txt` was modified (data corruption risk). v3 refuses.
6. **UTF-16/UTF-32 files could be rewritten** when the hex probe coincided.
   v3 refuses unconditionally.
7. **`--no-rn-normalize` did not work under MSYS/Git Bash** (bundled `sed`
   reads in text mode and strips CR anyway). v3 strips the BOM with
   `tail -c +4` (pure byte copy) and only invokes `sed` when CRLF
   normalisation is actually requested.
8. **`node_modules`, `.git`, `vendor` trees were rewritten** during recursive
   scans. v3 excludes VCS/dependency dirs by default.
9. **Cross-device "atomic" replace.** v2 built temp files in `$TMPDIR` and
   `mv`d them across filesystems — not atomic. v3 creates the temp next to
   the target (same filesystem) and verifies the result before rename.
10. **Inconsistent exit codes**: a missing explicit file argument reported
    "Access errors: 1" but exited 0; recursive mode exited 1 for the same
    condition. v3 exits 1 consistently.
11. **`ERROR_TYPES[size]` was dead code** (initialised, printed, never
    incremented). Oversize files are now detected per file (not only via
    `find -size`), counted and reported.
12. `umask 077` leaked into the whole script after the first temp file;
    cleanup used a stale `$$`-suffixed pattern in `$TMPDIR`; temp names
    collided across nested invocations. v3 uses `mktemp`, registers every
    temp file, and removes exactly those on exit/signals.
13. Hard-linked files were silently detached from their links by the atomic
    replace. v3 detects `nlink > 1` and rewrites in place (with rollback).
14. Symlink arguments were replaced by regular files (destroying the link).
    v3 resolves symlinks to their targets; the walk still never follows them.
15. shellcheck: v2 reported 20 findings (SC2059×12, SC2317×5, SC2155×2,
    SC2181×1); v3 is shellcheck-clean (0.9.0, default severity).
16. **CRLF detection was line-based, not byte-exact** — found by the
    PowerShell port, and a defect of *this* release's first draft rather than
    of v2. `has_crlf` used `grep '<CR>' (file ends in LF) and an awk
    end-of-line test otherwise. Every line-oriented tool defines "end of
    line" by the LF byte, so neither can distinguish a CR *immediately
    followed by* LF from a CR that merely ends an LF-delimited line.
    UTF-16LE encodes CR as `0D 00` and LF as `00 0A`, so `… 0D 00 0A` was
    reported as a CRLF: such files became modification candidates and were
    listed as protected, inflating `protectedUtf16or32` and printing warnings
    about files that needed nothing. That contradicted AGENTS.md invariant 3,
    `docs/SMART-BOM.md` §2 ("v3 matches the actual byte pair `0D 0A`") **and
    `bin/bom.js`, which was already byte-exact** — so the two v3 engines
    disagreed, and the sh↔node differential never caught it because no shared
    fixture had that byte pattern.
    Fixed: the file is rendered with `od -An -v -tx1` and the byte-aligned hex
    is searched for `0d0a`, so the match *is* the byte pair and NUL bytes are
    handled (which is also why v2's despaced hex window produced false
    positives — see item 1 of the v2 list). A `grep -q '<CR>'` pre-filter keeps
    CR-free files fast: measured on a 6 MB LF-only PHP file, 1.7 s before and
    after; a 6 MB file that does contain CRs costs ~1.9 s instead of ~0.01 s.
    Pinned by `t_policy_utf16_crlf_detection_regression` (bash) and its Node
    twin; reverting the fix turns four assertions red.

17. **A run of CRs before the LF was handled once, not to exhaustion** — a
    defect of all three implementations, found by the sh<->node and sh<->ps1
    differentials only after the MSYS `grep` defect above stopped masking it.
    The rule was written for a single CR: "delete a CR that is followed by LF".
    On `x CR CR LF` that removes the first CR and leaves `x LF CR LF`, which is
    still a CRLF, so `verify_clean_content` rejected the result and the run
    reported `Verification failed after cleaning` instead of cleaning the file.
    The three implementations did not even fail the same way: the reference wrote
    the bad bytes out, while `bin/bom.js` and `clean-bom-senior.ps1` refused to
    write and counted an error. A run is rare but real (touchpad and IME input,
    concatenated fragments), and the shared fixture `f8.xml` in the Node suite
    had carried the pattern all along — it was merely invisible while the
    reference refused to normalise CRLF at all under Git Bash.
    Fixed by collapsing the whole run to the single LF: `x CR CR LF` becomes
    `x LF` on all three, which also makes a second run a no-op, as a text tool
    must be (contract §7.2). Pinned by `t_core_cr_run_before_lf` (bash), its
    Node twin and a PowerShell assertion; reverting the fix in `bom.js` or the
    `.ps1` makes the differential red again.
18. **The MSYS `grep` pre-filter silenced CRLF detection completely.** `grep` is
    text-mode under Git Bash: it strips CR bytes before matching, so the "fast
    reject when the file has no CR byte at all" branch fired for files that were
    full of CRLF. Measured on Git Bash 5.3.15 — the same file gives
    `grep -c <CR>` = 0, `grep -U` = 2, `tr -dc <CR> | wc -c` = 2. On that
    platform the reference therefore never normalised a single CRLF, while
    `README.md` advertises Git Bash support and `--self-test` was 4 of 10 green.
    The pre-filter now counts CR bytes with `tr -dc <CR> | wc -c` (byte-oriented
    by construction, portable to BSD grep, and safe under `pipefail` because the
    consumer reads to EOF). Reverting it to `grep` turns six assertions red.
19. **`--update` refused every valid download whose script exceeded the pipe
    buffer.** The version-stamp check was
    `printf '%s' "$content" | grep -q "^VERSION=\"${remote}\""`, and under
    `set -o pipefail` the producer's SIGPIPE became the status of the whole
    pipeline: `grep -q` exits at the match, `printf` is still writing an 80 KB
    script, and the probe measured `PIPESTATUS = 141 0` — which `if !` reads as
    "stamp not found", so the updater refused a correct release and exited 3.
    Below the pipe buffer this cannot happen (64 KiB on MSYS, 16 KiB on macOS),
    which is why the 23 KB v2 script never showed it. The consumer is now `awk`,
    which reads to EOF; its `index()` test is also a literal match, so the dots
    in the expected version can no longer act as regex wildcards.
20. **The shellcheck gate was red on any host with a current shellcheck.** SC2317
    ("this function is never invoked") was split in 0.11: indirect invocation is
    now reported as **SC2329**, and `tests/sh/run-tests.sh` drives its 63 tests
    through a variable, so an unsuppressed run yields **80 findings** and exit 1.
    The repository was written and checked against 0.9.0 (`CHANGELOG` §Added,
    CI installs the Ubuntu package), where the same file is clean — so the gate's
    result silently depended on the linter's version. Measured: 0.11.0 on
    Windows 80 findings of SC2329, 0.9.0 on Debian exit 0. The suppression in the
    suite now names both codes.


### Changed

- Warnings are visible **by default** (v2 hid `WARN` behind `--verbose` —
  which is how protected-file decisions would have gone unnoticed).
- Summary: added `Files scanned`, the *Protected / Kept Unchanged* section
  and per-reason counters; v2 labels (`Files processed:`, `BOM signatures
  removed:`, …) are unchanged.
- Recursive display paths keep the v2 `./name` form; explicit arguments are
  echoed verbatim; directory scans display `dir/name`.
- Empty files are skipped by the walk (they cannot carry BOM/CRLF).
- Detection reads files fully (byte-exactness over sampling); deep checks
  (NUL, UTF-8 validity, non-ASCII) run **only** for modification candidates,
  so clean trees stay fast.

### Compatibility

| Implementation | Version | Status |
|---|---|---|
| `clean-bom-senior.sh` | 3.0.0 | reference (Linux/macOS/WSL/Git Bash) |
| `bin/bom.js` (npm `bom` / `clean-bom-senior`) | 3.0.0 | native Node.js, all platforms incl. Windows |
| `clean-bom-senior.ps1` | 3.0.0 | **full v3 port**, PowerShell 7.6+ (Windows/Linux/macOS) |
| `clean-bom-senior.bat` | 2.07.0 | **legacy**, frozen at the v2 contract |

- Every v2 flag (`-h -V -v -n --no-bom-clear --no-rn-normalize --`,
  positional files) behaves the same in v3 where it was not broken; the
  fixed behaviours above are deliberate, documented breaking changes
  (hence 3.0.0).
- The v2.07 differential/contract suites (`tests/legacy/`) were **removed**:
  all three of them compared against the v2.07 PowerShell port, which no
  longer exists, so they had no baseline left. They are one command away —
  `git show v3.0.0:tests/legacy/` — and `docs/BAT-PORT.md` §6 explains how
  to restore them before touching the batch port.
- **The cmd.exe port was deliberately not carried to v3.** A full draft was
  written and then withheld, because it could not be executed anywhere:
  wine's `cmd.exe` does not implement delayed expansion (`!V:~0,5!` returns
  the literal `[~0,5]`), has no ANSI escape acquisition, and Windows' own
  `certutil` — the only byte-I/O path cmd.exe has — does not exist under
  wine. An unverifiable safety tool is worse than an honest frozen one.
  `docs/BAT-PORT.md` §8 records the measurements and draws the exact line
  between what cmd.exe could and could not carry.

[3.0.0]: https://github.com/paulmann/Clean_BOM_Senior/releases/tag/v3.0.0

## [2.7.0] and earlier (2.07.x script generation)

See the git history and `docs/RAGRAF-REPORT.md` / `docs/BAT-PORT.md` for the
v2 era: the original shell tool, npm packaging, the PowerShell 7.6 port with
byte-for-byte parity tests, and the cmd.exe batch port via `certutil`.