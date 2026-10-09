# PowerShell Port — `clean-bom-senior.ps1`

> **Status: v3.0.0, full contract.** This is a complete PowerShell
> implementation of `docs/CLI-CONTRACT.md`, pinned to the bash reference by a
> 238-assertion suite (`tests/ps/run-tests.ps1`) and a 77-scenario
> byte-for-byte differential (`tests/ps/differential.py`). It replaced the
> v2.07 port that lived here before; that file is in the git history
> (`git show v3.0.0:clean-bom-senior.ps1`).

| | `clean-bom-senior.sh` | `bin/bom.js` | `clean-bom-senior.ps1` | `clean-bom-senior.bat` |
|---|---|---|---|---|
| Contract | v3 (reference) | v3 | **v3** | v2.07 (frozen) |
| Host | Linux, macOS, Git Bash | anywhere Node ≥ 18 runs | **PowerShell 7.6+ on Windows, Linux, macOS** | Windows 10/11 `cmd.exe` |
| Byte I/O | `od`, `sed`, `tail` | `Buffer` | **`System.IO.File` + `byte[]`** | `certutil -encodehex/-decodehex` |
| UTF-8 validation | `iconv` (optional) | built-in strict decoder | **`UTF8Encoding(throwOnInvalidBytes)` via `Decoder.Convert`** | PowerShell, else reported as disabled |
| Parity basis | reference | differential vs `.sh` | **differential vs `.sh`** | none (frozen) |
| Test | `tests/sh` | `tests/node` | **`tests/ps`** | — |

---

## 1. Why a fourth implementation

`bin/bom.js` already covers Windows, so the honest answer is: for the hosts
where Node is not a dependency anyone wants to add. A Windows shop that runs
its deployment through PowerShell remoting, a build agent with no Node
toolchain, an air-gapped host with nothing but the OS — those have PowerShell
7 and nothing else. This port needs **no external tool at all** for cleaning:
everything is .NET byte I/O.

The second reason turned out to matter more. Porting is the cheapest possible
audit of a specification, because a port has to answer questions the original
never had to. This one found a real defect in the reference — see §6.

## 2. Structure: the port mirrors the reference on purpose

The functions are deliberately one-to-one with `clean-bom-senior.sh`, in the
same order, with the same responsibilities. That is not aesthetics: it makes
the differential test meaningful, and it means a fix in one implementation has
an obvious home in the other.

| Reference (`sh`) | Port (`ps1`) |
|---|---|
| `log_raw` / `log_info` / `log_warn` / `log_error` | `Write-LogRaw` / `Write-LogInfo` / `Write-LogWarn` / `Write-LogError` |
| `die_usage` / `die_env` / `die_internal` | `Stop-Usage` / `Stop-Env` / `Stop-Internal` |
| `color_init` | `Initialize-Color` |
| `file_size` / `file_nlink` / `file_inode` / `file_attrs` | `Get-FileSizeBytes` / `Get-FileLinkCount` / `Get-FileInode` / `Get-FileUnixMode` |
| `resolve_path` | `Resolve-FullPath` |
| `read_magic` / `classify_bom` | `Get-MagicHex` / `Get-BomClass` |
| `has_crlf` / `has_nul` / `is_valid_utf8` / `has_non_ascii` | `Test-HasCrlf` / `Test-HasNul` / `Test-IsValidUtf8` / `Test-HasNonAscii` |
| `get_extension` / `in_list` / `ext_class` / `class_is_sensitive` | `Get-ExtensionLower` / `Test-InList` / `Get-ExtClass` / `Test-ClassIsSensitive` |
| `analyze_file` → `A_*` | `Get-FileAnalysis` → `$script:A` |
| `plan_file` → `P_*` | `Get-FilePlan` → `$script:P` |
| `build_clean_content` / `verify_clean_content` | `Get-CleanContent` / `Test-CleanContentValid` |
| `apply_attrs_to` / `make_backup_copy` / `write_in_place` / `transform_file` | `Set-FileAttributes` / `New-BackupCopy` / `Write-InPlace` / `Invoke-FileTransform` |
| `handle_file` | `Invoke-FileHandling` |
| `path_excluded` / `build_find_expr`+`scan_directory` / `scan_git_tracked` | `Test-PathExcluded` / `Get-WalkFiles`+`Invoke-DirectoryScan` / `Invoke-GitScan` |
| `display_statistics` / `show_greeting` / `json_report` | `Write-Statistics` / `Write-Greeting` / `Write-JsonReport` |
| `help_*` / `show_help` | **generated** (see §4) |
| `self_test` / `do_check_update` / `do_update` | `Invoke-SelfTest` / `Invoke-CheckUpdate` / `Invoke-SelfUpdate` |
| `parse_arguments` / `main` | `Invoke-ArgumentParsing` / `Invoke-Main` |

## 3. How the byte semantics are met

The contract (§7) is about bytes, so the port never lets a string encoding
touch file content:

- **Detection.** `Test-HasCrlf` walks the `byte[]` for `0x0D` and tests whether
  the *next* byte is `0x0A`. A CR as the final byte therefore cannot flag a
  file, which is the contract's rule, and it falls out of the scan for free.
  `Test-HasNul` is `Array.IndexOf(content, 0)`.
- **Validation.** `Test-IsValidUtf8` uses `UTF8Encoding($false, $true)` and its
  `Decoder.Convert` in 64 KiB chunks with `flush: $true` on the last one.
  *Measured, not assumed:* `GetByteCount()` does **not** validate — it happily
  counts `C3 28`, `ED A0 80` and a lone `FF`, because counting never runs the
  fallback. `GetString()` does validate but materialises the whole decoded
  string. `Decoder.Convert` validates incrementally, keeps state across chunks
  so a multi-byte sequence split at a boundary is not a false positive, and the
  final flush catches a truncated sequence at EOF.
- **Transformation.** `Get-CleanContent` strips bytes 0–2 when the plan says
  so, then runs `Convert-CrlfBytes` (drop every CR that precedes an LF, plus a
  CR as the final byte), then `Remove-TrailingCr` for the BOM-only path. The
  result is verified before it is installed, and verification failure leaves the
  original untouched.
- **Non-ASCII test** for the sensitive-extension rule scans from offset 3 when a
  UTF-8 BOM is present, from 0 otherwise.

Performance, measured on the same 6 MB LF-only PHP file: **sh 1.7 s, ps1 0.7 s**.
The port reads the file once and scans the array; the reference shells out to
`od | tr | awk` for the byte-exact CRLF answer.

## 4. The help text is generated, not copied

Twelve help topics are part of the contract, and hand-copying them between four
implementations is exactly how they drift — `bin/bom.js` and the reference had
already diverged in wording before this port existed.

`scripts/gen-ps-help.py` extracts the here-doc bodies from
`clean-bom-senior.sh`, folds the constant echoes (`$(fmt_size
"$MAX_SIZE_DEFAULT")`, `$EXTENSIONS_DEFAULT`, `$STRIP_ALWAYS`,
`$SENSITIVE_DEFAULT`, `$(help_topics_list`) to their literal values, maps
`$SCRIPT_NAME`/`$VERSION`/`$REPO_SLUG_DEFAULT` to PowerShell variables, and
emits the `Write-Help*` functions between the `# BEGIN GENERATED HELP` /
`# END GENERATED HELP` banner. Three sentences are port-specific by design and
are substituted there (`--completion` names the host shell; `--help update`
names the file it replaces and how it verifies it; `--help env` names the file
a mirror must serve).

```bash
python3 scripts/gen-ps-help.py           # regenerate after editing the reference
python3 scripts/gen-ps-help.py --check   # CI gate: fails on drift
```

Edit `clean-bom-senior.sh`, then regenerate. Never edit the generated block by
hand — the next run overwrites it.

## 5. Deliberate divergences

Each is a decision, and each is asserted by the suite rather than ignored.

| # | Area | Behaviour in `.ps1` | Why |
|---|---|---|---|
| 1 | `--completion` | emits `Register-ArgumentCompleter` for `clean-bom-senior.ps1`, `clean-bom-senior` and `bom` | cmd/bash completion scripts are useless in PowerShell; the reference emits bash. The topic is compared structurally, not literally |
| 2 | Ownership & permissions | permissions transfer through `FileInfo.UnixFileMode` (.NET 10, no `chmod` needed); ownership via `chown` and only as root; on Windows NTFS ACLs are inherited by the replacement | POSIX uid/gid are not meaningful on Windows |
| 3 | Hard-link count | `stat -c %h` on Unix, `fsutil hardlink list` on Windows; when neither is available the file is assumed to have one link and is replaced atomically | .NET exposes no portable link count. The fallback is the *safe* one only in the sense that the file is still cleaned correctly; the other links would not see the fix, which is why the probe is tried first |
| 4 | `--update` verification | requires a `#Requires -Version` header plus the stamp `$script:VERSION = '<X.Y.Z>';` | the reference checks a shebang plus `VERSION="<X.Y.Z>"`. Same guarantee, different file format |
| 5 | This file is **pure ASCII**, and the help it emits is not | the reference's help contains em dashes, arrows, bullets and an ellipsis; they are stored as `__EMDASH__`-style placeholders and restored by `Resolve-HelpPlaceholders` on the way out, so the emitted bytes are identical | Saving the file as UTF-8-with-BOM instead — which is what the Smart BOM Policy recommends for a non-ASCII `.ps1` — breaks `./clean-bom-senior.ps1` on Unix: a BOM in front of the shebang makes the kernel fall back to `/bin/sh`, which fails with `\xEF\xBB\xBF#!/usr/bin/env: No such file or directory`. Placeholders preserve **both** properties, and as a bonus the tool has no opinion about its own source file. `tests/ps/run-tests.ps1` asserts zero bytes above 0x7F, no BOM, a working exec bit, and that a real U+2014/U+2192 still reach stdout |
| 6 | `--help update` / `--help env` wording | names `clean-bom-senior.ps1` | `bin/bom.js` already names `bin/bom.js` in the same topics; the self-update topic describes the implementation you are holding |

Everything else — log lines, log levels and their gating, the greeting, the
summary blocks, the JSON schema and field order, display paths, exit codes and
their precedence, the decision table — is byte-identical to the reference and
verified as such.

## 6. What the port found in the reference

`has_crlf` in `clean-bom-senior.sh` was **line-based**: `grep '<CR>$'` when the
file ended in LF, an awk end-of-line test otherwise. Every line-oriented tool
defines "end of line" by the LF byte, so neither can distinguish a CR
*immediately followed by* LF from a CR that merely ends an LF-delimited line.

UTF-16LE encodes CR as `0D 00` and LF as `00 0A`, so `… 0D 00 0A` has a CR at
end-of-line but no `0D 0A` pair. Such files were flagged as modification
candidates and then reported as protected: `protectedUtf16or32` counted files
that needed nothing, and the run printed warnings about them. That contradicted
AGENTS.md invariant 3, `docs/SMART-BOM.md` §2 ("v3 matches the actual byte pair
`0D 0A`") **and `bin/bom.js`, which was already byte-exact** — so the two v3
implementations disagreed with each other, and the differential between them
never caught it because no shared fixture had that byte pattern.

Fixed in the reference (od-rendered hex, so `0d0a` *is* the byte pair and NUL
bytes are handled), and pinned by `t_policy_utf16_crlf_detection_regression` in
`tests/sh/run-tests.sh` plus its twin in `tests/node/run-tests.mjs`. Reverting
the fix turns four assertions red, which is how the test was validated.

Two further defects of the reference came out of the same area, both of them
found by running the suites on Git Bash rather than by reading the code:

- **The `grep` pre-filter silenced CRLF detection under MSYS.** `grep` is
text-mode there and strips CR bytes before matching, so the "no CR byte anywhere"
reject fired for files that were full of CRLF (measured on Git Bash 5.3.15: the
same file gives `grep -c <CR>` = 0, `grep -U` = 2, `tr -dc <CR> | wc -c` = 2).
The reference then never normalised CRLF at all on that platform, while the
README advertised Git Bash support — `--self-test` was 4 of 10 green. The
pre-filter now counts CR bytes with `tr -dc <CR> | wc -c`, which is
byte-oriented by construction and portable to BSD.
- **The version-stamp check in `do_update` refused every valid download.**
`printf '%s' "$content" | grep -q '<stamp>'` gives the pipeline the producer's
SIGPIPE under `set -o pipefail`: `grep -q` exits at the match, `printf` is killed
while the 80 KB script is still going out, and the pipeline status becomes 141,
which `if !` reads as "stamp not found". Measured as `PIPESTATUS = 141 0`. Below
a pipe buffer (64 KiB on MSYS, 16 KiB on macOS) it does not happen, which is why
v2's 23 KB script never showed it. The consumer is now `awk`, which reads to EOF.

The lesson is in `docs/TESTING.md` §"Two defects the differential found in the
reference": a fixture set is only as good as the byte patterns it contains, and
every existing UTF-16 fixture happened to include a literal `0D 0A`.

## 7. Traps hit while writing this port

Recorded because each one produced a wrong result silently, and each is now
either fixed or pinned by a test.

- **`@()` is not an empty `List`.** `$script:X = @()` creates a fixed-size
  `System.Object[]`, whose `.Add()` dies with *"Collection was of a fixed
  size"*. Every growable collection here is
  `[System.Collections.Generic.List[string]]::new()`.
- **`-split` sorts.** PowerShell's `-split` returns its match collection
  *ordered by the current culture*, so `--ext php,js` normalised to `js php`
  under a case-insensitive collation. Every split in this file goes through
  `[regex]::Matches(…, '[^\s]+')`, which preserves input order.
- **`[System.Array]::Sort` with a PowerShell comparer silently does nothing.**
  When .NET invokes a script block as a delegate, the block cannot resolve
  script-scope *functions*, so a comparer that calls one returns `$null`, every
  comparison reads as "equal", and the sort leaves the input in enumeration
  order. The failure is invisible except as wrong ordering. Sorting here is an
  LSD radix sort (`Sort-Ordinal`) that needs no delegate.
- **A comparer must return an int, not a bool.** `-ne` and `-gt` produce
  booleans; `[System.Array]::Sort` reads `$true` as `1` and `$false` as `0` and
  then sees an inconsistent comparer.
- **`Path.Combine('.', 'a.php')` returns `a.php`.** It drops the `./` that the
  v2 display contract requires, so the walk builds display and real paths by
  explicit `"$dir/$name"` concatenation. Related:
  `[IO.Directory]::EnumerateFileSystemEntries('.')` yields `src`, not `./src`.
- **PowerShell's Location is not the process CWD.** `[System.IO.*]` resolves
  relative paths against `[Environment]::CurrentDirectory`; `Push-Location`
  does not change it. The self-test sets both, and so does the test harness —
  otherwise every external helper (`stat`, `git`, `chmod`) resolves `./file`
  against the wrong directory.
- **`& $script a,b` passes one argument.** Splatting needs a variable holding a
  real array (`[string[]]$args` + `& $tool @args`). A literal comma list, and
  `@(...)` around an expression, both collapse into a single string `"a b"`.
- **An empty array returned from a function arrives as `$null`.** The pipeline
  unrolls it. Every byte-array return here is `return , $array`.
- **`Write-Host`-style concatenation as an argument.** `Write-StdErr "$B" +
  'Author:' + "$R …"` passes *three* positional arguments to a function with
  named parameters, and PowerShell fails with *"A positional parameter cannot
  be found that accepts argument '+'"*. Parenthesise the whole expression.
- **`[Console]::Out.Write` bypasses PowerShell's streams.** It is what makes
  stdout byte-exact UTF-8 regardless of `$OutputEncoding`, but it also means
  `2>&1 | Out-String` cannot capture it — the suite swaps `[Console]::SetOut` /
  `SetError` for a `StringWriter`.
- **In a double-quoted string, a backtick before `$` yields a literal `$`,
  which a regex then reads as "end of line".** Every version-stamp pattern
  written that way matched nothing. Single-quote regex sources.
- **`GetByteCount` is not a validator.** See §3.

## 8. Verifying

```bash
# the port's own suite (237 assertions, 63 groups), incl. the differential
# CLEANBOM_SKIP_DIFF=1 bounds the run: the last test drives the whole 77-case
# harness, which takes minutes on Windows. It reports SKIPPED, never a pass.
pwsh -NoLogo -NoProfile -File tests/ps/run-tests.ps1

# the byte-for-byte differential alone (77 scenarios)
python3 tests/ps/differential.py
python3 tests/ps/differential.py basic json policy_keep   # named cases

# built-in acceptance on this host
pwsh -NoLogo -NoProfile -File clean-bom-senior.ps1 --self-test

# help text still derived from the reference
python3 scripts/gen-ps-help.py --check
```

Expected: `ALL PASSED: 237 assertions`, `differential sh vs ps1: 77 identical,
0 differing`, `self-test: 10 passed, 0 failed`. The differential reports
`SKIP` (exit 0, never a silent pass) when bash, the shell reference or pwsh is
missing — on Windows that means Git Bash must be installed for it to run. The
suite finds the interpreter as `python3` first and `python` second, because a
Windows runner has only the latter; probing for `python3` alone made the
repository-consistency tests report green without running anything.

Environment variables for debugging:

| Variable | Effect |
|---|---|
| `CLEANBOM_PS_KEEPWS=1` | keep the last fixture workspace and print its path |
| `DIFF_VERBOSE=1` | print both streams in full instead of a unified diff |
| `DIFF_KEEP=1` | keep every differential workspace, with `sh.err`/`ps.err`/`sh.out`/`ps.out`/`rc.txt` |
| `DIFF_SH=…`, `DIFF_PS=…`, `DIFF_ROOT=…` | run the differential against copies elsewhere |

## 9. Limits

- **PowerShell 7.6+ only** (`#Requires -Version 7.6`). Windows PowerShell 5.1
  is refused at load time. The port uses .NET 10 APIs — notably
  `FileInfo.UnixFileMode` and `Path.ResolveFullLink` — and the reference's own
  repository convention for `.ps1` files is a 7.x target.
- **The whole file is read into memory**, capped by `--max-size` (default
  100 MB). Same trade-off as `bin/bom.js`; the reference streams through `sed`.
- **Symlinks are never followed** by the walk, and a symlink *argument* is
  resolved to its target — both per contract. Junction points and other
  reparse points on Windows are treated as links and skipped.
- **Hard-link detection depends on an external probe** (divergence 3). Without
  `stat`/`fsutil` a hard-linked file is replaced atomically and the other links
  keep the old content.
- **This file must not be fed to the tool with `--force`** or
  `--bom-policy=strip`: its BOM is load-bearing (divergence 5). Under the
  default policy the tool keeps it and says so.
