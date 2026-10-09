# CLI Contract v3 — normative specification

One contract, three active implementations. `clean-bom-senior.sh` (bash ≥ 3.2,
GNU/BSD) is the reference; `bin/bom.js` (Node ≥ 18) is the native npm CLI;
`clean-bom-senior.ps1` (PowerShell 7.6+) is the port for hosts that have
PowerShell and no Node. All three must behave identically on every platform,
Windows included.

Two differential tests pin byte-for-byte parity on shared fixtures — output
bytes, the file set, both streams (normalised for timestamps/PIDs/paths) and
the exit code:

* `node tests/node/run-tests.mjs differential` — sh ↔ node, 8 fixtures
* `python3 tests/ps/differential.py` — sh ↔ ps1, 77 scenarios

Each implementation's own suite pins the rest of this document (`tests/sh`,
`tests/node`, `tests/ps`).

The twelve help topics are **generated** for the PowerShell port from the
reference's here-docs (`scripts/gen-ps-help.py`); CI fails on drift. Three
sentences in them are port-specific by design and are listed in
`docs/PS-PORT.md` §5.

Legacy: `clean-bom-senior.bat` implements the **v2.07 contract** and is frozen
(see `docs/BAT-PORT.md`, including §8 for why no v3 batch port ships).

---

## 1. Invocation

```
clean-bom-senior [OPTIONS] [PATH...]        (npm: `bom` / `clean-bom-senior`)
clean-bom-senior.sh [OPTIONS] [PATH...]
```

- `PATH` is a file or a directory. Directories are scanned recursively.
- No `PATH`: the current working directory is scanned recursively.
- Options are GNU-style interspersed: they may follow positional paths.
- `--` ends option parsing; a bare `-` or any unknown `-…`/`--…` token is
  `Unknown option: <token>` on stderr + exit 2 (v2 parity).
- `CLEAN_BOM_OPTS` (env) is whitespace-split and **prepended** to argv.

## 2. Flags

| Flag | Meaning |
|---|---|
| `-n`, `--dry-run` | Full analysis, no writes; implies `-v`; exit 0 |
| `-c`, `--check` | CI gate: no writes, terse one-line summary (unless `-v`), exit **10** if any file would change |
| `-f`, `--fix` | Explicit default mode |
| `-v`, `--verbose` | Per-file PROCESSING/SUCCESS lines and `Would process:` lines |
| `-q`, `--quiet` | No greeting/summary; WARN/ERROR remain |
| `--silent` | ERROR only |
| `-j`, `--json` | JSON report on **stdout** (§6) |
| `--color auto\|always\|never`, `--no-color` | Colourise stderr; honours `NO_COLOR`, `CLICOLOR_FORCE`; explicit CLI wins over env |
| `--log-file FILE` | Append plain-text log |
| `--ext LIST` | Replace the default extension set (comma/space separated, dots tolerated, case-insensitive) |
| `--add-ext LIST` | Extend the default set |
| `--exclude GLOB` | Repeatable; matched against the displayed relative path with and without the leading `./`; supports `*`, `?`, `[...]`. **Quote it in a shell** (`--exclude 'dist/*'`): unquoted, the shell expands the glob before the tool sees it. When invoking the tool from a non-MSYS program under Git Bash, pass `MSYS=noglob` in the child environment for the same reason — see `tests/ps/differential.py`. |
| `--exclude-dir NAME` | Repeatable; prune any directory component named NAME |
| `--no-default-excludes` | Lift the defaults `.git .svn .hg node_modules` (explicit `--exclude-dir`s survive) |
| `--max-size SPEC` | Per-file cap; `512K`, `10M`, `1G`, `B`, or a byte count; default `100M` |
| `--git` | Process only `git ls-files` entries (positional args become pathspecs) |
| `--bom-policy auto\|strip\|keep` | Smart BOM Policy mode (default `auto`; see `docs/SMART-BOM.md`) |
| `--sensitive-ext LIST` | Redefine the sensitive set (default `txt,csv,tsv,ps1,psm1,psd1`; `''` disables sensitivity, including for unknown extensions) |
| `--force` | Strip "may-be-required" BOMs; clean invalid-UTF-8 byte-wise. **Never** overrides hard refusals (UTF-16/32, NUL-binary) |
| `--no-bom-clear` | v2: disable BOM removal entirely |
| `--no-rn-normalize`, `--no-crlf-normalize` | v2: disable CRLF normalisation entirely |
| `--update-mtime`, `--no-keep-mtime` | Modified files get a fresh mtime (default: original atime+mtime preserved) |
| `--backup` | Keep `<file>.bak.<pid>` of every modified file |
| `--backup-dir DIR` | Implies `--backup`; copies mirror the relative tree under DIR |
| `--strict` | Exit 1 if anything was kept/protected/oversize-skipped |
| `-h`, `--help [TOPIC]` | Full help / one topic; unknown topic → exit 2. Topics: `usage options bom-policy safety exit-codes examples env ci update files json compatibility` |
| `-V`, `--version` | `<name> version <X.Y.Z>` + author + website on stdout |
| `--check-update` | Fetch `VERSION` from the update source; exit **11** if newer, 0 if not, 3 on network failure |
| `--update` | Verified self-replace (§7); npm-managed installs → instructions + exit 3 |
| `--self-test` | Built-in 10-fixture acceptance suite; exit 0/1 |
| `--completion` | completion script for the host shell on stdout (bash in `.sh`, `Register-ArgumentCompleter` in `.ps1`) |

## 3. Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (clean tree, or everything cleaned; `--dry-run` always ends here absent errors) |
| 1 | Per-file errors occurred, **or** `--strict` triggered |
| 2 | Usage error (unknown option, bad value, unknown help topic) |
| 3 | Environment (missing dependency, unusable temp/log target, update network failure, npm-managed `--update`) |
| 4 | Critical internal error |
| 10 | `--check`: at least one file needs cleaning |
| 11 | `--check-update`: newer version available |

Precedence: fatal (2/3/4) > 1 > 10/11 > 0.

## 4. Streams

- **stderr** — everything human: log lines, greeting, summary. Line format:
  `[YYYY-MM-DD HH:MM:SS LEVEL] message`, levels `INFO WARN ERROR SUCCESS
  PROCESSING`. WARN/ERROR are always visible (except `--silent` hides
  non-ERROR); INFO/summary are suppressed by `--quiet`; SUCCESS/PROCESSING
  require `-v`.
- **stdout** — machine channels only: `--json`, `--help`, `--version`,
  `--completion`. With `--json`, stdout is *pure* JSON.

## 5. Display paths

- Recursive scan of `.`: `./dir/file.ext` (v2 parity).
- Directory argument `src`: `src/dir/file.ext`.
- Explicit file arguments: echoed **verbatim** (including symlinks; a
  resolved symlink logs `Symlink argument resolved: link -> target` and the
  target is what gets cleaned).
- Node CLI normalises `\` to `/` for walked paths on Windows.
- The PowerShell port builds walked display paths by explicit `"$dir/$name"`
  concatenation: `Path.Combine('.', 'a.php')` drops the `./` the first rule
  requires, and `EnumerateFileSystemEntries('.')` yields `src`, not `./src`.

## 6. JSON schema (`--json`)

```jsonc
{
  "tool": "clean-bom-senior",
  "version": "3.0.0",
  "mode": "fix" | "dry-run" | "check",
  "startedAt": "2026-10-08T12:00:00Z",
  "durationSeconds": 0,
  "cwd": "/abs/path",
  "options": {
    "bomPolicy": "auto", "noBomClear": false, "noCrlfNormalize": false,
    "force": false, "extensions": "php css js txt xml htm html",
    "sensitiveExtensions": "txt csv tsv ps1 psm1 psd1",
    "maxSizeBytes": 104857600, "keepMtime": true
  },
  "summary": {
    "scanned": 0, "changed": 0, "wouldChange": 0, "clean": 0,
    "bomKept": 0, "bomRemoved": 0, "crlfFixed": 0,
    "protectedUtf16or32": 0, "protectedBinary": 0,
    "protectedInvalidUtf8": 0, "skippedOversize": 0, "errors": 0
  },
  "files": [
    {
      "path": "./a.php",
      "status": "changed" | "would-change" | "kept" | "protected"
              | "skipped-size" | "error",
      "encoding": "none" | "utf8-bom" | "utf16le" | "utf16be"
                | "utf32le" | "utf32be",
      "actions": ["strip-bom", "crlf-to-lf"],
      "bomKept": false,
      "reason": null | "bom-may-be-required" | "bom-policy-keep"
              | "bom-required-utf16le" | "binary-nul-bytes"
              | "invalid-utf8" | "larger than --max-size (…)"
              | "transform-failed"
    }
  ]
}
```

Clean files are counted in `summary.clean` but **not listed** in `files`
(reports stay small on big trees).

## 7. Byte semantics (normative)

1. **BOM removal** = delete bytes `EF BB BF` iff they are bytes 0–2. Nothing
   else changes; no trailing newline is ever added or removed by this step. A CR
   at EOF is therefore **kept** on this path: a file reaches it precisely because
   it has no `0D 0A` pair, so that CR is a lone CR, not a line end. (The CRLF
   step below is the only one that removes a byte at EOF.)
2. **CRLF normalisation** = delete **every** `CR` that is immediately followed by
   `LF`, plus a run of CRs before a LF, and a `CR` as the final byte of the file
   **iff** the file is being rewritten anyway (documented v2 `sed s/\r$//`
   semantics). At most one `LF` is emitted for a line, so a run of CRs collapses
   to the LF it terminated: `x CR CR LF` becomes `x LF`, not `x LF CR LF`. Lone
   CRs mid-line are preserved, and a CR at EOF with no LF after it is not a CRLF
   and never flags a file. Files with no real CRLF are never rewritten.
   Rationale for collapsing the run: the single-CR rule is not idempotent, so
   `CR CR LF` came back as `CR LF` and the tool's own post-write verification
   rejected the result — it reported an error and left a valid file untouched
   (measured on all three implementations before this was pinned by tests).
3. **Order** for both actions: BOM first, then CRLF (equivalently: one pass
   producing identical bytes).
4. **Hard refusals** (no write under any flag): UTF-16/32 BOM detected;
   NUL byte present. **Soft protections** (overridable with `--force`):
   invalid UTF-8; sensitive-extension BOM keep.
5. **Clean files are never rewritten** — byte-identical output is not enough;
   inode/mtime must not change either (tested).

## 8. Update source

- Default: `https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/refs/heads/main`
  for `VERSION`; releases are fetched from `refs/tags/v<X.Y.Z>` first.
- `CLEAN_BOM_UPDATE_URL` overrides the base (mirrors, `file://` in the bash
  implementation's tests, local HTTP in the Node tests).
- `CLEAN_BOM_GITHUB_REPO` overrides the repository slug.
- Downloaded content is verified before install: correct shebang **and** an
  embedded version stamp equal to the announced version; otherwise exit 3 and
  the running file stays byte-identical.
- Version comparison is numeric `major.minor.patch` (suffixes ignored).

## 9. Environment

`CLEAN_BOM_OPTS`, `CLEAN_BOM_GITHUB_REPO`, `CLEAN_BOM_UPDATE_URL`,
`NO_COLOR`, `CLICOLOR_FORCE`, `TMPDIR` (bash implementation: rollback copies;
Node implementation: `os.tmpdir()`).

## 10. Known implementation notes

- bash: `sed` receives the CR byte literally (BSD sed does not know `\r`);
  BOM-only stripping uses `tail -c +4` (byte copy — immune to the MSYS sed
  text-mode defect). `has_crlf` renders the file with `od -An -v -tx1` and
  searches the byte-aligned hex for `0d0a`, because no line-oriented tool can
  distinguish a CR immediately followed by LF from a CR that merely ends an
  LF-delimited line — which made UTF-16LE `0D 00 0A` a false positive. A
  `grep -q '<CR>'` pre-filter keeps CR-free files (most LF-only source) fast.
- Node: files are read whole (capped by `--max-size`); UTF-8 validity uses a
  built-in strict validator equivalent to `iconv -f UTF-8 -t UTF-8`.
- PowerShell: files are read whole (same cap); UTF-8 validity uses
  `UTF8Encoding(throwOnInvalidBytes)` through `Decoder.Convert` in chunks —
  `GetByteCount()` does **not** validate, it never runs the fallback. Sorting
  is an explicit LSD radix sort, because `[System.Array]::Sort` with a
  PowerShell script-block comparer silently no-ops (the delegate cannot resolve
  script-scope functions) and `-split` sorts by the current culture.
- All three: deep checks (NUL/validity/non-ASCII) run only for modification
  candidates; the walk skips empty files; symlinks are never followed.
