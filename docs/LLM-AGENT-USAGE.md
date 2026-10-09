# Using the tool from an LLM agent

This document is for agents and for people who wire the tool into one. It answers three
questions: **how** to give an agent the rule, **when** the rule applies, and **which**
implementation to call on which platform. Everything here was measured on v3.0.0
(2026-10-09) against the tool in this repository.

- Short, copy-paste prompt for another agent: [`PROMPT-OTHER-HARNESS.md`](PROMPT-OTHER-HARNESS.md)
- Portable skill file: [`../skills/clean-bom-crlf/SKILL.md`](../skills/clean-bom-crlf/SKILL.md)
- Policy details: [`SMART-BOM.md`](SMART-BOM.md) · Normative contract: [`CLI-CONTRACT.md`](CLI-CONTRACT.md)

## 1. Put the rule in two places, not one

| Where | What goes there | Why there |
|---|---|---|
| **A skill** (`SKILL.md`) | the full procedure: install, per-platform entry point, the decision table, the exceptions, byte-level verification, exit codes | a skill is loaded when the task actually touches files, so the long text costs nothing until it is needed |
| **The agent's always-loaded rules** (system prompt, `AGENTS.md`, `CLAUDE.md`…) | one pointer sentence naming the skill | an always-present line is what makes the agent *think* to load the skill; a skill nobody loads is decoration |

A skill alone is unreliable (nothing reminds the agent it exists); a rule alone is expensive
and duplicated. Together they behave like a loader plus a check.

Ready-made skill: [`skills/clean-bom-crlf/SKILL.md`](../skills/clean-bom-crlf/SKILL.md).
Copy that **directory** (the skill is a directory with `SKILL.md` inside) into the skill root
your agent scans:

```
$DSH_HOME/skills/clean-bom-crlf/SKILL.md     # DeepSeek Harness
~/.claude/skills/clean-bom-crlf/SKILL.md     # Claude Code / compatible agents
<repo>/.agent/skills/clean-bom-crlf/SKILL.md # project-local, travels with the repo
```

If an agent has no skill mechanism at all, paste the body of `SKILL.md` into its rules file as
a section — the content does not depend on the loader.

Pointer sentence for the rules file:

> Any task that touches code or text files (create, edit, generate, patch, package:
> `.php .js .css .html .xml .sh .py .yaml .json .ps1 .md .txt` …) — load and follow the
> `clean-bom-crlf` skill before delivering the result.

## 2. When the rule applies

Roughly: **every file that stays behind.** Create, edit, generate, patch or package a text
file, and it must end at `BOM=False`, `CRLF=False` before it is handed over or committed —
except the deliberate exceptions in §4 below.

Two failure modes are worth naming, because both look like success:

- running the tool **with no arguments** — it then walks the current directory and can rewrite
  files unrelated to the task;
- running it against a **directory** while the files have an extension outside the default set
  (`php css js txt xml htm html`) — those files are skipped silently, and the report still
  reads as "done".

## 3. Which implementation to call

The project ships one contract and three implementations. Use the one that exists on the host:

| Platform | Command | Notes |
|---|---|---|
| Linux, macOS, WSL, Git Bash | `bash clean-bom-senior.sh --quiet <files…>` | POSIX shell, GNU **and** BSD userland; no extra runtime |
| Windows | `pwsh -NoLogo -NoProfile -File clean-bom-senior.ps1 --quiet <files…>` | **requires PowerShell 7.0+** (Core). Pure .NET byte I/O — no Git Bash, `sed` or `certutil` needed |
| Any host with Node ≥ 18 | `node bin/bom.js --quiet <files…>` | handy fallback on Windows when PowerShell 7 is unavailable |
| Any, without writing | `--check` | exit `10` = something needs cleaning, `0` = clean |

Parity is asserted, not assumed: sh↔node on 8 fixtures, sh↔ps1 on 77 scenarios.

## 4. What the tool decides (measured)

| Situation | Result |
|---|---|
| UTF-8 BOM + code (`php js css html xml sh py yaml json`) | BOM removed, CRLF→LF |
| UTF-8 BOM + pure-ASCII content (any extension) | BOM removed |
| BOM + non-ASCII in `txt csv tsv ps1 psm1 psd1` **and any unknown extension (incl. `md`)** | **BOM kept deliberately** — Excel and PowerShell 5.1 read such a file only with a BOM; CRLF still normalised |
| the same + `--bom-policy=strip` / `--force` | BOM removed |
| UTF-16/32 BOM, or NUL bytes anywhere | **never touched**, even with `--force` |
| invalid UTF-8 | untouched by default; `--force` = byte-level cleaning |
| file already clean | **never rewritten** — inode and mtime unchanged |

**Exceptions — the condition is inverted there:**

- `.bat`, `.cmd`, `.reg` must keep CRLF (cmd.exe will not run an LF-only batch file). A plain
  call breaks them; if the BOM must go, the only safe form is `--no-rn-normalize`
  (measured: BOM removed, CRLF intact).
- non-ASCII `txt`/`csv`/`ps1`/`md` keep their BOM by policy. Remove it knowingly — e.g. a
  `#!/usr/bin/env pwsh` script that must also run on Unix has to be ASCII without a BOM,
  otherwise the kernel reads the BOM as magic and runs `/bin/sh`.

## 5. Verify by bytes — an agent's own report is not evidence

PowerShell:

```powershell
$b = [IO.File]::ReadAllBytes('<file>')
$bom  = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
$crlf = ([IO.File]::ReadAllText('<file>')) -match "`r`n"
"BOM=$bom CRLF=$crlf"     # expected False False except for the exceptions above
```

POSIX:

```bash
head -c 3 '<file>' | od -An -tx1 | tr -d ' \n'   # must not be efbbbf
grep -c $'\r' '<file>'                           # must be 0
```

Exit codes: `0` success · `1` per-file errors or `--strict` findings · `2` usage ·
`3` environment · `4` internal · `10` `--check` found dirt · `11` update available.
Precedence: 2/3/4 > 1 > 10/11 > 0.

## 6. Installing the tool for an agent that does not have it

The repository is **public**, so an agent can fetch a pinned revision and verify it. Pin a
commit instead of `main` — otherwise the instruction silently ages:

```bash
PIN=c799d11635a22e6abccd903e534dd84a409117a2
curl -fsSL -o clean-bom-senior.sh \
  "https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/$PIN/clean-bom-senior.sh"
printf '%s  %s\n' ec1634249bff874d10b0d2999760be603153b1f0fcccc06a5f6b0be667504693 clean-bom-senior.sh | sha256sum -c -
chmod +x clean-bom-senior.sh
```

On Windows fetch `clean-bom-senior.ps1` and `bin/bom.js` the same way and make sure
PowerShell 7+ is present (`$PSVersionTable.PSVersion` must be 7.x). If the checksum does not
match, do not run the file. If there is no network, say so — do not imitate success.

## 7. What the agent should report back

An agent that claims the rule is installed should return: the path of the skill file and of
the rules file, confirmation that both are UTF-8 without BOM and LF-only, the first lines of
the rules section, and the output of `--version`. Four short facts; without them "the rule is
installed" is unverifiable.
