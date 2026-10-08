# Smart BOM Policy — when cleaning is needed, and when the BOM is load-bearing

> The question this document answers: **«Before stripping a BOM by default —
> is cleaning actually needed for this file, and is the BOM perhaps *required*
> by it, such that removing it would corrupt the file?»**
>
> Since v3.0.0 the tool answers this per file, by its actual bytes, before any
> write happens. Every decision is logged with a reason and appears in
> `--json` (`status` + `reason`). Nothing is modified silently, and a file
> that needs no modification is never rewritten at all (inode and timestamps
> stay intact).

---

## 1. What a BOM is, and why "just strip it" is wrong

A Byte Order Mark is the code point U+FEFF at the start of a text file. Its
meaning depends entirely on the **encoding of the file**:

| First bytes | Encoding | Is the BOM removable? |
|---|---|---|
| `EF BB BF` | UTF-8 | Sometimes — see §3. In UTF-8 the BOM carries **no** byte-order information (UTF-8 has no byte order); it is a *signature* whose usefulness depends on the consumer. |
| `FF FE` | UTF-16LE | **No.** It is the endianness marker. Without it, decoders must guess; many will misread the file. |
| `FE FF` | UTF-16BE | **No.** Same as above. |
| `FF FE 00 00` | UTF-32LE | **No.** |
| `00 00 FE FF` | UTF-32BE | **No.** |

Two corollaries the v2 tool got wrong:

1. A UTF-16/32 file whose *extension* is in the supported list (a `.txt`
   saved by Notepad as "Unicode", a `.xml` exported by a Windows tool) must
   never be fed to byte-level CRLF/BOM logic — `\r\n` inside UTF-16 is
   `0D 00 0A 00`, and "cleaning" it destroys the file.
2. Even for UTF-8, removability depends on **who reads the file**. That is
   the rest of this document.

## 2. Step zero: is cleaning needed at all?

A file is a *candidate* only when a byte-exact scan of the **whole file**
finds at least one of:

- a UTF-8 BOM in bytes 0–2 (and BOM processing is enabled), or
- at least one real `CR LF` pair (and CRLF processing is enabled).

Non-candidates are skipped without a write: mtime, inode, hard links and ACLs
stay untouched. Notes on exactness:

- v2 scanned the hex rendering of the first 1024 bytes for the substring
  `0d0a`. That both **missed** CRLFs beyond byte 1024 and **matched**
  innocent byte runs across boundaries (e.g. `30 D0 A5` contains the
  characters `0d0a`), causing needless rewrites. v3 matches the actual byte
  pair `0D 0A` anywhere in the file.
- A lone `CR` at EOF (no `LF` after it) is *not* a CRLF and never flags a
  file; CR-only "old Mac" files are left alone. (When a file *is* rewritten
  because of real CRLFs, a trailing CR at EOF is removed too — the documented
  `sed s/\r$//` semantics inherited from v2.)
- A BOM in the middle of a file is not a BOM (it is a ZWNBSP); only bytes 0–2
  count.

## 3. The decision table (evaluated top-down, first match wins)

| # | Condition (by actual bytes) | Action | `--json` reason | Override |
|---|---|---|---|---|
| 1 | size > `--max-size` | skip, counted | `larger than --max-size` | raise `--max-size` |
| 2 | UTF-16/UTF-32 BOM | **never touched** (reported only if a naive tool would have rewritten it, i.e. a real CRLF match exists) | `bom-required-utf16le` etc. | **none** — hard refusal, even `--force` |
| 3 | NUL byte anywhere | **never touched** (binary data, or BOM-less UTF-16) | `binary-nul-bytes` | **none** — hard refusal |
| 4 | content is not valid UTF-8 | not touched | `invalid-utf8` | `--force` (byte-level cleaning is safe for ASCII-compatible encodings) |
| 5 | UTF-8 BOM + **sensitive** extension + non-ASCII content | **BOM kept**, CRLF still fixed, explanation logged | `bom-may-be-required` | `--force`, `--bom-policy=strip`, `--sensitive-ext ''` |
| 6 | UTF-8 BOM + code extension, *or* pure-ASCII content | BOM removed | — | `--bom-policy=keep`, `--no-bom-clear` |
| 7 | no BOM, no CRLF | clean — no write | — | — |

### Why rule 5 exists (the "Excel/Notepad/PowerShell" rule)

For these consumers, a UTF-8 BOM is not dirt — it is the **only** reliable
signal that the file is UTF-8:

- **Microsoft Excel** opens BOM-less UTF-8 `.csv`/`.txt` as ANSI (cp1251,
  cp1252, …): `café` becomes `cafÃ©`. With the BOM it opens correctly.
- **Legacy Windows Notepad** (pre-1903) and a long tail of Win32 apps using
  `IsTextUnicode`/ANSI APIs behave the same way.
- **Windows PowerShell 5.1** parses `.ps1` files *without* a BOM as ANSI.
  A script containing non-ASCII string literals silently changes meaning or
  breaks with parse errors. (PowerShell 7+ defaults to UTF-8 — which is why
  `.ps1` files in this very repository are ASCII-only.)

Hence the default **sensitive set**: `txt csv tsv ps1 psm1 psd1`, plus *any
extension the tool does not recognise* (added via `--ext`/`--add-ext`) —
an unknown file type is treated conservatively. Sensitivity only bites when
the content after the BOM is **non-ASCII**: for a pure-ASCII file the BOM
carries zero information, every consumer reads it identically with or
without it, so removal is lossless (rule 6).

### Why rule 6 is safe for code

- **PHP** — the tool's home turf: a leading BOM is emitted as output before
  any header, breaking `header()`, sessions, redirects, JSON APIs
  ("headers already sent"), and historically interferes with
  `declare(strict_types=1)`/`namespace` tooling. Strip it.
- **JS/TS/JSON**: Node tolerates a BOM, but `JSON.parse` rejects it, shebang
  detection (`#!/usr/bin/env node`) breaks when a BOM precedes it, and some
  bundlers/minifiers mishandle it. Strip it.
- **CSS/HTML/XML/SVG**: all modern parsers accept and ignore a UTF-8 BOM;
  XML even forbids treating it as content. Stripping is safe and removes
  editor-to-editor noise. Strip it.

## 4. What the tool guarantees mechanically

- **Atomic, verified replace.** Cleaned bytes are produced in memory / in a
  temp file *in the same directory*, then **verified** (BOM gone, no CRLF
  left, nothing added — including "no trailing newline added"), and only then
  installed with `rename(2)`. A crash can never leave a half-written file,
  and a verification failure leaves the original untouched (and is reported).
- **Hard refusals cannot be forced.** Rules 2–3 reject even under `--force`;
  the tool prints what to do instead (e.g. convert UTF-16 → UTF-8 with
  `iconv` deliberately, then clean).
- **Metadata.** Permissions always transfer; ownership transfers when
  running as root; timestamps of modified files are preserved by default
  (`--update-mtime` opts out); clean files are never rewritten.
- **Hard links** (`nlink > 1`) are rewritten in place through the inode so
  links stay links; **symlink arguments** are resolved to their targets;
  the recursive walk never follows symlinks.
- **`--dry-run` / `--check`** run the identical analysis pipeline with the
  write stage disabled — what you preview is exactly what a fix run would do,
  including every keep/protect decision.

## 5. Choosing your policy

| Scenario | Flags |
|---|---|
| Safe defaults for a mixed repo (recommended) | *(none)* |
| "This repo is Linux-only, BOMs are always dirt" | `--bom-policy=strip` or `--force` |
| "Fix line endings only, never touch any BOM" | `--bom-policy=keep` or `--no-bom-clear` |
| CI gate: fail when anything needs cleaning | `--check` (exit 10) |
| CI gate: fail also on kept/protected files (strict hygiene policy) | `--check --strict` |
| Windows deployment repo with Excel-consumed `.csv` | keep defaults; the BOM in non-ASCII `.csv` is intentional |

## 6. Encoding references

- Unicode Standard §16.8 (Byte Order Mark), §2.13 (UTF-16 endianness) —
  U+FEFF is a *required* endianness signature for UTF-16/32 and an
  *optional* signature for UTF-8.
- RFC 3629 (UTF-8): the encoding has no byte order; a BOM adds nothing.
- WHATWG Encoding Standard: decoders for `utf-8` strip a leading BOM;
  `UTF-16LE/BE` without a BOM must be declared out-of-band.
- Windows PowerShell 5.1 `about_Language_Keywords`/encoding behaviour:
  scripts without a BOM are read as ANSI.
- Microsoft documentation for Excel/Notepad CSV import: UTF-8 detection is
  BOM-based.
