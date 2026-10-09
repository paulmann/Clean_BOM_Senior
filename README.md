# Clean BOM Senior 🧹✨

[![Version](https://img.shields.io/badge/version-3.0.0-blue.svg)](CHANGELOG.md)
[![npm version](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![npm downloads](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![CI](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmann/Clean_BOM_Senior/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

> **Removes invisible UTF-8 BOM and Windows CRLF from source files — and knows
> when it must not.** Atomic, byte-exact, CI-friendly: a file is rewritten only
> when cleaning is genuinely needed and genuinely safe, and never when its BOM
> is load-bearing.

A UTF-8 BOM (`EF BB BF`) at the top of a PHP file breaks `header()`, sessions
and JSON APIs; CRLF line endings from a Windows editor pollute diffs and
shell scripts. But the naive fix — "strip every BOM" — **corrupts files**:
for UTF-16/UTF-32 the BOM *is* the format, and for a non-ASCII `.txt`/`.csv`
it is the only thing that makes Excel and Windows Notepad read the file as
UTF-8 instead of mojibake.

**Clean BOM Senior v3 answers two questions per file, by its actual bytes,
before writing anything:**

1. *Is cleaning needed at all?* — byte-exact whole-file detection (a clean
   file is never rewritten: inode, mtime and hard links stay intact).
2. *Is the BOM perhaps required?* — the [**Smart BOM Policy**](docs/SMART-BOM.md):
   UTF-16/32 and binary files are refused unconditionally, invalid UTF-8 is
   protected, "sensitive" text keeps its BOM with an explanation, and code
   files (php/js/css/html/xml…) get cleaned. Every decision is logged with a
   reason and available as JSON.

---

## Quick start

```bash
# Anywhere (npm, Node ≥ 18 — Linux, macOS, Windows):
npm install -g clean-bom-senior
bom --dry-run                      # explain what would change and why
bom                                # clean the current tree, smart & safe

# POSIX (no npm needed):
curl -fsSLO https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh
./clean-bom-senior.sh --self-test  # verify the tool on THIS machine
./clean-bom-senior.sh              # clean the current tree

# CI gate — fail the build when anything needs cleaning:
bom --check                        # exit 10 = dirty, 0 = clean
```

## What you get

| | |
|---|---|
| 🧠 **Smart BOM Policy** | Never strips a BOM the file requires: UTF-16/32 refused unconditionally, NUL-binary refused, invalid UTF-8 protected, Excel/Notepad-sensitive text (`txt csv ps1…`, non-ASCII) kept with an explanation — `--force` to override the soft cases. [Full decision table →](docs/SMART-BOM.md) |
| 🔬 **Byte-exact detection** | Whole-file scans, no sampling windows: no false positives (v2 rewrote files whose *hex dump* merely contained `0d0a`), no false negatives (v2 missed CRLF past byte 1024). |
| 🛡️ **Atomic & verified writes** | Temp file in the same directory → content verification → `rename(2)`. Hard links rewritten in place, symlinks resolved, permissions/ownership/timestamps preserved. A crash can never leave a half-written file. |
| 🤖 **CI-native** | `--check` (exit 10), `--json` report, `--strict`, `--quiet`, `NO_COLOR`, deterministic output, git-hook ready. |
| 🚫 **Sane scope** | `.git`, `.svn`, `.hg`, `node_modules` excluded by default; `--ext/--add-ext/--exclude/--exclude-dir/--max-size/--git` to shape the rest. |
| 🔄 **Self-updating** | `--check-update` (exit 11) and `--update` with content verification; mirrors via `CLEAN_BOM_UPDATE_URL`; npm installs are redirected to npm. [Details →](docs/UPDATE.md) |
| 📖 **Comprehensive help** | `--help` plus 12 topics: `--help bom-policy`, `--help ci`, `--help json`, … |

## Implementations — one contract

| Implementation | Version | Platforms | Status |
|---|---|---|---|
| [`clean-bom-senior.sh`](clean-bom-senior.sh) | **3.0.0** | Linux, macOS, *BSD, WSL, Git Bash (bash ≥ 3.2, GNU **and** BSD userland) | reference |
| [`bin/bom.js`](bin/bom.js) — npm `bom` / `clean-bom-senior` | **3.0.0** | **everywhere Node ≥ 18 runs, incl. native Windows** | native CLI |
| [`clean-bom-senior.ps1`](clean-bom-senior.ps1) | **3.0.0** | **PowerShell 7.6+ — Windows, Linux, macOS. No external tool required** | full port |
| [`clean-bom-senior.bat`](clean-bom-senior.bat) | 2.07.0 | Windows `cmd.exe` (no PowerShell, no Git Bash) | **legacy**, frozen at the v2 contract |

The three v3 implementations are pinned byte-for-byte by two differential
tests — `node tests/node/run-tests.mjs differential` (sh ↔ node) and
`python3 tests/ps/differential.py` (sh ↔ ps1, 77 scenarios). On Windows, use
the npm CLI or the PowerShell port; the batch port remains for hosts with
neither, and is a **v2.07** tool — see [`docs/BAT-PORT.md`](docs/BAT-PORT.md)
§8 for why it was not carried to v3.
Contract: [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md).

---

## Installation

### npm (recommended — all platforms, incl. Windows)

```bash
npm install -g clean-bom-senior
bom --version            # → bom version 3.0.0 (Node.js implementation)
clean-bom-senior --help  # same tool, longer alias
```

### POSIX shell — from source

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
sudo install -m 755 clean-bom-senior.sh /usr/local/bin/clean-bom-senior
clean-bom-senior --self-test
```

### POSIX shell — one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.sh \
  -o clean-bom-senior.sh && chmod +x clean-bom-senior.sh
```

### PowerShell 7.6+ — from source (Windows, Linux, macOS)

No external tool is needed for cleaning; everything is .NET byte I/O.

```powershell
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
./clean-bom-senior.ps1 --self-test          # 10 fixtures, verifies this host
./clean-bom-senior.ps1 --help bom-policy    # the Smart BOM Policy in detail

# optional: put it on PATH
Copy-Item clean-bom-senior.ps1 "$HOME/.local/bin/clean-bom-senior.ps1"
```

> The file is **pure ASCII on purpose**, so `./clean-bom-senior.ps1` works
> directly on Unix — a UTF-8 BOM in front of the shebang would make the kernel
> fall back to `/bin/sh`. The built-in help still emits the reference's em
> dashes and arrows: they are stored as placeholders and restored on output.
> See [`docs/PS-PORT.md`](docs/PS-PORT.md) §5.

### Self-update (all three v3 implementations)

```bash
clean-bom-senior.sh --check-update   # exit 11 when a newer release exists
clean-bom-senior.sh --update         # verified atomic self-replace
```

```powershell
./clean-bom-senior.ps1 --check-update   # same contract, same exit codes
./clean-bom-senior.ps1 --update         # verifies the #Requires header + version stamp
```

```bash
npm i -g clean-bom-senior@latest     # the npm way (enforced automatically:
                                     # --update refuses npm-managed installs)
```

### Uninstall

```bash
npm uninstall -g clean-bom-senior    # npm install
sudo rm /usr/local/bin/clean-bom-senior   # manual install
```

---

## Usage

```bash
clean-bom-senior.sh [OPTIONS] [PATH...]
```

`PATH` is a file **or a directory** (scanned recursively); with no `PATH` the
current directory is scanned. Options may be interspersed; `--` ends option
parsing (so file names may start with `-`).

### The everyday commands

```bash
bom                          # clean the tree with smart safe defaults
bom --dry-run                # what would change, and why (no writes)
bom --check                  # CI gate: exit 10 if anything is dirty
bom --check --json > r.json  # machine-readable gate report
bom src index.php            # a directory + a file
bom --git                    # only git-tracked files
bom -v                       # per-file log with every decision
```

### Smart BOM Policy in one picture

```
                      ┌─ UTF-16/32 BOM ────────────► REFUSE (never touch)
file bytes ──classify─┼─ NUL bytes ────────────────► REFUSE (never touch)
                      ├─ invalid UTF-8 ────────────► PROTECT (--force: byte-clean)
                      ├─ UTF-8 BOM + sensitive ext ┐
                      │   + non-ASCII content ─────► KEEP BOM, fix CRLF, explain
                      ├─ UTF-8 BOM + code/ASCII ───► STRIP BOM (+ fix CRLF)
                      └─ no BOM, no CRLF ──────────► CLEAN: not rewritten at all
```

Details, rationale and references: [`docs/SMART-BOM.md`](docs/SMART-BOM.md) ·
`bom --help bom-policy`.

### Flag reference (abridged — full: `--help options`)

| Group | Flags |
|---|---|
| Operation | `-n/--dry-run` `-c/--check` `-f/--fix` `-v/--verbose` `-q/--quiet` `--silent` `-j/--json` `--color auto\|always\|never` `--log-file FILE` |
| Selection | `--ext LIST` `--add-ext LIST` `--exclude GLOB` `--exclude-dir NAME` `--no-default-excludes` `--max-size 10M` `--git` |
| BOM policy | `--bom-policy auto\|strip\|keep` `--sensitive-ext LIST` `--force` |
| Transform | `--no-bom-clear` `--no-rn-normalize`/`--no-crlf-normalize` `--update-mtime` `--backup` `--backup-dir DIR` |
| Info | `-h/--help [TOPIC]` `-V/--version` `--self-test` `--completion` `--strict` |
| Update | `--check-update` `--update` |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success (clean tree, or everything cleaned) |
| 1 | per-file errors, or `--strict` saw kept/protected files |
| 2 | usage error |
| 3 | environment problem (deps, temp, update network, npm-managed `--update`) |
| 4 | critical internal error |
| **10** | `--check`: files need cleaning |
| **11** | `--check-update`: update available |

---

## CI / CD

### GitHub Actions

```yaml
- uses: actions/setup-node@v4
  with: { node-version: 20 }
- run: npm i -g clean-bom-senior
- name: BOM/CRLF gate
  run: bom --check --quiet --json > bom-report.json || exit $?
  # exit 10 fails the job; upload bom-report.json as an artifact
```

### Pre-commit hook

```bash
#!/bin/sh
# .git/hooks/pre-commit  (chmod +x)
clean-bom-senior --check --git --quiet || {
  echo "BOM/CRLF issues found. Fix with: clean-bom-senior --git" >&2
  exit 1
}
```

### Make

```make
.PHONY: bom-check bom-fix
bom-check:
	@bom --check --quiet
bom-fix:
	@bom --quiet
```

More recipes: `bom --help ci`.

---

## Why BOMs hurt (the PHP story)

```php
\xEF\xBB\xBF<?php           ← invisible BOM
header('Content-Type: application/json');
```

- `Warning: Cannot modify header information — headers already sent`: the BOM
  *is* output, emitted before `header()` runs.
- Broken JSON/XML APIs: consumers choke on `\uFEFF{...}`.
- Concatenated builds and `include`d files leak BOMs mid-stream.
- Mixed CRLF/LF trees produce whole-file diffs and break `#!/bin/sh`
  shebangs (`/bin/sh^M: bad interpreter`).

And why "strip everything" is *also* wrong:

- **UTF-16/UTF-32**: the BOM is the endianness signature — removing it
  corrupts the file (Notepad's "Unicode" `.txt` is exactly this).
- **Excel / legacy Notepad / Win32 ANSI APIs**: BOM-less UTF-8 `.csv`/`.txt`
  with non-ASCII content renders as mojibake (`café` → `cafÃ©`).
- **Windows PowerShell 5.1**: parses BOM-less non-ASCII `.ps1` as ANSI —
  the script changes meaning or fails.

v3 keeps the BOM exactly where it is load-bearing and strips it exactly where
it is dirt — and tells you which decision it made, per file.

---

## Safety guarantees

- **Never rewritten unless needed**: clean files keep their inode and mtime
  (asserted by tests).
- **Atomic + verified**: temp file in the same directory → verification
  (BOM gone / CRLF gone / nothing added) → `rename(2)`; rollback copies for
  in-place rewrites; no leftovers (asserted).
- **Hard refusals no flag can override**: UTF-16/32, NUL-binary
  (`--force` only unlocks the *soft* protections).
- **Metadata**: permissions always, ownership as root, timestamps of modified
  files by default (`--update-mtime` opts out).
- **Hard links & symlinks**: links stay links (in-place rewrite + warning);
  symlink arguments are resolved; the walk never follows symlinks.
- Full list: `bom --help safety` · [`docs/SMART-BOM.md`](docs/SMART-BOM.md) §4.

## Documentation

| Document | Contents |
|---|---|
| [`docs/SMART-BOM.md`](docs/SMART-BOM.md) | the policy: decision table, rationale, encoding references |
| [`docs/CLI-CONTRACT.md`](docs/CLI-CONTRACT.md) | normative v3 contract: flags, exit codes, streams, JSON schema, byte semantics |
| [`docs/UPDATE.md`](docs/UPDATE.md) | auto-update design, verification, mirrors, release checklist |
| [`docs/TESTING.md`](docs/TESTING.md) | test architecture, coverage map, the two differentials, PowerShell invocation traps |
| [`docs/PS-PORT.md`](docs/PS-PORT.md) | the PowerShell port: structure, divergences, traps hit, what it found in the reference |
| [`CHANGELOG.md`](CHANGELOG.md) | v3.0.0: every fixed v2 defect, measured |
| [`docs/BAT-PORT.md`](docs/BAT-PORT.md) | (legacy) how the cmd.exe port works, and why there is no v3 batch port |
| [`docs/RAGRAF-REPORT.md`](docs/RAGRAF-REPORT.md) | (legacy) v2-era audit report |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) | ground rules · vulnerability reporting |

## Development & testing

```bash
bash tests/sh/run-tests.sh -v    # reference suite (167 assertions)
node tests/node/run-tests.mjs    # Node suite (161 assertions) + sh↔node differential
pwsh -File tests/ps/run-tests.ps1 # PowerShell suite (237 assertions) + sh↔ps1 differential
python3 tests/ps/differential.py # sh ↔ ps1 byte parity, 77 scenarios
bom --self-test                  # built-in acceptance, any host
./clean-bom-senior.ps1 --self-test
shellcheck clean-bom-senior.sh   # 0 findings
bash scripts/check-version-consistency.sh
python3 scripts/gen-ps-help.py --check   # ps1 help still derived from the reference
```

CI matrix: shellcheck → bash suites (Ubuntu, macOS) → Node suites
({18,20,22} × {Ubuntu, macOS, Windows}) → PowerShell suites (Ubuntu, macOS,
Windows) → both differentials + help-sync gate → npm pack → version guard.
See [`docs/TESTING.md`](docs/TESTING.md).

## Requirements

- **npm CLI**: Node ≥ 18. Nothing else — any OS.
- **PowerShell port**: PowerShell 7.6+ (Core). Nothing else is required for
  cleaning; `git` for `--git`, `curl` for `--update`/`--check-update`
  (`Invoke-WebRequest` is the fallback), `stat`/`fsutil` for hard-link
  detection, `chown` for ownership transfer as root.
- **Shell reference**: bash ≥ 3.2 (macOS system bash works), standard
  userland (`find sed awk od grep stat tail wc tr mv cp touch chmod mktemp`);
  optional: `iconv` (UTF-8 validation), `curl`/`wget` (`--update`), `git`
  (`--git`).
- **Legacy ports**: PowerShell 7.6+ / Windows 10–11 `cmd.exe`.

## License

[MIT](LICENSE) © Mikhail Deynekin — [deynekin.com](https://deynekin.com)
