# Batch Port — `clean-bom-senior.bat`

A third implementation of the same contract, for hosts where neither Git Bash nor
PowerShell is available: Windows `cmd.exe`, using only commands that ship with
Windows 10/11.

| | `clean-bom-senior.sh` | `clean-bom-senior.ps1` | `clean-bom-senior.bat` |
|---|---|---|---|
| Host | Linux, macOS, Git Bash | Windows, PowerShell 7.6 | Windows 10/11, `cmd.exe` |
| Byte I/O | `sed`, `od` | .NET | `certutil -encodehex` / `-decodehex` |
| Parity basis | reference | byte-for-byte vs `.sh` | byte-for-byte vs `.ps1` and `.sh` |
| Test | — | `tests/differential.ps1` | `tests/bat-differential.ps1` |

Flags, detection window, report shape and exit codes are the same in all three.
Measured: 15/15 compared fixtures identical, `bat exit: 0  port exit: 0  shell exit: 0`.

```
Usage:
    clean-bom-senior.bat                      Clean the current directory recursively
    clean-bom-senior.bat --dry-run            Preview only
    clean-bom-senior.bat file1.php file2.js   Named files only
    clean-bom-senior.bat --no-bom-clear       Skip BOM removal
    clean-bom-senior.bat --no-rn-normalize    Skip CRLF normalisation
```

## 1. Why `certutil`

`cmd.exe` has no byte-oriented I/O. `set`, `set /p`, `for /f`, `echo` and
redirection all work on text, and the interpreter rewrites line endings on the way
through. BOM removal and CRLF normalisation are byte operations, so the script
works on a hexadecimal rendering instead:

```
certutil -encodehex -f <file> <hex> 4     ->  "ef bb bf 3c 3f ...", 16 values per line
certutil -decodehex      <hex> <file> 4   <-  the same format, no header
```

Both directions were verified byte for byte, including the short last line and a
file of three bytes. The remainder of this document is the filter that runs on that
hex text, because that is where all the difficulty is.

## 2. The transformation

Reproduces `sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//'`:

* values are concatenated across lines first, because a CRLF pair can straddle the
  16-byte boundary of the dump and `0d` and `0a` would never become adjacent;
* **one value is held back** as a carry. The carry is not just a buffer: the space
  that `for /f` inserts between two lines stands in for the byte the hex dump does
  not represent — a line separator. So the next line's first value is not on the
  same line as the carry, and must not be joined to it. The pair `0d` `0a` that the
  reference's `s/\r$//` removes **is** adjacent inside a line; when it is split
  across the carry it is precisely the pair that must survive;
* `0d0a` → `0a` is applied to the body **before** the carry is split off. Applied
  after, a pair landing exactly on the boundary is broken — measured on a CR at
  offset 15: the file came back with the CRLF intact instead of a single LF;
* the trailing CR at end of file is dropped, because sed's `$` matches the end of
  the buffer as well as before a newline. A lone CR inside a line survives.

Calibrated against the PowerShell port on these cases, all matching byte for byte:
a CR at every offset relative to the 16-byte boundary, CRLF at end of file, a lone
CR, a CR immediately before a CRLF, a BOM-only file that must come out empty, a
file with no final newline, and non-ASCII content.

## 3. Traps in `cmd` that were hit while writing this

These are not hypothetical. Each one produced a wrong result or a silent failure
during development, and each is now covered by the test or by a comment in the file.

**A `.bat` must have CRLF line endings.** Written with LF only, `cmd` refused to run
it: exit 255 and no output at all. Note the irony — this tool's own purpose is to
remove CRLF, so its own file must be excluded from any cleaning run.

**Parentheses in text inside `if ( … )` break the block.** `echo Would process: %F%
(Issues: %I%)` closed the block early; the remainder was then read as a command.
Escaping them as `^(` `^)` did not help either — the run died with exit 255 right
after the `PROCESSING` line. The messages that contain parentheses are therefore
printed from their own labels, never from inside a block.

**`set /a` inside an `if` block fails with `* was unexpected at this time`.**
Variables are expanded before the block is parsed, so `if not "%N%"=="" ( set /a
N+=1 )` is read as `set /a 5+=1`, where `*` is not a known operator. Every
arithmetic operation lives in its own label, called with `call`.

**Substring syntax is a no-op on an empty value.** Measured in this shell:

```
set "B=" & set "B=!B:0d0a=0a!"   ->  B=[0d0a=0a]   (the literal was assigned)
set "C=" & set "T=!C:~6!"         ->  T=[~6]        (the literal was assigned)
set "F=abc" & set "F=!F:abc=!"    ->  F=[]          (fine on a non-empty value)
```

This is the defect that broke BOM-only files twice — once through the BOM strip and
once through the carry loop. A file short enough to fit one dump line is therefore
transformed as a whole, without per-line splitting, and the carry loop has an
explicit empty-value guard.

**`for /r` matches on 8.3 short names.** The pattern `*.htm` also yields `.html`
files, because `.html` shortens to `.HTM`. This is the same trap this project
documents for `Get-ChildItem -Filter` in PowerShell. Listing both patterns made each
`.html` file appear twice — measured: one file was processed and then reported clean
in the same run. The fix is the `.htm` pattern alone plus a per-file extension check
in `:Categorize`.

**`%*` inside a called label carries the label's own arguments.** `call :Log INFO
"msg"` with `set "MSG=%*"` produced `INFO "INFO "msg""`. The message is taken from
`%~2` instead.

**`call set "X=%%A:%B%\=%%"`** is needed to strip a `%CD%` prefix when the path may
contain spaces: the replacement text is itself a variable, and `%VAR:a=b%` with a
literal filename will not do.

## 4. Deliberate divergences

Against the PowerShell port and the shell reference. Each is a decision, not an
oversight.

| # | Area | Behaviour in `.bat` | Why |
|---|---|---|---|
| 1 | Help text | ASCII only; `-` instead of `•` | a `.bat` cannot emit the reference's UTF-8 bullets reliably — it depends on the console code page. File *content* is unaffected: it never passes through the code page, only through `certutil` |
| 2 | Modification time | restored through `pwsh`, else `powershell.exe`; if neither exists, the time is not restored and the greeting says so | `cmd` cannot set a file timestamp at all, and `copy` overwrites the receiver's time. Measured: `copy /b` onto the original re-stamps it, while preserving attributes and creation time |
| 3 | Paths containing `!` | not supported | command extensions expand `!` inside the delayed-expansion blocks this script requires. The PowerShell port has no such limit |
| 4 | Performance | about 1 second per 100 KB | the transformation is a batch loop. Fine for a source tree, not for multi-megabyte files |
| 5 | NUL-byte offset | reported as the hex dump line number, not a byte offset | the exact column loop cost more than it was worth; the PowerShell port reports the byte offset |
| 6 | Timestamp format | the locale's own date string | `cmd` has no locale-free timestamp; the reference prints its locale too |
| 7 | Binary files | reported and skipped | the reference rewrites a file holding a NUL byte and corrupts it; the port and this script refuse. The test asserts this divergence for both |

## 5. Files are never left half-written

The order per file is: dump → transform → write the cleaned copy → create
`<file>.bak.<runid>` next to the original → `copy /b` the cleaned copy over the
original → restore the modification time → delete the backup. A failure at any point
leaves the original in place and reports `Failed to process file content`, which
sets exit code 1 — the same classification the reference and the port use.

`copy /b` onto the original was chosen because of what it preserves. Measured on
Windows 10.0.26300 with a file carrying `ReadOnly`, a three-day-old modification
time and a five-day-old creation time:

* `copy /b source dest` preserves `dest`'s attributes and creation time, and adopts
  `source`'s modification time;
* `move` into the same path preserves attributes and creation time, not the time;
* redirection (`echo x > dest`) preserves the file's identity but re-stamps it.

So attributes and creation time come for free, and only the modification time needs
the two PowerShell calls. A test run with all attributes set confirmed the byte
result is unaffected.

## 6. Verifying

```powershell
# batch port vs the PowerShell port vs the shell reference
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\bat-differential.ps1
```

Expected: `identical: 15 / 15 compared`, `leftover backups in the batch tree: 0`,
`batch parity verified: identical bytes against the PowerShell port`, exit code 0.
Exit code is 1 on any byte difference or exit-code difference, 2 when a required
script is missing. When Git Bash is absent the shell comparison is skipped and said
so explicitly — never silently passed.

Verified once, deliberately, that the test fails on a defect: breaking the
substitution order and dropping the trailing-CR rule produced
`[DIFF] crlf_only.css  length 23 vs 21` and exit code 1.

## 7. Limits

* `.bat` files must not be fed to this tool — or to the other two — with default
  flags: normalising CRLF would break them. Use `--no-rn-normalize`, or exclude them.
* A recursive run from a directory whose path contains `!` is refused by the
  expansion rules, not by a check in the script; the failure is a wrong run, so keep
  such trees out of scope.
* The script is Ctrl+C safe in the sense that it leaves the original intact, but a
  hard kill between the backup and the replacement can leave a
  `<file>.bak.<runid>` file behind. It is named after the run and can be deleted.
