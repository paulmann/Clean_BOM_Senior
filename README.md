# Clean BOM Senior 🧹✨

[![Version](https://img.shields.io/badge/version-2.07.0-blue.svg)](https://github.com/paulmann/Clean_BOM_Senior)
[![npm version](https://img.shields.io/npm/v/clean-bom-senior.svg?color=red)](https://www.npmjs.com/package/clean-bom-senior)
[![npm downloads](https://img.shields.io/npm/dm/clean-bom-senior.svg?color=brightgreen)](https://www.npmjs.com/package/clean-bom-senior)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-orange.svg)](https://www.gnu.org/software/bash/)
[![PowerShell](https://img.shields.io/badge/powershell-7.6-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)]()

> **A production-ready utility for safely removing invisible UTF-8 BOM and Windows CRLF from source code files**

Clean BOM Senior detects and removes invisible UTF-8 Byte Order Marks (BOM) and Windows CRLF line endings that cause critical errors in PHP, JavaScript, CSS and other source code files.

It ships as **three implementations of one contract**: a POSIX shell script for Linux, macOS
and Unix (also the npm CLI), a PowerShell 7.6 port for Windows hosts without Git Bash, and a
batch port for hosts without PowerShell either. Same flags, same detection rules, same
output, same exit codes — verified byte for byte by differential tests.

---

## ⚡ Three Implementations, One Contract

| | `clean-bom-senior.sh` | `clean-bom-senior.ps1` |
|---|---|---|
| **Language** | POSIX shell (v2.07.0, 687 lines) | PowerShell 7.6 (PSEdition Core) |
| **Platforms** | Linux, macOS, Unix-like | Windows, Linux, macOS (anywhere `pwsh` 7.6 runs) |
| **Dependencies** | `find sed od grep stat mv cp touch chown chmod` | none beyond PowerShell 7.6 |
| **Flags** | `-h -v -n -V --no-bom-clear --no-rn-normalize --` | identical, plus PowerShell-style aliases |
| **Exit codes** | `0 1 2 3` | `0 1 2 3` |
| **Output format** | banner, `[timestamp LEVEL]` log lines, summary | identical |
| **Metadata kept** | uid/gid/mode/timestamps | ACL, attributes, creation time, timestamps |
| **Parity** | reference implementation | verified: 14 / 14 fixtures identical |

Quick start for both:

```bash
# Linux / macOS / Unix, or the npm CLI
./clean-bom-senior.sh --dry-run --verbose
bom --dry-run --verbose
```

```powershell
# Windows, PowerShell 7.6+
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --dry-run --verbose
```

Details: [Installation](#-installation) · [Usage](#-usage) · [PowerShell 7.6 Port](#-powershell-76-port) · [Verifying Parity](#-verifying-parity)

---

## ⚡ Quick Start

**Yes, everything is executable.** The install chain handles it automatically:
- `clean-bom-senior.sh` — gets `chmod +x` applied if missing
- `bom` — symlink inherits the executable bit from its target; no separate `chmod` needed
- `clean-bom-senior.ps1` — launched through `pwsh -File`, so no executable bit is involved

***


## Installation

### Install via npm

```bash
# Install globally from npm
npm install -g clean-bom-senior

# Verify the CLI is available
bom --help
```

The npm package installs the `bom` CLI globally and runs a post-install step to ensure the bundled shell script is executable on supported systems. The package also ships `clean-bom-senior.ps1` as-is: an npm install on Windows gives you both implementations, and the PowerShell port is invoked directly.

### Install from source

```bash
# Clone the repository
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior

# Install globally as `bom` — resolves absolute path, ensures executable bit, creates symlink
src="$(readlink -f ./clean-bom-senior.sh 2>/dev/null || realpath ./clean-bom-senior.sh 2>/dev/null)" \
  && [ -f "$src" ] \
  && { [ -x "$src" ] || chmod +x "$src"; } \
  && sudo ln -sf "$src" /usr/local/bin/bom \
  && echo "✅ Installed: $(which bom) → $src"
```

> The install command automatically resolves the absolute path, grants the executable
> bit to the source script if missing, and creates the `/usr/local/bin/bom` symlink.
> Since a symlink inherits permissions from its target, both `clean-bom-senior.sh`
> and `bom` will be executable upon completion.

### Install the PowerShell port (Windows)

Nothing to install — the port is a single file with no dependencies beyond PowerShell 7.6.

```powershell
# Check the interpreter version first: 7.6 or newer is required
$PSVersionTable.PSVersion          # → 7.6.x
$PSVersionTable.PSEdition          # → Core

# Download it next to your project (or into a tools\ folder)
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.ps1' `
                  -OutFile .\tools\clean-bom-senior.ps1

# Run it
pwsh -NoLogo -NoProfile -NonInteractive -File .\tools\clean-bom-senior.ps1 --help
```

Into an npm project (the `.ps1` is part of the package):

```powershell
npm install --save-dev clean-bom-senior
node_modules\.bin\..\clean-bom-senior\clean-bom-senior.ps1 --version   # file is in the package root
```

Or simply keep the file and call it through `pwsh` from your own scripts — see
[Windows Automation](#-windows-automation).

> **Execution policy.** Launching with `pwsh -File` needs no policy change. If you
> instead dot-source the script into an interactive session, a restricted policy may
> block it: use `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ...`.
> Execution policy is a Windows-only concept and has no effect on Linux or macOS.

## Verify Installation

```bash
which bom               # → /usr/local/bin/bom
ls -la $(which bom)     # → lrwxrwxrwx ... /usr/local/bin/bom -> /path/to/clean-bom-senior.sh
```

```powershell
(Get-Command pwsh).Source        # → C:\Program Files\PowerShell\7\pwsh.exe
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --version
# → clean-bom-senior.ps1 version 2.07.0
```

## Usage

```bash
# Recursively clean all files in the current directory
bom

# Dry run — preview changes without modifying any files
bom --dry-run

# Verbose — print detailed per-file processing log
bom --verbose

# Target specific files
bom file1.php file2.js config.xml

# Remove BOM signatures only — skip CRLF normalization
bom --no-rn-normalize

# Normalize CRLF line endings only — skip BOM removal
bom --no-bom-clear

# Dry run with verbose output, skipping BOM removal
bom --dry-run --no-bom-clear --verbose
```

```powershell
# Recursively clean all files in the current directory
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1

# Dry run — preview changes without modifying any files
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --dry-run

# Verbose — print detailed per-file processing log
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --verbose

# Target specific files (relative paths are resolved against the working directory)
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 file1.php file2.js config.xml

# Remove BOM signatures only — skip CRLF normalization
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --no-rn-normalize

# Normalize CRLF line endings only — skip BOM removal
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --no-bom-clear

# Dry run with verbose output, skipping BOM removal
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --dry-run --no-bom-clear --verbose
```

## Uninstall

```bash
sudo rm /usr/local/bin/bom && echo "✅ bom removed from PATH"
```

```powershell
Remove-Item -LiteralPath .\clean-bom-senior.ps1          # the port is a single file
npm uninstall -g clean-bom-senior                        # if it came from npm
```

***

### What the install chain does, step by step

| Step | Command fragment | Effect |
|------|-----------------|--------|
| 1 | `readlink -f \|\| realpath` | Resolves the absolute path (cross-distro fallback) |
| 2 | `[ -f "$src" ]` | Aborts if the file does not exist |
| 3 | `[ -x "$src" ] \|\| chmod +x` | Grants executable bit if not already set |
| 4 | `sudo ln -sf` | Creates (or replaces) the global symlink |
| 5 | Symlink inheritance | `bom` is executable automatically — no extra `chmod` needed |



## 📋 Table of Contents

- [⚡ Three Implementations, One Contract](#-three-implementations-one-contract)
- [🚨 Why Clean BOM Senior?](#-why-clean-bom-senior)
  - [The Hidden Problem](#the-hidden-problem)
  - [Real-World Impact](#real-world-impact)
- [✨ Key Features](#-key-features)
  - [🛡️ Enterprise-Grade Safety](#️-enterprise-grade-safety)
  - [🎯 Intelligent Processing](#-intelligent-processing)
  - [📊 Comprehensive Reporting](#-comprehensive-reporting)
  - [🔄 DevOps Integration](#-devops-integration)
- [📋 Installation & Usage](#-installation--usage)
  - [System Requirements](#system-requirements)
  - [Installation Options](#installation-options)
  - [Command Line Options](#command-line-options)
  - [Usage Examples](#usage-examples)
- [🐚 PowerShell 7.6 Port](#-powershell-76-port)
  - [Why a Second Implementation](#why-a-second-implementation)
  - [Requirements](#requirements)
  - [Running the Port](#running-the-port)
  - [Command-Line Options](#command-line-options-1)
  - [Usage Examples](#usage-examples-1)
  - [What It Changes, Byte for Byte](#what-it-changes-byte-for-byte)
  - [Safety Model](#safety-model)
  - [Output and Exit Codes](#output-and-exit-codes)
  - [Comprehensive Statistics](#comprehensive-statistics)
  - [Deliberate Divergences from the Shell Original](#deliberate-divergences-from-the-shell-original)
  - [Verifying Parity](#-verifying-parity)
  - [Windows Automation](#-windows-automation)
- [🪟 Batch Port (cmd.exe)](#-batch-port-cmdexe)
  - [Why certutil](#why-certutil)
  - [Batch Port Divergences](#batch-port-divergences)
  - [Verifying the Batch Port](#verifying-the-batch-port)
- [🏗️ Advanced Features](#️-advanced-features)
  - [File Preservation Guarantees](#file-preservation-guarantees)
  - [Comprehensive Statistics](#comprehensive-statistics-1)
  - [Supported File Types](#supported-file-types)
  - [Error Handling](#error-handling)
- [🔗 DevOps Integration](#-devops-integration-1)
  - [CI/CD Pipeline Integration](#cicd-pipeline-integration)
  - [Git Hooks](#git-hooks)
  - [Docker Integration](#docker-integration)
- [🏢 Team & Enterprise Usage](#-team--enterprise-usage)
  - [Project Setup](#project-setup)
  - [Team Workflow](#team-workflow)
  - [IDE Integration](#ide-integration)
- [🔍 Troubleshooting](#-troubleshooting)
  - [Common Issues](#common-issues)
  - [PowerShell-Specific Issues](#powershell-specific-issues)
  - [Debugging Commands](#debugging-commands)
  - [Recovery Procedures](#recovery-procedures)
- [🤝 Contributing](#-contributing)
  - [Development Setup](#development-setup)
  - [Contribution Guidelines](#contribution-guidelines)
  - [Code Standards](#code-standards)
- [📄 License](#-license)
- [👨‍💻 Author & Support](#-author--support)
  - [Getting Help](#getting-help)
  - [Related Projects](#related-projects)
- [🎯 Roadmap](#-roadmap)
  - [Upcoming Features](#upcoming-features)
  - [Version History](#version-history)

## 🚨 Why Clean BOM Senior?

### The Hidden Problem

UTF-8 BOM markers are **invisible** 3-byte sequences (`EF BB BF`) that can break your code:

```php
<?php
// ⚠️ This file has invisible BOM - will cause FATAL ERROR!
namespace MyApp\Controllers;  // Fatal error: Namespace declaration statement has to be...
```

```javascript
// ⚠️ BOM here causes encoding issues
import { Component } from 'react';  // Potential parsing errors
```

### Real-World Impact

- **PHP Fatal Errors**: BOM before `namespace` or `declare(strict_types=1)` statements
- **JavaScript Parsing Issues**: BOM can break module imports and cause encoding problems  
- **CSS Rendering Problems**: BOM may cause unexpected styling behavior
- **Cross-Platform Conflicts**: Mixed CRLF/LF line endings between Windows and Unix systems
- **CI/CD Pipeline Failures**: Automated builds failing due to encoding issues

## ✨ Key Features

### 🛡️ **Enterprise-Grade Safety**
- **Atomic Operations**: Changes are applied atomically or rolled back completely
- **Automatic Backups**: Creates backup copies during processing with automatic cleanup
- **File Integrity**: Preserves original file ownership, permissions, and timestamps
- **Error Recovery**: Comprehensive rollback mechanism on any failure

### 🎯 **Intelligent Processing**
- **Smart Detection**: Only processes files that actually contain BOM or CRLF issues
- **Multi-Format Support**: PHP, CSS, JS, TXT, XML, HTM, HTML files
- **Size Limits**: Built-in protection against processing oversized files (100MB default)
- **Extension Filtering**: Configurable file extension support

### 📊 **Comprehensive Reporting**
- **Detailed Statistics**: Complete breakdown of processed files by type and issues fixed
- **Progress Tracking**: Real-time logging with timestamps and color coding
- **Dry-Run Mode**: Preview operations without making changes
- **Error Classification**: Categorized error reporting with resolution suggestions

### 🔄 **DevOps Integration**
- **CI/CD Ready**: Perfect for integration into build pipelines
- **Git Hooks**: Ideal for pre-commit hooks and automated workflows
- **Cross-Platform**: Linux, macOS and Unix via the shell script; Windows via the PowerShell port
- **No Dependencies**: Pure bash script with standard Unix utilities only; the port needs nothing beyond PowerShell 7.6

## 📋 Installation & Usage

### System Requirements

**Shell implementation:**

- **Shell**: Bash 4.0+ (or compatible: sh, dash)
- **OS**: Linux, macOS, Unix-like systems
- **Tools**: Standard utilities (`find`, `sed`, `od`, `grep`, `stat`, `mv`, `cp`, `touch`, `chown`, `chmod`)
- **Permissions**: Write access to target directory and temp folder

**PowerShell implementation:**

- **PowerShell**: 7.6 or newer, `PSEdition Core` (`pwsh`)
- **OS**: Windows 10/11, Windows Server 2016+, or any platform with `pwsh` 7.6
- **Tools**: none — no external command is invoked
- **Permissions**: write access to the target directory and to the temp directory

### Installation Options

#### Option 1: Direct Download
```bash
wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh
./clean-bom-senior.sh --help
```

#### Option 2: Git Clone
```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
chmod +x clean-bom-senior.sh
```

#### Option 3: Global Installation
```bash
# Install globally (requires sudo)
sudo curl -o /usr/local/bin/bom https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
sudo chmod +x /usr/local/bin/bom

# Now use anywhere with simple command
bom --help
bom --dry-run
```

#### Option 4: User Alias
```bash
# Add to ~/.bashrc or ~/.bash_profile
alias bom='/path/to/clean-bom-senior.sh'

# Reload shell configuration
source ~/.bashrc

# Use the alias
bom --verbose
```

#### Option 5: PowerShell Download (Windows)
```powershell
New-Item -ItemType Directory -Path .\tools -Force | Out-Null
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.ps1' `
                  -OutFile .\tools\clean-bom-senior.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\tools\clean-bom-senior.ps1 --help
```

#### Option 6: PowerShell Function (Windows, per-user)
```powershell
# Add to your PowerShell profile
function bom { pwsh -NoLogo -NoProfile -NonInteractive -File "$env:USERPROFILE\tools\clean-bom-senior.ps1" @args }

# Reload the profile
. $PROFILE

# Use it like the shell CLI
bom --dry-run --verbose
```

> The port is a script, not a module, so it is also perfectly valid to call it
> directly: `& .\clean-bom-senior.ps1 --version`.


### Command-Line Options

| Option                  | Description                                    |
|-------------------------|------------------------------------------------|
| `-h, --help`            | Show help message and exit                     |
| `-v, --verbose`         | Enable detailed output                         |
| `-n, --dry-run`         | Preview mode: show what would change           |
| `-V, --version`         | Show script version info                       |
| `--no-bom-clear`        | **NEW**: Do not remove BOM                     |
| `--no-rn-normalize`     | **NEW**: Do not normalize CRLF (`\r\n`) lines  |

Both implementations accept this exact set. The PowerShell port additionally accepts
PowerShell-style spellings of the same flags — see
[Command-Line Options](#command-line-options-1) in the port section.


### Usage Examples

#### Basic Usage
```bash
# Clean all supported files in current directory and subdirectories
./clean-bom-senior.sh

# Clean with verbose output
./clean-bom-senior.sh --verbose

# Preview changes without modifying files
./clean-bom-senior.sh --dry-run

# Disable BOM removal (keep BOM, fix CRLF)
./clean-bom-senior.sh --no-bom-clear

# Disable CRLF normalization (keep CRLF, remove BOM)
./clean-bom-senior.sh --no-rn-normalize

# Both options
./clean-bom-senior.sh --no-bom-clear --no-rn-normalize

# Dry run shows what "would" (or "would not") be done under current flags
./clean-bom-senior.sh --dry-run --no-bom-clear
```

#### Specific Files
```bash
# Clean specific files
./clean-bom-senior.sh config.php script.js style.css

# Clean files with verbose logging
./clean-bom-senior.sh --verbose src/Controller.php src/Model.php

# Preview specific files
./clean-bom-senior.sh --dry-run templates/*.php
```

#### Directory Processing
```bash
# Clean entire project (recursive)
./clean-bom-senior.sh

# Clean specific directory with verbose output
./clean-bom-senior.sh --verbose src/

# Preview entire project changes
./clean-bom-senior.sh --dry-run --verbose
```

> **Directories as arguments are not supported.** `./clean-bom-senior.sh src/` looks
> for a *file* named `src/`, reports `File not found` and cleans nothing. Change into
> the directory instead, or list the files explicitly.

## 🐚 PowerShell 7.6 Port

> A third implementation exists for hosts without PowerShell and without Git Bash: see
> [Batch Port (cmd.exe)](#-batch-port-cmdexe).

### Why a Second Implementation

BOM and CRLF break PHP and JavaScript the same way on Windows, but the shell script cannot
help there: it needs `find`, `sed`, `od`, `stat`, `chown` and a POSIX temp directory.
Git Bash is a large dependency to install just to strip three bytes from a file. The port
removes that dependency: one `.ps1` file, PowerShell 7.6, no external process.

It is a **behavioural port**, not a rewrite. Everything a pipeline can observe — flags,
detection rules, log lines, summary layout, exit codes — matches the shell original. The
handful of places where it deliberately differs are listed in
[Deliberate Divergences](#deliberate-divergences-from-the-shell-original), and each one is
asserted by the test suite rather than left to trust.

### Requirements

| Requirement | Value |
|---|---|
| Interpreter | PowerShell **7.6+** (`PSEdition Core`), i.e. `pwsh` |
| Enforced by | `#Requires -Version 7.6` and `#Requires -PSEdition Core` at the top of the file |
| Strictness | `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'` |
| External tools | none |
| Profile | not needed — the script is self-contained and expects to be run with `-NoProfile` |
| Windows PowerShell 5.1 | **not supported and not tested** |

Verify the interpreter before blaming the script:

```powershell
$PSVersionTable.PSVersion     # 7.6.x
$PSVersionTable.PSEdition     # Core
```

### Running the Port

```powershell
# Canonical invocation: no logo, no profile, non-interactive
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --dry-run

# Explicit file arguments
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 .\config.php .\assets\app.js

# From an existing PowerShell session (no second process)
& .\clean-bom-senior.ps1 --version

# Absolute path, when the script lives outside the project
pwsh -NoLogo -NoProfile -NonInteractive -File 'C:\tools\clean-bom-senior.ps1' --verbose
```

```powershell
# Recommended pattern for automation: fail the caller when anything went wrong
pwsh -NoLogo -NoProfile -NonInteractive -File .\tools\clean-bom-senior.ps1 --dry-run
if ($LASTEXITCODE -ne 0) { throw "clean-bom-senior reported issues (exit $LASTEXITCODE)" }
```

> **Run it inside an isolated directory.** Called without file arguments the tool
> recursively cleans the *current* directory — in the port, the directory PowerShell is
> currently located in. Set the location deliberately before a cleaning run:
> `Set-Location -LiteralPath 'C:\work\sandbox'`.

### Command-Line Options

The POSIX spellings are the contract and work exactly as in the shell original. The
PowerShell-style aliases are added for interactive use; they are matched
**case-sensitively**, because `-v` and `-V` mean different things.

| POSIX / shell spelling | PowerShell alias | Description |
|---|---|---|
| `-h`, `--help` | `-Help` | Show help message and exit (stdout) |
| `-v`, `--verbose` | `-Verbose` | Enable detailed output and processing logs |
| `-n`, `--dry-run` | `-DryRun` | Preview mode: nothing is modified (also enables verbose, as in the shell) |
| `-V`, `--version` | `-Version` | Show script version information (stdout) |
| `--no-bom-clear` | `-NoBomClear` | Do not remove BOM |
| `--no-rn-normalize` | `-NoRnNormalize` | Do not normalize CRLF (`\r\n`) lines |
| `--` | — | End option parsing; everything after it is a file argument |

```powershell
& .\clean-bom-senior.ps1 -h              # same as --help
& .\clean-bom-senior.ps1 -DryRun         # same as --dry-run
& .\clean-bom-senior.ps1 -- -weird-.php  # treat '-weird-.php' as a file name
```

Two behaviours worth knowing, both inherited from the shell parser:

- **The first positional argument ends option parsing.** `script a.php --verbose` treats
  `--verbose` as a second file name, not as a flag. Put flags first.
- **`--dry-run` implies verbose.** The shell version does the same, so the log stays comparable.

There is deliberately no `param()` block: PowerShell's own parameter binding would swallow
the POSIX spellings and break drop-in compatibility with the shell CLI.

### Usage Examples

```powershell
$tool = '.\clean-bom-senior.ps1'   # or an absolute path

# Preview the whole project — no file is modified
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --dry-run

# Clean everything, with the per-file log
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --verbose

# Clean only specific files
pwsh -NoLogo -NoProfile -NonInteractive -File $tool .\index.php .\assets\style.css

# Strip BOM only (leave CRLF alone)
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --no-rn-normalize

# Normalize CRLF only (leave BOM alone)
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --no-bom-clear

# Both operations off — reports what would be skipped, changes nothing
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --dry-run --no-bom-clear --no-rn-normalize
```

### What It Changes, Byte for Byte

Detection matches the shell original exactly:

| Rule | Implementation |
|---|---|
| BOM | bytes `EF BB BF` at offsets 0, 1, 2 — nowhere else |
| CRLF | bytes `0D 0A` **within the first 1024 bytes** |
| Extension filter | case-insensitive: `php css js txt xml htm html` |
| Empty files | skipped in recursive mode (the reference `find` uses `-size +0c`) |
| Size limit | files of 100 MB or more are skipped |
| Skip when clean | a file with no detected issue is never rewritten |

Normalization reproduces the reference `sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//'`
pipeline, and was calibrated against observed `sed` behaviour rather than assumed:

| Input (`\r`=CR, `\n`=LF) | Result | Why |
|---|---|---|
| `a\r\nb` | `a\nb` | CR before LF is removed — the CRLF conversion |
| `a\r` (CR at end of file) | `a` | `$` matches at end of buffer, so a trailing CR is dropped |
| `a\rb` (lone CR inside a line) | `a\rb` | CR not followed by LF and not at EOF survives |
| BOM only | empty file | BOM is line 1, and removing it leaves nothing |
| `\xEF\xBB\xBFa\r\n` | `a\n` | BOM at offset 0 is dropped, CRLF normalized |
| `x\xEF\xBB\xBFa` | `x\xEF\xBB\xBFa` | BOM not at offset 0 is not a BOM marker |
| `first\r\nsecond` (no final newline) | `first\nsecond` | no newline is added at the end of a file |

The CRLF *detection* window is 1024 bytes, exactly like the reference; the CRLF
*normalization* covers the entire file in both implementations. A CRLF sitting beyond the
first 1024 bytes does not make the file "dirty", but if the file is rewritten for any other
reason, those line endings are normalized as well — the port reproduces the reference here,
and `tests/differential.ps1` covers the case explicitly.

### Safety Model

The port touches user files, so the guarantees are explicit:

1. **Nothing is rewritten without a reason.** Files without BOM and without CRLF in the
   detection window are skipped; content, attributes and modification time stay untouched.
2. **A backup is taken first.** `<file>.bak.<pid>` is created next to the file before any
   change is written, and deleted after a successful replacement.
3. **The replacement is atomic.** The cleaned bytes are written to a temp file
   (`%TEMP%\<script>.<pid>.<guid>`), then moved over the original with overwrite, so the
   original path never holds a half-written file.
4. **Failure rolls back.** If the move fails, the backup is copied back over the file and
   the temp file is removed.
5. **Identity is preserved.** The ACL, the file attributes, the creation time and the
   original last-write time are captured before the rewrite and restored after it — this is
   the port's version of the reference's `chown`/`chmod`/`touch -r` step.
6. **Binary files are refused.** A file that carries a supported extension but holds a NUL
   byte is reported and skipped instead of being rewritten; the reference rewrites it.
7. **Third-party and generated trees are not entered.** Directories such as `.git`,
   `node_modules`, `vendor`, `bower_components`, `.venv`, `obj`, `dist`, `build`, `coverage`
   and `target` are skipped instead of being cleaned. The reference walks into them.
8. **Symlinks and junctions are not followed**, so a cleaning run cannot escape the tree it
   was started in through a reparse point.

Failure classification is preserved from the reference: an unreadable or unwritable file is
an *access* error, a file that cannot be processed is a *processing* error, and both make
the process exit code `1` instead of failing silently.

> **Read-only files.** On Windows there is no POSIX mode bit, so the port treats the
> ReadOnly attribute (or an ACL denying write) as "not writable" and reports the same
> access error the reference does.

### Output and Exit Codes

The stream contract is the reference's, and it is machine-checkable:

| Stream | Content |
|---|---|
| stdout | only `--help` and `--version` output |
| stderr | banner, configuration block, log lines, summary — everything else |

```powershell
# Measured: stdout 0 bytes, stderr 1377 bytes for a --dry-run in an empty directory
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --dry-run 1> $null
```

Log lines use the reference format `[yyyy-MM-dd HH:mm:ss LEVEL] message`, where `INFO` and
`ERROR` always print and `WARN`, `SUCCESS`, `PROCESSING` print in verbose mode. ANSI colour
is emitted only when stderr is a terminal, exactly as the reference gates on `[ -t 2 ]` —
piped output is plain text.

Exit codes are identical to the reference:

| Code | Meaning |
|---|---|
| `0` | Success — all files processed without errors |
| `1` | Partial success — at least one file had an access, processing or replacement error |
| `2` | Invalid command-line arguments (unknown option) |
| `3` | Temp directory missing or not writable |

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 --bogus
# stderr: [2026-10-02 02:37:06 ERROR] Unknown option: --bogus
# $LASTEXITCODE → 2
```

> **Exit code 3 in the port.** The check runs against the temp directory resolved by .NET,
> which validates the environment and falls back to the per-user temp directory. Pointing
> `TMP`/`TMPDIR` at a non-existent directory therefore does *not* produce exit code 3 here,
> while the shell original exits 3 in that situation (measured: shell `3`, port `0`). This
> is a deliberate divergence — see the table below.

### Comprehensive Statistics

The summary block is the reference's, field for field:

```text
=== UTF-8 BOM & CRLF Cleaner v2.07.0 ===
Author: Mikhail Deynekin (mid1977@gmail.com)
Website: https://deynekin.com
Started: 2026-10-02 02:40:14

--- Configuration ---
Verbose mode: DISABLED
Dry-run mode: DISABLED
BOM removal: ENABLED
CRLF normalization: DISABLED
Supported extensions: php css js txt xml htm html
Maximum file size: 100 MB

--- Operation Mode ---
• Scanning files for UTF-8 BOM and CRLF issues
• Removing invisible UTF-8 BOM signatures
• Preserving file ownership, permissions, and timestamps
• Creating backup copies during processing

Starting file processing...
[2026-10-02 02:40:14 INFO] Specific file mode: Processing 1 file(s)

=== PROCESSING SUMMARY ===
Execution time: 0 seconds
Files processed: 1
Files skipped (clean): 1
Errors encountered: 0

--- Issues Fixed ---
BOM signatures removed: 1
CRLF line endings fixed: 1

--- File Type Distribution ---
.php files: 1

Processing completed at: 2026-10-02 02:40:14
```

`--dry-run` replaces the "would process" log with a `Would process: <file> (Issues: …, Type: …)`
line per file, lists the affected files under `--- Files That Would Be Processed ---`, and
prints `NO FILES WILL BE MODIFIED (preview mode)` in the mode block. `Issues` is one of
`BOM`, `CRLF` or `BOM+CRLF`.

### Deliberate Divergences from the Shell Original

Everything not listed here is expected to be identical, and
`tests/differential.ps1` fails the build when it is not.

| # | Area | `clean-bom-senior.sh` | `clean-bom-senior.ps1` | Why |
|---|---|---|---|---|
| 1 | Modification time | re-stamped with the copy time (`touch -r` points at a fresh backup) | original last-write time restored | the README promises preserved timestamps |
| 2 | `--no-rn-normalize` | CRLF still removed — MSYS `sed` strips CR on read | flag really leaves CRLF intact | a declared flag must work |
| 3 | Metadata | uid/gid/mode via `chown`/`chmod` | ACL, attributes, creation time | POSIX modes do not exist on Windows |
| 4 | Binary files | rewrites a file containing NUL bytes | reports it and skips | never corrupt binary data |
| 5 | Directory walk | descends into `vendor/`, `.git/`, `node_modules/` | these trees are pruned | protects third-party code |
| 6 | Exit code 3 | unwritable `TMPDIR` exits immediately with 3 | .NET validates the temp path and falls back to a working directory | no reliance on `TMPDIR`/`TMP`, which automation environments frequently lack |
| 7 | Help text | `clean-bom-senior.sh` in the usage block | `clean-bom-senior.ps1`, plus a "PowerShell port notes" section | the usage line names the file the user actually ran |

Divergences 1, 2, 3, 5 and 7 are improvements over the reference rather than compromises:
the shell script intends the same behaviour and fails to deliver it (documented in the
project issue list). Divergences 4 and 6 are safety decisions taken in the port.

### 🔍 Verifying Parity

Parity is not asserted by reading the code — it is measured. `tests/differential.ps1`
builds one fixture set from **raw bytes**, copies it twice, runs each implementation on its
own copy, and compares the results file by file, byte by byte, plus the exit codes.

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\differential.ps1
```

Expected output:

```text
fixtures prepared: 17
...
shell exit: 0   port exit: 0
[EXPECTED] binary_nul.js           port skipped the binary; the reference rewrote it
[SAME] bom_crlf.php            14 bytes
...
identical: 14 / 14 compared
leftover backups - shell: 0  port: 0

parity verified: identical bytes and identical exit codes
```

The run exits `0` only when every compared file matches, both implementations agree on the
exit code, the documented divergences are reproduced as documented, no backup file was left
behind, and no relative-path invocation produced a spurious access error. Any other outcome
exits `1`, prints the file-level difference (hexadecimal, for small files) and dumps the tail
of both runs.

### CLI Contract Test

The byte comparison above does not say anything about argument parsing, binary detection or
the shape of paths in the log. `tests/cli-contract.ps1` covers those three, each of them a
defect found in the audit of 2026-10-05:

| Case | Expected | Was |
|---|---|---|
| `clean-bom-senior.ps1 -` | `Unknown option: -`, exit 2 | `File not found: -`, exit 0 |
| NUL byte past the first 8 KB | skipped, reported with its offset, file untouched | missed, file rewritten |
| recursive log path | `./name`, as the reference prints it | absolute Windows path |

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\cli-contract.ps1
# assertions checked: 15   failures: 0
```

## 🪟 Batch Port (cmd.exe)

`clean-bom-senior.bat` is the third implementation of the same contract, for Windows hosts
without PowerShell and without Git Bash. Same flags, same detection window, same report, same
exit codes; the file bytes are identical to the PowerShell port and to the shell original.

```bat
clean-bom-senior.bat                             Process all files recursively
clean-bom-senior.bat --dry-run                   Preview mode (no file changes)
clean-bom-senior.bat file1.php file2.js          Process specific files only
clean-bom-senior.bat --no-bom-clear              Skip BOM removal
clean-bom-senior.bat --no-rn-normalize           Skip CRLF normalization
```

The full design record — the hexadecimal filter, the `cmd` traps it works around, and every
divergence with its measurement — is in `docs/BAT-PORT.md`.

### Why certutil

`cmd.exe` has no byte-oriented I/O: `set`, `for /f`, `echo` and redirection all work on text
and rewrite line endings on the way through. BOM removal and CRLF normalisation are byte
operations, so this port performs them on a hexadecimal rendering:

```bat
certutil -encodehex -f <file> <hex> 4     rem  "ef bb bf 3c 3f ...", 16 values per line
certutil -decodehex      <hex> <file> 4   rem  the same format, no header
```

Both directions were verified byte for byte, including a short last line. The filter that
runs on that hex text reproduces `sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//'` and was
calibrated against the PowerShell port on a CR at every offset relative to the 16-byte
boundary of the dump.

### Batch Port Divergences

| # | Area | Behaviour |
|---|---|---|
| 1 | Help text | ASCII only; the reference's UTF-8 bullets depend on the console code page. File *content* is unaffected — it never passes through the code page |
| 2 | Modification time | restored through PowerShell when available; otherwise not restored, and the greeting says so |
| 3 | Paths with `!` | not supported: command extensions expand it inside the delayed-expansion blocks the script needs |
| 4 | Performance | about one second per 100 KB; meant for source trees, not multi-megabyte files |
| 5 | NUL byte offset | reported as the dump line number, not a byte offset |
| 6 | Timestamp format | the locale's own date string |
| 7 | Binary files | reported and skipped, as in the PowerShell port; the reference rewrites them |

Divergences 1, 5 and 6 come from what `cmd` can express; 2 and 3 are hard limits of the
shell, stated rather than hidden; 7 is the same safety decision the PowerShell port makes.

### Verifying the Batch Port

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\bat-differential.ps1
```

One fixture set built from raw bytes, three copies, three implementations. Expected:
`identical: 15 / 15 compared`, `leftover backups in the batch tree: 0`, `batch parity
verified: identical bytes against the PowerShell port`, exit code 0. The `.bat` result is
compared with the PowerShell port always, and with the shell original when Git Bash is
present; when it is absent the test says so explicitly instead of passing silently. The NUL
fixture is asserted as a documented divergence rather than compared.

Covered cases: BOM only; BOM + CRLF; CRLF without BOM; already clean file (must not be
rewritten); empty file; file consisting of a single BOM; mixed endings; lone CR inside a
line; CR at end of file; file without a trailing newline; unsupported extension;
upper-case extension; nested directories; CRLF beyond the 1024-byte detection window; BOM
not at offset 0; binary file with NUL bytes; `--no-rn-normalize`; relative file argument.

Useful switches:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\differential.ps1 -KeepFixtures
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\differential.ps1 -BashPath 'D:\Git\bin\bash.exe'
```

The test is isolated by construction: fixtures live in a fresh temp directory, each
implementation runs with its working directory set inside its own copy, and Git Bash is
detected automatically (`Program Files\Git\bin\bash.exe`, or next to `git.exe` on `PATH`).
The test copies *its own* copy of the reference script, so nothing in the repository is
modified by a test run.

### 🪟 Windows Automation

#### Pre-commit hook (Windows, no Git Bash)

Include both ports in the npm package. The package manifest already lists
`clean-bom-senior.ps1`; the batch port is shipped the same way:

```json
{
  "files": [
    "bin/",
    "clean-bom-senior.sh",
    "clean-bom-senior.ps1",
    "clean-bom-senior.bat",
    "README.md",
    "LICENSE"
  ]
}
```

`os` currently limits installation to `linux` and `darwin`, so a Windows install would be
refused by npm even though the package carries the Windows implementations. That gate is a
project decision, not an oversight — see `AGENTS.md` section 9.1.

```powershell
# .git\hooks\pre-commit  →  invoked through Git's own shell; wrap it in PowerShell:
#   pwsh -NoLogo -NoProfile -NonInteractive -File tools\check-bom.ps1
# tools\check-bom.ps1
$tool = Join-Path $PSScriptRoot 'clean-bom-senior.ps1'
pwsh -NoLogo -NoProfile -NonInteractive -File $tool --dry-run
if ($LASTEXITCODE -ne 0) {
    Write-Error 'BOM or CRLF issues found. Run: pwsh -File tools\clean-bom-senior.ps1'
    exit 1
}
Write-Host 'No BOM/CRLF issues detected'
```

Without PowerShell at all, the pre-commit hook can call the batch port directly:

```bat
@echo off
rem .git\hooks\pre-commit
"%~dp0..\tools\clean-bom-senior.bat" --dry-run
if errorlevel 1 (
    >&2 echo BOM or CRLF issues found
    exit /b 1
)
exit /b 0
```

#### GitHub Actions (Windows runner)

```yaml
name: Clean BOM (Windows)
on: [push, pull_request]
jobs:
  clean-bom:
    runs-on: windows-latest          # pwsh 7.x is preinstalled
    steps:
      - uses: actions/checkout@v4
      - name: Check for BOM and CRLF
        shell: pwsh
        run: |
          ./clean-bom-senior.ps1 --dry-run
          if ($LASTEXITCODE -ne 0) { exit 1 }
```

#### Scheduled maintenance task

```powershell
# Run every night in a fixed working directory
$action  = New-ScheduledTaskAction -Execute (Get-Command pwsh).Source `
    -Argument '-NoLogo -NoProfile -NonInteractive -File "C:\tools\clean-bom-senior.ps1" --verbose' `
    -WorkingDirectory 'C:\sites\myapp'
$trigger = New-ScheduledTaskTrigger -Daily -At 03:00
Register-ScheduledTask -TaskName 'Clean BOM (myapp)' -Action $action -Trigger $trigger
```

#### npm scripts (cross-platform)

```json
{
  "scripts": {
    "check-bom": "pwsh -NoLogo -NoProfile -NonInteractive -File ./clean-bom-senior.ps1 --dry-run",
    "clean-bom": "pwsh -NoLogo -NoProfile -NonInteractive -File ./clean-bom-senior.ps1 --verbose"
  }
}
```

## 🏗️ Advanced Features

### File Preservation Guarantees

Clean BOM Senior ensures **complete file integrity**:

```bash
# Before processing (example file attributes)
-rw-r--r-- 1 developer team 1234 Oct 28 10:30 script.php

# After processing - ALL attributes preserved
-rw-r--r-- 1 developer team 1156 Oct 28 10:30 script.php
# ✅ Same owner, group, permissions, timestamp
# ❌ Only file size changed (BOM removed: 1234 → 1156 bytes)
```

**What's Preserved:**

- ✅ **Ownership**: Original user and group ownership (shell) / ACL and owner (PowerShell)
- ✅ **Permissions**: File mode/access rights (755, 644, etc.) / ACL entries and attributes
- ✅ **Timestamps**: Last modified time (crucial for build systems), plus creation time in the port
- ✅ **Content Integrity**: Only BOM and CRLF are removed
- ✅ **Idempotence**: A second run over a clean tree changes nothing and rewrites nothing

### Comprehensive Statistics

```bash
# Example output with statistics
=== PROCESSING SUMMARY ===
Execution time: 2 seconds
Files processed: 15
Files skipped (clean): 8
Errors encountered: 0

--- Issues Fixed ---
BOM signatures removed: 12
CRLF line endings fixed: 8

--- File Type Distribution ---
.php files: 10
.js files: 3
.css files: 2
```

The PowerShell port prints the same block; see
[Comprehensive Statistics](#comprehensive-statistics) for a captured run.

### Supported File Types

| Extension | Purpose | Common Issues |
|-----------|---------|---------------|
| `.php` | PHP scripts | BOM breaks `namespace`, `declare()` |
| `.css` | Stylesheets | BOM can affect rendering |
| `.js` | JavaScript | BOM may break modules/imports |
| `.txt` | Text files | Mixed line endings |
| `.xml` | XML documents | BOM affects XML parsing |
| `.htm/.html` | Web pages | Encoding display issues |

Extensions are matched case-insensitively (`UPPER.PHP` is processed). Files with other
extensions are still processed when they are passed **explicitly** on the command line —
useful for `.ps1`, `.cs`, `.py`, `.md` and friends, which are not part of the recursive
extension filter:

```powershell
# Explicit paths bypass the recursive extension filter in both implementations
pwsh -NoLogo -NoProfile -NonInteractive -File .\clean-bom-senior.ps1 .\script.ps1 .\build.yaml
```

### Error Handling

Clean BOM Senior provides **bulletproof error handling**:

```bash
--- Error Breakdown ---
Access errors: 2        # Permission denied files
File size errors: 1     # Files exceeding size limit
Processing errors: 0    # Content processing failures
Other errors: 0         # Miscellaneous issues
```

**Error Recovery Features:**
- 🔄 **Automatic Rollback**: Failed operations are completely reverted
- 💾 **Backup & Restore**: Temporary backups ensure data safety
- 📝 **Detailed Logging**: Every error includes context and suggestions
- 🛡️ **Safe Defaults**: Conservative approach prevents data loss

Errors are counted per category and reported in the summary. A file that is missing or
unreadable counts as an *access* error; a file whose replacement failed counts as a
*processing* error and triggers a rollback from the backup.

## 🔗 DevOps Integration

### CI/CD Pipeline Integration

#### GitHub Actions
```yaml
name: Clean BOM
on: [push, pull_request]
jobs:
  clean-bom:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Clean BOM markers
        run: |
          wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
          chmod +x clean-bom-senior.sh
          ./clean-bom-senior.sh --dry-run --verbose
```

#### GitLab CI
```yaml
clean_bom:
  stage: test
  script:
    - wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
    - chmod +x clean-bom-senior.sh
    - ./clean-bom-senior.sh --verbose
  only:
    - merge_requests
    - main
```

#### Checking a whole repository in CI (both platforms)

```yaml
jobs:
  bom-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./clean-bom-senior.sh --dry-run
  bom-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - shell: pwsh
        run: |
          ./clean-bom-senior.ps1 --dry-run
          exit $LASTEXITCODE
```

### Git Hooks

#### Pre-commit Hook
```bash
#!/bin/bash
# .git/hooks/pre-commit
./tools/clean-bom-senior.sh --dry-run > /dev/null
if [ $? -ne 0 ]; then
    echo "❌ BOM or CRLF issues found. Run: ./tools/clean-bom-senior.sh"
    exit 1
fi
echo "✅ No BOM/CRLF issues detected"
```

#### Pre-push Hook
```bash
#!/bin/bash
# .git/hooks/pre-push
echo "🧹 Cleaning BOM markers before push..."
./tools/clean-bom-senior.sh --verbose
```

For Windows hooks that must not depend on Git Bash, see
[Windows Automation](#-windows-automation).

### Docker Integration

```dockerfile
# Dockerfile example
FROM php:8.1-alpine
COPY . /app
WORKDIR /app

# Clean BOM as part of build process
RUN wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh \
    && chmod +x clean-bom-senior.sh \
    && ./clean-bom-senior.sh \
    && rm clean-bom-senior.sh

CMD ["php", "index.php"]
```

For a Windows container image, use the PowerShell port instead:

```dockerfile
# escape=`
FROM mcr.microsoft.com/powershell:7.6-windowsservercore-ltsc2022
COPY . /app
WORKDIR /app
RUN pwsh -NoLogo -NoProfile -NonInteractive -File ./clean-bom-senior.ps1
```

## 🏢 Team & Enterprise Usage

### Project Setup
```bash
# Add to project tools
mkdir -p tools
cd tools
wget https://github.com/paulmann/Clean_BOM_Senior/raw/main/clean-bom-senior.sh
chmod +x clean-bom-senior.sh

# Create project alias in package.json (for Node.js projects)
{
  "scripts": {
    "clean-bom": "./tools/clean-bom-senior.sh --verbose",
    "check-bom": "./tools/clean-bom-senior.sh --dry-run"
  }
}

# Or in Makefile
clean-bom:
	./tools/clean-bom-senior.sh --verbose

check-bom:
	./tools/clean-bom-senior.sh --dry-run
```

```powershell
# Windows equivalents
New-Item -ItemType Directory -Path .\tools -Force | Out-Null
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/main/clean-bom-senior.ps1' `
                  -OutFile .\tools\clean-bom-senior.ps1
```

```json
{
  "scripts": {
    "clean-bom": "pwsh -NoLogo -NoProfile -NonInteractive -File ./tools/clean-bom-senior.ps1 --verbose",
    "check-bom": "pwsh -NoLogo -NoProfile -NonInteractive -File ./tools/clean-bom-senior.ps1 --dry-run"
  }
}
```

### Team Workflow
```bash
# Before committing changes
npm run check-bom          # or: make check-bom
# If issues found:
npm run clean-bom          # or: make clean-bom

# Regular maintenance
./tools/clean-bom-senior.sh --verbose  # Weekly cleanup
```

One tool, two entry points — pick the one that matches the developer's platform, and keep
the flags identical so the log of a Linux run and a Windows run can be compared directly:

```powershell
# Linux/macOS developer
./tools/clean-bom-senior.sh --dry-run --verbose

# Windows developer, same check
pwsh -NoLogo -NoProfile -NonInteractive -File .\tools\clean-bom-senior.ps1 --dry-run --verbose
```

### IDE Integration

#### VS Code Task (`.vscode/tasks.json`)
```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Clean BOM",
            "type": "shell",
            "command": "./tools/clean-bom-senior.sh",
            "args": ["--verbose"],
            "group": "build",
            "presentation": {
                "echo": true,
                "reveal": "always"
            }
        }
    ]
}
```

#### VS Code Task for Windows (`.vscode/tasks.json`)
```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Clean BOM (PowerShell)",
            "type": "shell",
            "command": "pwsh",
            "args": [
                "-NoLogo", "-NoProfile", "-NonInteractive",
                "-File", "${workspaceFolder}/tools/clean-bom-senior.ps1",
                "--verbose"
            ],
            "group": "build",
            "problemMatcher": [],
            "presentation": {
                "echo": true,
                "reveal": "always"
            }
        }
    ]
}
```

## 🔍 Troubleshooting

### Common Issues

#### Permission Errors
```bash
# Problem: Cannot write to file
[ERROR] Cannot write to file: protected.php

# Solution: Check file permissions
chmod 644 protected.php
# Or run with appropriate permissions
sudo ./clean-bom-senior.sh
```

#### No Files Found
```bash
# Problem: "No files found with supported extensions"
# Solution: Verify you're in the correct directory
ls -la *.{php,css,js,html}  # Check for supported files
pwd                          # Verify current directory
```

#### Large Files Skipped
```bash
# Problem: File size exceeds limit
# Check file sizes
find . -name "*.php" -size +100M -exec ls -lh {} \;

# Solution: Process large files individually if needed
./clean-bom-senior.sh specific-large-file.php
```

> Files of 100 MB or more are skipped by the size guard, and the guard wins over an
> explicit path too: the tool reports `File exceeds the size limit, skipping` and leaves the
> file alone. Clean such a file with a dedicated tool.

### PowerShell-Specific Issues

| Symptom | Cause | Fix |
|---|---|---|
| `The term 'pwsh' is not recognized` | PowerShell 7 not installed, or not on `PATH` | install PowerShell 7.6+; `C:\Program Files\PowerShell\7\pwsh.exe` is a valid absolute path |
| `The script ... is not digitally signed` | execution policy blocks dot-sourcing | launch with `pwsh -ExecutionPolicy Bypass -File ...`, or run via `-File` (no policy needed) |
| `Cannot write to file: <path>` | ReadOnly attribute or ACL denies write | `Set-ItemProperty -LiteralPath <path> -Name Attributes -Value Normal`, or fix the ACL |
| `Binary content (NUL byte) detected, skipping` | the file is not text | expected; pass it to a binary-aware tool instead |
| A relative file argument is reported as missing | the file is resolved against the process working directory | `Set-Location` to the file's directory first, or pass an absolute path |
| `Unknown option: -verbose` | PowerShell aliases are case-sensitive | use `-Verbose`, or the POSIX `-v` |
| Colour codes in a redirected log | a terminal was detected | none needed — piped output is already plain; redirect stderr to a file to force it |

### Debugging Commands

```bash
# Check for BOM manually
hexdump -C file.php | head -1
# Look for: EF BB BF at beginning

# Check for CRLF
od -c file.php | head -5
# Look for: \r \n sequences

# Verify UTF-8 encoding
file -i file.php
# Should show: charset=utf-8
```

```powershell
# Check for BOM manually (first three bytes)
$bytes = [System.IO.File]::ReadAllBytes('.\file.php')
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$hasCrlf = ([System.IO.File]::ReadAllText('.\file.php')) -match "`r`n"
"BOM=$hasBom  CRLF=$hasCrlf"      # → BOM=False  CRLF=False when clean

# Hex dump of the first 16 bytes
($bytes[0..15] | ForEach-Object { $_.ToString('x2') }) -join ' '
```

### Recovery Procedures

```bash
# If something goes wrong, backups are created as:
# filename.bak.PROCESS_ID

# Restore from backup
cp file.php.bak.12345 file.php

# Clean up backup files
rm *.bak.*
```

```powershell
# The same naming applies in the port: <file>.bak.<pid>, next to the file
Copy-Item -LiteralPath '.\file.php.bak.12345' -Destination '.\file.php' -Force

# Find leftovers of an interrupted run
Get-ChildItem -Recurse -File | Where-Object { $_.Name -match '\.bak\.\d+$' }
```

A backup left on disk means the run did not finish for that file; the original file is
still present and untouched until the atomic replacement, so a leftover backup can be
removed once you have verified the file content.

## 🤝 Contributing

We welcome contributions! Here's how to get involved:

### Development Setup
```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior

# Check script syntax
bash -n clean-bom-senior.sh

# Test dry run
./clean-bom-senior.sh --dry-run --verbose
```

```powershell
# Check the port's syntax without running it
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\clean-bom-senior.ps1), [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { $errors | Format-List; throw 'Syntax errors' }

# Dry run in a sandbox
Set-Location -LiteralPath .\sandbox
pwsh -NoLogo -NoProfile -NonInteractive -File ..\clean-bom-senior.ps1 --dry-run --verbose

# Prove parity with the shell original (the only accepted proof)
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\differential.ps1
```

A change to either implementation is only complete when `tests/differential.ps1` reports
`parity verified`. If a change intentionally moves behaviour away from the reference, add a
row to [Deliberate Divergences](#deliberate-divergences-from-the-shell-original) **and** an
assertion for it in the test, so the divergence is checked instead of assumed.

Maintainer notes — invariants, known traps, and the decisions behind each divergence — live
in `AGENTS.md` at the repository root.

### Contribution Guidelines

1. **Fork** the repository
2. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **Test** your changes thoroughly
4. **Commit** your changes (`git commit -m 'Add amazing feature'`)
5. **Push** to the branch (`git push origin feature/amazing-feature`)
6. **Open** a Pull Request

### Code Standards

- ✅ **POSIX Compliance**: Ensure compatibility across different shells
- ✅ **PowerShell 7.6 only**: `#Requires -Version 7.6`, `#Requires -PSEdition Core`, no Windows PowerShell 5.1 constructs
- ✅ **Error Handling**: Comprehensive error checking and recovery
- ✅ **Documentation**: Comment complex logic and functions
- ✅ **Testing**: Verify functionality across different file types, and re-run the differential test
- ✅ **Backwards Compatibility**: Maintain compatibility with existing usage — flags, output and exit codes are a contract

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

```
MIT License

Copyright (c) 2025 Mikhail Deynekin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

## 👨‍💻 Author & Support

**Mikhail Deynekin**
- 🌐 Website: [deynekin.com](https://deynekin.com)
- 📧 Email: mid1977@gmail.com
- 🐙 GitHub: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: Read this README thoroughly
- 🐛 **Bug Reports**: [Open an issue](https://github.com/paulmann/Clean_BOM_Senior/issues/new)
- 💡 **Feature Requests**: [Request features](https://github.com/paulmann/Clean_BOM_Senior/issues/new)
- 💬 **Questions**: Check [Discussions](https://github.com/paulmann/Clean_BOM_Senior/discussions)

### Related Projects

- [ssg/unbom](https://github.com/ssg/unbom) - .NET tool for BOM removal
- [stdlib-js/string-remove-utf8-bom](https://github.com/stdlib-js/string-remove-utf8-bom) - Node.js BOM removal
- [PowerShell/PowerShell](https://github.com/PowerShell/PowerShell) - the interpreter the port requires

## 🎯 Roadmap

### Upcoming Features

- [ ] **Web Interface**: Browser-based file upload and cleaning
- [ ] **Docker Image**: Pre-built container for CI/CD integration
- [x] **Windows Support**: Native Windows PowerShell version — `clean-bom-senior.ps1` (PowerShell 7.6), parity-verified
- [ ] **Plugin System**: Extensible architecture for custom processors
- [ ] **Performance Optimization**: Parallel processing for large codebases
- [ ] **Advanced Reporting**: HTML/JSON output formats
- [ ] **Unified CLI**: a single entry point that dispatches to the shell script or the port by platform

### Version History

- **PowerShell port** (2026-10-02, unreleased):
  - `clean-bom-senior.ps1` — PowerShell 7.6 port of the v2.07.0 contract: BOM removal, CRLF normalization, POSIX-style flags with PowerShell aliases, identical log format and exit codes
  - `tests/differential.ps1` — parity test against the shell original on 17 raw-byte fixtures (14 compared, 2 excluded by construction, 1 asserted divergence); exits non-zero on any byte-level difference
  - `tests/cli-contract.ps1` — CLI contract of the port on 15 assertions: argument parsing (including a bare `-`), NUL-byte detection beyond the first block, and the `./name` shape of log paths
  - `tests/bat-differential.ps1` — parity of the batch port against the PowerShell port and the shell original on 15 raw-byte fixtures
  - `docs/BAT-PORT.md` — design record of the batch port: the hexadecimal filter, the `cmd` traps, and every divergence with its measurement
  - `docs/RAGRAF-REPORT.md` — code audit of 2026-10-05: defects found, fixes, and what the static index could and could not answer
  - Preserves the original modification time, ACL, attributes and creation time across a rewrite; skips binary (NUL-byte) files; prunes `.git`, `vendor`, `node_modules` and other third-party or generated trees
  - Exit code 3 is reached through .NET's validated temp path (see divergences)
- **v2.07.0** (2025-09-30):  
  - Added `--no-bom-clear` and `--no-rn-normalize` CLI flags for selective disabling of BOM and CRLF operations  
  - Fixed variable leakage in `while read` loops (uses process substitution consistently)  
  - Enhanced dry-run output to reflect disabled operations  
  - Improved argument parsing and help text  
  - Minor refactoring for code clarity/maintainability
- **v2.06.4** (2025-09-28): Fixed statistics reporting, improved process substitution
- **v2.06.3** (2025-09-28): Resolved unbound variable issues, enhanced error handling
- **v2.06.2** (2025-09-28): Added file attribute preservation, global command support
- **v2.05.0** (2025-09-28): Major refactor with comprehensive statistics and CI/CD integration

---

<div align="center">

### ⭐ Star this repository if it helped you!

**Clean BOM Senior** - *Making source code clean, one file at a time* 🧹✨

[Report Bug](https://github.com/paulmann/Clean_BOM_Senior/issues) · [Request Feature](https://github.com/paulmann/Clean_BOM_Senior/issues) · [Documentation](https://github.com/paulmann/Clean_BOM_Senior/wiki)

</div>
