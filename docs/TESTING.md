# Testing

## Suites at a glance

| Suite | What it pins | Runs on | Command |
|---|---|---|---|
| `tests/sh/run-tests.sh` | the bash reference, v3 contract (**167 assertions**) | Linux, macOS, WSL, Git Bash | `bash tests/sh/run-tests.sh [-k] [-v] [FILTER]` |
| `tests/node/run-tests.mjs` | the Node CLI, v3 contract (**161 assertions**) **+ sh↔node differential** | Linux, macOS, **Windows** | `node tests/node/run-tests.mjs [FILTER]` |
| `tests/ps/run-tests.ps1` | the PowerShell port, v3 contract (**237 assertions**, 63 groups) **+ sh↔ps1 differential** | Linux, macOS, **Windows** (pwsh 7.6+) | `pwsh -File tests/ps/run-tests.ps1 [FILTER]` |
| `tests/ps/differential.py` | sh↔ps1 byte parity on 77 scenarios | Linux, macOS (needs bash + pwsh) | `python3 tests/ps/differential.py [CASE ...]` |
| built-in `--self-test` | the installation on *any* host (10 fixtures) | everywhere | `clean-bom-senior.sh --self-test` / `bom --self-test` / `./clean-bom-senior.ps1 --self-test` |
| `scripts/gen-ps-help.py --check` | the PowerShell help text is still derived from the reference | everywhere (python3) | `python3 scripts/gen-ps-help.py --check` |
| `scripts/check-version-consistency.sh` | release hygiene across all four files | everywhere | `bash scripts/check-version-consistency.sh` |

CI runs all of these on a matrix (`.github/workflows/ci.yml`): shellcheck →
bash suite on Ubuntu+macOS → Node suite on {18,20,22} × {Ubuntu, macOS,
Windows} → PowerShell suite on {Ubuntu, macOS, Windows} → both differentials →
npm pack + version guard.

The cmd.exe port (`clean-bom-senior.bat`) is frozen at the v2.07 contract and
has **no automated suite in this tree** — see *The frozen batch port* below.

## Design principles (how the suites are built)

1. **Raw bytes, never "text".** Every fixture is written from hex —
   `printf '\xNN'` in bash, `Buffer.from(hex)` in Node, a hex→byte loop in
   PowerShell. An editor, git or a shell layer must never be able to normalise
   what the test believes it created. It also keeps every test file pure ASCII,
   so the Smart BOM Policy has no opinion about the suite itself.
2. **Assert bytes, inodes, mtimes and exit codes** — not just "the tool
   printed success". "Clean file not rewritten" means the *inode* is stable.
3. **Isolation.** Each test gets a fresh temp workspace; the tool runs with its
   working directory inside it (the tool cleans the CWD recursively by
   default — running a test inside the repository would rewrite the
   repository).
4. **Regression pinning.** Every v2 defect listed in `CHANGELOG.md` §Fixed has
   a named test (`…regression`, `…v2 gave 0`, `--no-rn-normalize (v2/MSYS
   regression)`, …), and so does every defect found *while porting* — see
   `t_policy_utf16_crlf_detection_regression` and its Node twin.
5. **Differential parity.** One contract, three implementations. Each port runs
   *both* engines over the same fixtures and compares the resulting bytes, the
   file set, both output streams and the exit code. Any divergence is a defect
   in one of them — and twice it was a defect in the *reference* (§ below).
6. **A test that cannot fail proves nothing.** When you touch a test, inject
   the defect it guards against and watch it go red first. Both CRLF-detection
   regressions were verified this way: reverting the fix turns 4 assertions red.
7. **Update machinery is tested without the network**: the bash suite points
   `CLEAN_BOM_UPDATE_URL` at a `file://` fake repository; the Node suite spins
   up a localhost HTTP server (async spawn — `spawnSync` would deadlock the
   in-process server); the PowerShell suite uses `file://` too.
8. **Help text is generated, not copied.** `scripts/gen-ps-help.py` derives the
   twelve PowerShell help topics from the here-docs in `clean-bom-senior.sh`,
   and CI fails when they drift. Hand-copying documentation between
   implementations is how they diverge.

## What the suites cover (map)

- Core: BOM, CRLF, BOM+CRLF, clean files, empty files, BOM-only files,
  no-trailing-newline, lone CR / EOF-CR semantics, late CRLF (>1024 B),
  uppercase extensions, hex false-positive regression.
- Smart BOM Policy: UTF-16LE/BE, UTF-32LE/BE (incl. `--force` refusal),
  **CRLF detection is byte-exact, not line-based**, NUL-binary (incl. NUL
  beyond 8 KiB), invalid UTF-8 (default + `--force`), sensitive
  keep/force/policy-strip/policy-keep, ASCII-only strip, `--sensitive-ext`
  customisation, `--no-bom-clear`, `--no-rn-normalize`, both-disabled.
- Metadata: mtime preservation + `--update-mtime`, permissions, hard links
  (inode preserved, both links updated), symlink arguments (link survives,
  target cleaned), `--backup`/`--backup-dir`, no leftovers, idempotency.
- Modes: dry-run, check (10/0), JSON schema/counters/purity, strict,
  quiet/silent, log-file.
- Selection: directory args (and their display-path contract), recursion,
  `--ext`/`--add-ext` (incl. list normalisation order), default exclusions +
  `--no-default-excludes` + `--exclude`/`--exclude-dir`, `--max-size`
  (incl. bad value → 2, unit suffixes), `--git` (tracked vs untracked).
- CLI: unknown option / bare `-` → 2 (and *which* usage errors carry the
  `Try … --help` hint), `--` terminator, missing file → 1, mixed
  success/failure → 1, interspersed options, help/topics/version/completion,
  `CLEAN_BOM_OPTS`, colour modes incl. `NO_COLOR`, summary counters, filenames
  with spaces/quotes/JSON escaping, self-test.
- Update: newer → 11, current → 0, unreachable source → 3, apply-and-verify,
  tampered download → 3 with a byte-identical original.
- Repo: version consistency across four files, generated-help sync,
  sh↔node differential, sh↔ps1 differential.

## Two defects the differential found in the *reference*

Porting is the cheapest possible audit, because a port has to answer questions
the original never had to. Two answers disagreed with the documentation:

1. **CRLF detection was line-based, not byte-exact.** `has_crlf` used
   `grep '<CR>$'` and an awk end-of-line test. Every line-oriented tool defines
   "end of line" by the LF byte, so neither can distinguish a CR *immediately
   followed by* LF from a CR that merely ends an LF-delimited line. UTF-16LE
   encodes CR as `0D 00` and LF as `00 0A`, so `… 0D 00 0A` was reported as a
   CRLF: such files were flagged as modification candidates and listed as
   protected, inflating `protectedUtf16or32` and warning about files that
   needed nothing. That contradicted AGENTS.md invariant 3, `docs/SMART-BOM.md`
   §2 ("v3 matches the actual byte pair `0D 0A`") and `bin/bom.js`, which was
   already byte-exact. Fixed in `has_crlf` (od-rendered hex, so `0d0a` *is* the
   byte pair and NUL bytes are handled), pinned by a named regression test in
   both the bash and the Node suite.
   *Cost, stated plainly:* the exact scan is `od | tr | awk` and is only run on
   files that contain a CR byte at all (a pre-filter rejects the rest in
   milliseconds). Measured on a 6 MB LF-only PHP file: 1.7 s before, 1.7 s
   after. A 6 MB file that *does* contain CRs costs ~1.9 s instead of ~0.01 s.
   The PowerShell port is unaffected — it scans the byte array directly and
   measures 0.7 s on the same file.
   *The pre-filter itself was a defect on Git Bash* (found by running the
   suite, not by reading the code): `grep` is text-mode under MSYS and strips
   CR bytes before matching, so the reject branch fired for files full of CRLF
   and the reference never normalised anything on that platform (`--self-test`
   4 of 10). The same file measures `grep -c <CR>` = 0, `grep -U` = 2,
   `tr -dc <CR> | wc -c` = 2. It now counts bytes with `tr`, which is also the
   portable form: `grep -U` is GNU-only and this file must run on macOS.

2. **The compatibility matrix in `--help` still described the ports as legacy.**
   Now generated from one place for sh and ps1, and updated by hand in
   `bin/bom.js` (which has always shipped its own wording for that topic).

## Three defects the three-way differential found, and why one masked the next

With CRLF detection working on every platform, the sh↔node and sh↔ps1
comparisons became meaningful for the first time on Git Bash, and two more
defects came out — both of them cases where a *single* byte pattern was the
whole difference:

1. **A run of CRs before the LF (`x CR CR LF`) was handled once, not to
   exhaustion.** The rule was written for one CR per line, so `CR CR LF` came
   back as `CR LF` — still a CRLF — and the post-write verification rejected the
   tool's own output. The reference wrote the bad bytes out; `bin/bom.js` and the
   PowerShell port logged `Verification failed after cleaning` and refused to
   write at all. The Node suite's own fixture `f8.xml` had carried exactly this
   pattern from the start; it proved nothing while the reference refused to
   normalise CRLF under Git Bash, which is the point worth remembering: **a
   fixture only tests what the implementations actually reach.**
2. **`tests/ps/differential.py` could not run on Windows at all.** It executed
   the `.sh` reference directly, which fails with `OSError: [WinError 193] %1 is
   not a valid Win32 application`, and it ended as an unhandled traceback in a
   CI matrix that includes `windows-latest`. It now hands the reference to bash,
   skips cleanly when bash is absent, and passes `MSYS=noglob` to its bash
   child.

That last detail was itself a defect of the harness and is worth stating
plainly, because it looked exactly like a bug in the tool: when Python (a
non-MSYS program) launches bash, the MSYS runtime **globs the arguments** it
passes on, so `--exclude '*/nested/*'` reached the reference pre-expanded into
`src/nested/c.js`. The reference then dutifully excluded that one file and the
two "identical" runs had in fact been asked for different things. Traced as
`EXCLUDE_PATTERNS=$'src/nested/c.js\n'`. Nothing in the tool was wrong.

## PowerShell suite: two invocation traps worth knowing

`tests/ps/run-tests.ps1` invokes the tool **in-process**, because spawning
`pwsh` costs about a second and 63 groups would take minutes. Two things then
matter, and both cost real debugging time:

- **Splatting.** `& $script a,b` and `& $script @(a,b)` both hand the script a
  *single* string argument `"a b"`; a literal comma list is one expression and
  `@(...)` around an expression is not splatting. Splatting only happens
  against a variable holding a real array, hence `[string[]]$toolArgs` +
  `& $tool @toolArgs`. The tool's own `--self-test` had the same bug.
- **Location vs process CWD.** `[Environment]::CurrentDirectory` is what .NET
  resolves relative paths against, and PowerShell re-syncs it to its own
  Location before launching a *native* command. Setting only one of the two
  makes `[System.IO.File]` and `stat` disagree about what `./file` means —
  which silently turned a hard-linked file's in-place rewrite into an atomic
  replace. The harness sets both (`Push-Location` **and**
  `[Environment]::CurrentDirectory`).

Also: `[Console]::Out.Write` bypasses PowerShell's stream plumbing, so
capturing the tool's output needs `[Console]::SetOut`/`SetError` with a
`StringWriter`, not `2>&1 | Out-String`.

## The frozen batch port

`clean-bom-senior.bat` implements the **v2.07** contract and is frozen. Its
differential suite was removed together with the v2.07 PowerShell port it used
as a comparison baseline (`git show v3.0.0:tests/legacy/` still has all three
files). To exercise the batch port:

```powershell
git checkout v2.07.0            # the generation its tests assert
pwsh -NoProfile -File .\tests\legacy\bat-differential.ps1
```

Reason it is not part of v3: a full v3 cmd.exe port cannot be *verified* on
anything but Windows, and an unverifiable safety tool is worse than an honest
frozen one. What was measured while investigating: wine's `cmd.exe` does not
implement delayed expansion (`!V:~0,5!` comes back as the literal `[~0,5]`),
has no ANSI escape acquisition, and Windows' own `certutil` — the only byte-I/O
path cmd.exe has — does not exist under wine at all. See `docs/BAT-PORT.md`
§8 for the full assessment and the options.

On Windows, use `bin/bom.js` (npm) or `clean-bom-senior.ps1` for v3 behaviour.

## Running everything locally

```bash
npm test                       # Node suite (any OS)
npm run test:sh                # bash suite (POSIX)
npm run test:ps                # PowerShell suite (pwsh 7.6+)
npm run selftest               # built-in acceptance
npm run lint:sh                # shellcheck (if installed)
npm run version:check          # release hygiene
python3 scripts/gen-ps-help.py --check    # help text still derived from sh
python3 tests/ps/differential.py          # sh vs ps1, 77 scenarios
```

Useful switches for the PowerShell suite:

```powershell
pwsh -File tests/ps/run-tests.ps1 'hard links'   # filter by group name
$env:CLEANBOM_PS_KEEPWS = '1'                     # keep the fixture workspace
$env:DIFF_VERBOSE = '1'; $env:DIFF_KEEP = '1'     # differential: full streams
python3 tests/ps/differential.py basic json       # differential: named cases
```
