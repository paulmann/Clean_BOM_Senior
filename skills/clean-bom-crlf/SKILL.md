---
name: clean-bom-crlf
description: "BOM/CRLF hygiene for every text or source file created, edited, generated or packaged: strip a UTF-8 BOM and normalise CRLF to LF with Clean_BOM_Senior v3.0.0 (Smart BOM Policy), then verify by bytes. Load before delivering or committing any file that stays in a repository or ships in a build. Covers the deliberate exceptions (.bat/.cmd/.reg keep CRLF; non-ASCII .txt/.csv/.ps1/.md keep their BOM), the exit codes, and how to install the tool when it is missing."
whenToUse: "Any task that creates, edits, generates, patches or packages text files or source code — including .php, .js, .css, .html, .xml, .sh, .py, .yaml, .json, .ps1, .md, .txt — and especially before handing the result to the user or committing it."
license: MIT
---

# BOM / CRLF hygiene

## The rule, in one paragraph

**Result condition.** Every text file I created or modified in this task, and that stays
in a repository or ships in a build, ends up at **`BOM=False`, `CRLF=False`**. Exceptions
are listed in §5 and their condition is the opposite (a `.bat` must have `CRLF=True`).
Because the tool decides by actual bytes, the rule is about the *result*, not about flags:
flags exist only for the exceptions.

The tool is **Clean_BOM_Senior v3.0.0** (measured 2026-10-09). Before writing anything it
classifies the file from its real bytes and decides whether cleaning is needed at all and
whether the BOM is load-bearing (Smart BOM Policy). It never touches UTF-16/32 or binary
files and never rewrites a file that is already clean.

---

## 1. Install it if it is missing

The tool is the **same project on every platform**, but you call a different entry point:
the shell implementation on POSIX, the PowerShell implementation on Windows. Confirm it is
present first: `--version` must print `3.0.0`. If a refresh is needed, the commands below
pin commit `c799d11` (the last measured revision) — replace the pin deliberately, and update
the checksum with it, when you upgrade.

**Integrity.** `sha256(clean-bom-senior.sh)` must be
`ec1634249bff874d10b0d2999760be603153b1f0fcccc06a5f6b0be667504693`.
If it does not match, do **not** run the file — stop and report.

### Linux / macOS / WSL / Git Bash

```bash
mkdir -p "$HOME/.local/share/clean-bom"
cd "$HOME/.local/share/clean-bom"
PIN=c799d11635a22e6abccd903e534dd84a409117a2
BASE=https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/$PIN
curl -fsSL -o clean-bom-senior.sh "$BASE/clean-bom-senior.sh"
printf '%s  %s\n' ec1634249bff874d10b0d2999760be603153b1f0fcccc06a5f6b0be667504693 clean-bom-senior.sh | sha256sum -c -
chmod +x clean-bom-senior.sh
bash clean-bom-senior.sh --version
```

On macOS `sha256sum` is not installed; use `shasum -a 256 clean-bom-senior.sh` and compare
the value by eye. On Linux the flag is `--version`; no extra runtime is required beyond
`bash`, `sed`, `awk`, `od`, `tr`, `find` — all present in a base system.

### Windows — PowerShell 7+ is required

The PowerShell implementation needs **PowerShell 7.0 or newer** (PSEdition Core). It is
pure .NET byte I/O, so no Git Bash, `sed` or `certutil` is involved. Check it first:

```powershell
$PSVersionTable.PSVersion        # must be 7.x or higher; 5.1 will NOT work
```

If PowerShell 7 is missing, install it (both commands below are per-user and need no
administrator rights):

```powershell
winget install --id Microsoft.PowerShell --scope user
# or headless:
iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI"
```

Then fetch the two files Windows needs — the PowerShell implementation (cleaning) and the
Node implementation (a working fallback, and the checker used by the suites):

```powershell
$dst  = 'C:\AutoClaw\Clean_BOM_Senior'
$base = 'https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/c799d11635a22e6abccd903e534dd84a409117a2'
New-Item -ItemType Directory -Force $dst, "$dst\bin" | Out-Null
Invoke-WebRequest -Uri "$base/clean-bom-senior.ps1" -OutFile "$dst\clean-bom-senior.ps1"
Invoke-WebRequest -Uri "$base/bin/bom.js"          -OutFile "$dst\bin\bom.js"
Invoke-WebRequest -Uri "$base/VERSION"             -OutFile "$dst\VERSION"
pwsh -NoLogo -NoProfile -File "$dst\clean-bom-senior.ps1" --version
```

`Invoke-WebRequest` keeps `-UseBasicParsing` only as an accepted-but-pointless parameter in
PowerShell 7 (verified present in 7.6.6); it is omitted here on purpose.

If neither PowerShell 7 nor Node can be installed, say so plainly and do not fake the
result — cleaning "by eye" is worse than an unfound BOM.

---

## 2. Which entry point on which platform

| Platform | Command |
|---|---|
| Linux, macOS, WSL, Git Bash | `bash clean-bom-senior.sh --quiet <files…>` |
| Windows, PowerShell 7+ | `pwsh -NoLogo -NoProfile -File clean-bom-senior.ps1 --quiet <files…>` |
| Any host with Node ≥ 18 | `node bin/bom.js --quiet <files…>` |
| Any of the above, no writing | `--check` → exit `0` clean, `10` needs cleaning |

All three are one contract: sh↔node byte parity is asserted on 8 fixtures, sh↔ps1 on 77
scenarios. Pick the one that exists on the host; do not mix them inside one run.

---

## 3. How to call it

* **Explicit file paths only.** With no arguments it walks the *current directory* and
  rewrites files that have nothing to do with the task.
* A **directory argument works**, but only the default extension set is picked up
  (`php css js txt xml htm html`). Anything else is silently skipped — pass explicit paths,
  or `--add-ext <list>`.
* One call accepts several files. Repeated runs are idempotent.
* `--quiet` for scripted use; add `--json` when a machine-readable report is wanted.

---

## 4. What the tool does (measured on v3.0.0)

| Situation | Result |
|---|---|
| UTF-8 BOM + code (`php js css html xml sh py yaml json`) | BOM removed, CRLF→LF |
| UTF-8 BOM + pure-ASCII content (any extension) | BOM removed |
| BOM + non-ASCII in `txt csv tsv ps1 psm1 psd1` **and any unknown extension (incl. `md`)** | **BOM kept deliberately** (Excel and PowerShell 5.1 read such a file only with a BOM); CRLF still normalised |
| the same + `--bom-policy=strip` or `--force` | BOM removed |
| CRLF without BOM (file passed explicitly) | CRLF→LF |
| UTF-16/32 BOM (`FF FE`, `FE FF`, `FF FE 00 00`, `00 00 FE FF`) | **never touched**, even with `--force` |
| NUL bytes anywhere | **never touched**, even with `--force` |
| invalid UTF-8 | untouched by default; `--force` enables byte-level cleaning |
| file already clean | **never rewritten** — inode and mtime unchanged |

---

## 5. When NOT to run it (or to run it in a special form)

* **`.bat`, `.cmd`, `.reg` — CRLF is mandatory.** cmd.exe refuses to run an LF-only batch
  file (exit 255). Measured: an explicit path turns `@echo off\r\n` into `@echo off\n`, which
  breaks the file. If such a file needs its BOM removed, the only safe form is
  `--no-rn-normalize` (measured: BOM gone, CRLF intact).
* **Binary and asset files** (images, archives, fonts, `.exe`, `.dll`) — not this tool.
* **UTF-16/32 and NUL-containing files** — not "forbidden" but "the tool refuses": they need
  `iconv`, not line-ending work.
* **Invalid UTF-8** — `--force` is a deliberate decision (a cp1251/latin-1 file), not a
  reflex.
* **Non-ASCII in a sensitive extension** — there the BOM is a feature. Remove it knowingly:
  a file with a shebang (`#!/usr/bin/env pwsh`) that must also run on Unix has to be ASCII
  without a BOM, otherwise the kernel reads the BOM as magic and runs `/bin/sh`.

---

## 6. Verify by bytes, not by "looks fine"

PowerShell:

```powershell
$b = [IO.File]::ReadAllBytes('<file>')
$bom  = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
$crlf = ([IO.File]::ReadAllText('<file>')) -match "`r`n"
"BOM=$bom CRLF=$crlf"     # expected False False, except for §5 exceptions
```

POSIX:

```bash
head -c 3 '<file>' | od -An -tx1 | tr -d ' \n'   # must not be efbbbf
grep -c $'\r' '<file>'                           # must be 0
```

For the §5 exceptions the expectation is **inverted**: `.bat`/`.cmd` must show
`CRLF=True`; a non-ASCII `.ps1`/`.txt`/`.md` must show `BOM=True`, and that is not a defect.

---

## 7. Exit codes (so success is not inferred from silence)

| Code | Meaning |
|---|---|
| 0 | success (tree clean, or everything cleaned) |
| 1 | finished, but some files had processing errors; `--strict` saw kept/protected/skipped |
| 2 | invalid command-line usage |
| 3 | environment problem (missing dependency, unusable temp dir, network, `--update` on an npm install) |
| 4 | critical internal error |
| 10 | `--check`: at least one file needs cleaning |
| 11 | `--check-update`: a newer version exists |

Precedence when several apply: 2/3/4 > 1 > 10/11 > 0.

---

## 8. What counts as a failure of this skill

* Reporting success **without** the byte check in §6.
* Writing to a file that was already clean (the tool does not do it; a changed mtime is a
  defect, not a detail).
* Running with no arguments, or against a directory whose files are outside the default
  extension set — a silent no-op that still reads as "done".
* Passing `.bat`/`.cmd` to a plain call — it breaks execution of the file.
* Removing the BOM from a non-ASCII `.ps1`/`.txt`/`.md` without a deliberate decision.

---

## 9. Where to pin this rule in an agent

The rule belongs in **both** places, and they do different jobs:

1. **A skill** (this file) — the full procedure: install, per-platform entry point,
   exceptions, verification. This is the portable form; drop the directory into the
   skill root your agent scans, e.g. `$DSH_HOME/skills/clean-bom-crlf/` or
   `~/.claude/skills/clean-bom-crlf/`, or a project-local `.agent/skills/clean-bom-crlf/`.
2. **The agent's always-loaded rules** (its system prompt / `AGENTS.md`) — a short pointer,
   because a skill is only consulted when the agent thinks to look, while the rules file is
   present in every session. One sentence is enough; the full text above lives here.

Pointer sentence to paste into the rules file:

> Any task that touches code or text files (create, edit, generate, patch, package:
> `.php .js .css .html .xml .sh .py .yaml .json .ps1 .md .txt` …) — load and follow the
> `clean-bom-crlf` skill before delivering the result.

Optional tool-native form, where the agent has a skill loader: "call the skill `clean-bom-crlf`
first, then work by it".

Repository: <https://github.com/paulmann/Clean_BOM_Senior> · Policy details:
`docs/SMART-BOM.md` · Normative contract: `docs/CLI-CONTRACT.md`
