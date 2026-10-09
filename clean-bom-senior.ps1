#!/usr/bin/env pwsh
#Requires -Version 7.6
#Requires -PSEdition Core
# ==============================================================================
# Clean BOM Senior - UTF-8 BOM & CRLF Cleaner with Smart BOM Policy
# ==============================================================================
#
# File:         clean-bom-senior.ps1   (PowerShell port, v3 contract)
# Version:      3.0.0
# Author:       Mikhail Deynekin <mid1977@gmail.com>
# Website:      https://deynekin.com
# Repository:   https://github.com/paulmann/Clean_BOM_Senior
# License:      MIT
#
# DESCRIPTION
#   PowerShell implementation of the v3 CLI contract (docs/CLI-CONTRACT.md).
#   `clean-bom-senior.sh` is the normative reference; this port reproduces it
#   line by line - the same analysis pipeline, the same Smart BOM Policy
#   decision table, the same log lines, the same JSON schema, the same exit
#   codes. `tests/ps/run-tests.ps1` pins that parity with a differential test
#   against the shell reference on shared fixtures (byte-for-byte).
#
#   v3 introduces the Smart BOM Policy (see `--help bom-policy` and
#   docs/SMART-BOM.md): before stripping anything, the tool classifies the
#   file by its ACTUAL BYTES -
#     * UTF-16/UTF-32 BOMs are structurally required -> file is never touched;
#     * binary files (NUL bytes)                     -> never touched;
#     * invalid UTF-8                                -> never touched unless
#                                                       --force is given;
#     * UTF-8 BOM in "sensitive" text (txt/csv/ps1..., non-ASCII content) may
#       be required by Excel, legacy Notepad or Windows PowerShell 5.1 -> kept
#       by default, with an explanation; --force strips it;
#     * UTF-8 BOM in code (php/js/css/html/xml...) is harmful or useless ->
#       stripped.
#
#   Detection is byte-exact over the WHOLE file.
#
# PORTABILITY
#   PowerShell 7.6+ (Core) on Windows, Linux and macOS. Everything is .NET
#   byte I/O: no external tools are required for cleaning. Optional external
#   helpers are used when present and degrade gracefully when not:
#     git    --git
#     curl   --update / --check-update (Invoke-WebRequest is the fallback)
#     stat   hard-link count on Unix (fsutil hardlink list on Windows) - .NET
#            exposes no portable link count
#     chown  ownership transfer, root only (Unix)
#
# THIS FILE IS PURE ASCII ON PURPOSE - keep it that way (`tests/ps/run-tests.ps1`
#   asserts it). The help text it EMITS is not ASCII: the reference's help uses
#   em dashes, arrows, bullets and an ellipsis, and the help topics are part of
#   the CLI contract, so those bytes are stored as `__EMDASH__`-style
#   placeholders and restored by Resolve-HelpPlaceholders on the way out.
#   Saving this file as UTF-8-with-BOM instead would break `./clean-bom-senior.ps1`
#   on Unix, because a BOM in front of the shebang makes the kernel fall back to
#   /bin/sh. See docs/PS-PORT.md section 5.
#
# EXIT CODES
#   0   success (nothing to do, or everything cleaned)
#   1   finished, but some files could not be processed (per-file errors),
#       or --strict saw kept/protected files
#   2   invalid command line usage
#   3   environment problem (unusable temp dir, network failure during
#       --check-update, npm-managed install during --update)
#   4   critical internal error
#   10  --check mode: issues found (files need cleaning) - CI gate
#   11  --check-update: a newer version is available
#
# OUTPUT STREAMS
#   stderr : human log + summary (the v2/v3 contract)
#   stdout : machine output only (--json, --help, --version, --completion)
#
# DELIBERATE, DOCUMENTED DIVERGENCES FROM THE SHELL REFERENCE
#   1. `--completion` emits a PowerShell `Register-ArgumentCompleter` script
#      instead of a bash one (the shell reference emits bash completion).
#   2. Permissions transfer through .NET (`FileInfo.UnixFileMode`) on Unix and
#      through NTFS ACL inheritance on Windows; ownership transfer uses
#      `chown` and only runs as root (POSIX uid/gid mean nothing on Windows).
#   3. Hard-link detection shells out (`stat -c %h` on Unix,
#      `fsutil hardlink list` on Windows) because .NET exposes no portable
#      link count. When the probe is unavailable the file is assumed to have
#      one link and is replaced atomically.
#   4. `--update` accepts a self-verifying `.ps1` (a `#Requires` header plus
#      the `$script:Version = '<X.Y.Z>'` stamp) where the shell reference
#      checks a shebang plus `VERSION="<X.Y.Z>"`.
#   See docs/PS-PORT.md for the full table.
#
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
$script:VERSION = '3.0.0';
$script:SCRIPT_PATH = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:SCRIPT_NAME = [System.IO.Path]::GetFileName($script:SCRIPT_PATH)
$script:SCRIPT_PID = [System.Diagnostics.Process]::GetCurrentProcess().Id
$script:REPO_SLUG_DEFAULT = 'paulmann/Clean_BOM_Senior'

# Extensions cleaned by default (v2-compatible set).
$script:EXTENSIONS_DEFAULT = 'php css js txt xml htm html'

# Extensions whose UTF-8 BOM may be REQUIRED by mainstream Windows consumers
# (Excel / legacy Notepad / csv readers; Windows PowerShell 5.1). For these,
# the BOM is kept by default when the content is non-ASCII. Overrides:
# --force, --bom-policy=strip, --sensitive-ext "".
$script:SENSITIVE_DEFAULT = 'txt csv tsv ps1 psm1 psd1'

# Extensions where a UTF-8 BOM is known-harmful or useless: always safe to
# strip (parsers of these formats either reject or ignore the BOM).
$script:STRIP_ALWAYS = 'php phtml phps inc php3 php4 php5 php7 php8 ' +
'js mjs cjs jsx ts tsx vue json jsonc json5 ' +
'css scss sass less htm html xhtml xml svg xsl xslt ' +
'mustache hbs twig blade sh bash zsh fish py rb pl lua sql yaml yml toml'

# Directories never descended into by default (VCS internals / dependencies).
$script:EXCLUDE_DIRS_DEFAULT = '.git .svn .hg node_modules'

$script:MAX_SIZE_DEFAULT = [long]100 * 1024 * 1024

$script:EXIT_OK = 0
$script:EXIT_FILE_ERRORS = 1
$script:EXIT_USAGE = 2
$script:EXIT_ENV = 3
$script:EXIT_INTERNAL = 4
$script:EXIT_CHECK_FOUND = 10
$script:EXIT_UPDATE_AVAILABLE = 11

# Latin-1 maps every byte 0x00-0xFF onto the code point with the same value,
# so a Latin-1 string is a lossless, index-preserving view of a byte array.
# It is used for fast native substring scans (IndexOf) over file content.
$script:LATIN1 = [System.Text.Encoding]::GetEncoding(28591)
# UTF-8 decoder that throws on invalid sequences - the .NET equivalent of
# `iconv -f UTF-8 -t UTF-8`. GetByteCount() validates without allocating.
$script:UTF8_STRICT = New-Object System.Text.UTF8Encoding($false, $true)

# ------------------------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------------------------
$script:VERBOSE_ON = 0
$script:QUIET = 0
$script:SILENT = 0
$script:DRY_RUN = 0
$script:CHECK_MODE = 0
$script:JSON_OUT = 0
$script:FORCE = 0
$script:STRICT = 0
$script:SHOW_HELP = 0
$script:HELP_TOPIC = ''
$script:SHOW_VERSION = 0
$script:SHOW_COMPLETION = 0
$script:SELF_TEST = 0
$script:DO_CHECK_UPDATE = 0
$script:DO_UPDATE = 0

$script:BOM_POLICY = 'auto'                 # auto | strip | keep
$script:NO_BOM_CLEAR = 0                    # v2 compat: --no-bom-clear
$script:NO_CRLF_NORMALIZE = 0               # v2 compat: --no-rn-normalize
$script:EXTENSIONS = $script:EXTENSIONS_DEFAULT
$script:SENSITIVE_EXTS = $script:SENSITIVE_DEFAULT
$script:USER_EXCLUDE_DIRS = ''
# NOTE: this must stay a real List. `@()` would produce a fixed-size
# System.Object[], whose .Add() dies with "Collection was of a fixed size".
$script:EXCLUDE_PATTERNS = [System.Collections.Generic.List[string]]::new()
$script:EXCLUDE_DIRS = $script:EXCLUDE_DIRS_DEFAULT
$script:USE_DEFAULT_EXCLUDES = 1
$script:MAX_SIZE = $script:MAX_SIZE_DEFAULT
$script:GIT_MODE = 0
$script:COLOR_MODE = 'auto'
$script:LOG_FILE = ''
$script:BACKUP = 0
$script:BACKUP_DIR = ''
$script:KEEP_MTIME = 1

# Counters
$script:SCANNED_COUNT = 0
$script:CHANGED_COUNT = 0
$script:WOULD_CHANGE_COUNT = 0
$script:CLEAN_COUNT = 0
$script:KEPT_BOM_COUNT = 0
$script:PROTECTED_UTF16_COUNT = 0
$script:PROTECTED_BINARY_COUNT = 0
$script:PROTECTED_INVALID_COUNT = 0
$script:SKIPPED_SIZE_COUNT = 0
$script:BOM_REMOVED_COUNT = 0
$script:CRLF_FIXED_COUNT = 0
$script:ERROR_COUNT = 0
$script:ERR_ACCESS = 0
$script:ERR_PROCESSING = 0
$script:ERR_OTHER = 0
$script:FILE_ERRORS = 0
$script:START_TIME = [DateTime]::MinValue
$script:START_TIME_ISO = ''

# Aggregates
$script:CHANGED_EXT_LINES = New-Object System.Collections.Generic.List[string]
$script:AFFECTED_FILES = New-Object System.Collections.Generic.List[string]
$script:JSON_ENTRIES = New-Object System.Collections.Generic.List[string]
$script:TEMP_FILES = New-Object System.Collections.Generic.List[string]

# Positional paths / git pathspecs
$script:POSITIONAL = New-Object System.Collections.Generic.List[string]
$script:GIT_PATHSPEC = New-Object System.Collections.Generic.List[string]

$script:SELF_PATH = $script:SCRIPT_PATH
$script:SCRIPT_PATH_RESOLVED = ''
$script:ExitCode = 0

# Per-file analysis results (filled by Get-FileAnalysis)
$script:A = @{
    enc = 'none'; hasCrlf = 0; binary = 0; validUtf8 = 1; nonAscii = 0
    candidate = 0; oversize = 0; size = [long]0; ext = ''; extClass = 'unknown'
}
# Per-file plan (filled by Get-FilePlan)
$script:P = @{
    stripBom = 0; fixCrlf = 0; bomKept = 0; status = 'clean'; reason = ''
}

# Colours (populated by Initialize-Color; empty strings when disabled)
$script:COL_RED = ''
$script:COL_GREEN = ''
$script:COL_YELLOW = ''
$script:COL_BLUE = ''
$script:COL_MAGENTA = ''
$script:COL_CYAN = ''
$script:COL_RESET = ''

# Saved console state, restored on exit
$script:SAVED_OUT_ENC = $null
$script:SAVED_ERR_ENC = $null

# ------------------------------------------------------------------------------
# Control flow: a fatal condition throws, the outer handler maps it to an exit
# code, and the finally block removes registered temp files (the bash `trap`).
# ------------------------------------------------------------------------------
class CleanBomFatalException : System.Exception {
    [int]$Code
    CleanBomFatalException([int]$code, [string]$message) : base($message) { $this.Code = $code }
}

function Register-TempFile {
    param([string]$Path)
    $script:TEMP_FILES.Add($Path)
}

function Remove-RegisteredTempFiles {
    foreach ($t in @($script:TEMP_FILES)) {
        if ($t) {
            try { [System.IO.File]::Delete($t) } catch { }
        }
    }
    $script:TEMP_FILES.Clear()
}

# This file is pure ASCII on purpose, and the help text it emits is not: the
# reference's help contains em dashes, arrows, bullets and an ellipsis, and the
# help topics are part of the CLI contract, so the OUTPUT must carry those exact
# bytes. They are therefore stored as ASCII placeholders and restored here.
#
# Why not just save the file as UTF-8 with a BOM, the way the Smart BOM Policy
# recommends for a non-ASCII .ps1? Because a BOM in front of `#!/usr/bin/env
# pwsh` breaks direct invocation on Unix: the kernel reads the first two bytes
# as the magic, finds \xEF\xBB instead, and falls back to /bin/sh, which then
# fails on "\xEF\xBB\xBF#!/usr/bin/env: No such file or directory". Keeping the
# source ASCII preserves BOTH properties - identical output bytes and a working
# shebang - and as a bonus the tool has no opinion about its own source file.
$script:HELP_SUBSTITUTIONS = @(
    @('__EMDASH__', [string][char]0x2014),
    @('__ARROW__', [string][char]0x2192),
    @('__BULLET__', [string][char]0x2022),
    @('__ELLIPSIS__', [string][char]0x2026),
    @('__ELEMENTOF__', [string][char]0x2208),
    @('__NOTEQUAL__', [string][char]0x2260)
)

function Resolve-HelpPlaceholders {
    param([string]$Text)
    foreach ($pair in $script:HELP_SUBSTITUTIONS) {
        if ($Text.Contains($pair[0])) { $Text = $Text.Replace($pair[0], $pair[1]) }
    }
    return $Text
}

function Write-StdOut {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    # Bypasses PowerShell's formatting pipeline and $OutputEncoding entirely:
    # the bytes that reach stdout are exactly the UTF-8 encoding of $Text.
    [Console]::Out.Write((Resolve-HelpPlaceholders $Text))
}

function Write-StdErr {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    # Same placeholder resolution as stdout: the log messages carry the
    # reference's em dashes, and the file itself stays ASCII.
    [Console]::Error.Write((Resolve-HelpPlaceholders $Text))
}

#------------------------------------------------------------------------------
# Logging (stderr; optionally tee'd to --log-file). Line format is the v2/v3
# contract: [YYYY-MM-DD HH:MM:SS LEVEL] message
#------------------------------------------------------------------------------
function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

function Write-LogRaw {
    param([string]$Color, [string]$Level, [string]$Message)
    # --silent leaves ERROR only. WARN is "always visible" in the sense that v3
    # no longer hides it behind --verbose (v2 did, which is why protected files
    # could go unnoticed); --silent is the one explicit opt-out, and the
    # reference gates it here for every level except ERROR.
    if ($script:SILENT -eq 1 -and $Level -cne 'ERROR') { return }
    $ts = Get-Timestamp
    Write-StdErr ("$Color[$ts $Level]$($script:COL_RESET) $Message`n")
    if ($script:LOG_FILE) {
        try {
            [System.IO.File]::AppendAllText(
                $script:LOG_FILE, "[$ts $Level] $Message`n", $script:UTF8_NO_BOM_ENC)
        } catch { }
    }
}

function Write-LogInfo {
    param([string]$Message)
    if ($script:QUIET -eq 1) { return }
    Write-LogRaw -Color $script:COL_BLUE -Level 'INFO' -Message $Message
}

# v3: warnings are visible by default (v2 hid them behind --verbose, which is
# exactly why the "protected" cases must never be silent).
function Write-LogWarn {
    param([string]$Message)
    Write-LogRaw -Color $script:COL_YELLOW -Level 'WARN' -Message $Message
}

function Write-LogError {
    param([string]$Message)
    Write-LogRaw -Color $script:COL_RED -Level 'ERROR' -Message $Message
    $script:ERROR_COUNT = $script:ERROR_COUNT + 1
}

function Write-LogSuccess {
    param([string]$Message)
    if ($script:VERBOSE_ON -ne 1) { return }
    Write-LogRaw -Color $script:COL_GREEN -Level 'SUCCESS' -Message $Message
}

function Write-LogProcessing {
    param([string]$Message)
    if ($script:VERBOSE_ON -ne 1) { return }
    Write-LogRaw -Color $script:COL_CYAN -Level 'PROCESSING' -Message $Message
}

function Stop-Usage {
    param([string]$Message)
    Write-LogError $Message
    Write-StdErr ("Try `"$($script:SCRIPT_NAME) --help`" for more information.`n")
    throw [CleanBomFatalException]::new($script:EXIT_USAGE, $Message)
}

function Stop-Env {
    param([string]$Message)
    Write-LogError $Message
    throw [CleanBomFatalException]::new($script:EXIT_ENV, $Message)
}

function Stop-Internal {
    param([string]$Message)
    Write-LogError $Message
    throw [CleanBomFatalException]::new($script:EXIT_INTERNAL, $Message)
}

#------------------------------------------------------------------------------
# Colour initialisation (NO_COLOR / CLICOLOR_FORCE / --color are honoured)
#------------------------------------------------------------------------------
function Initialize-Color {
    $useColor = 0
    switch -CaseSensitive ($script:COLOR_MODE) {
        'always' { $useColor = 1 }
        'never' { $useColor = 0 }
        'auto' {
            $useColor = 0
            if ($null -ne $env:NO_COLOR -and $env:NO_COLOR -cne '') {
                $useColor = 0
            } elseif ($null -ne $env:CLICOLOR_FORCE -and $env:CLICOLOR_FORCE -cne '' -and $env:CLICOLOR_FORCE -cne '0') {
                $useColor = 1
            } elseif (-not [Console]::IsErrorRedirected) {
                $useColor = 1
            }
        }
        default { Stop-Usage "Invalid --color value: $($script:COLOR_MODE) (expected auto|always|never)" }
    }
    if ($useColor -eq 1) {
        $script:COL_RED = "`e[0;31m"
        $script:COL_GREEN = "`e[0;32m"
        $script:COL_YELLOW = "`e[1;33m"
        $script:COL_BLUE = "`e[0;34m"
        $script:COL_MAGENTA = "`e[0;35m"
        $script:COL_CYAN = "`e[0;36m"
        $script:COL_RESET = "`e[0m"
    }
}

#------------------------------------------------------------------------------
# Platform helpers. .NET has no portable link count, inode number or Unix mode,
# so those three probes shell out and degrade to a safe default when the helper
# is missing (documented divergence #3 in the header).
#------------------------------------------------------------------------------
function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT') -or $IsWindows
}

function Test-Have {
    param([string]$Command)
    return [bool](Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-FileSizeBytes {
    param([string]$Path)
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if ($fi.Exists) { return [long]$fi.Length }
    } catch { }
    return [long]0
}

function Get-FileLinkCount {
    param([string]$Path)
    try {
        if (Test-IsWindows) {
            if (-not (Test-Have 'fsutil')) { return 1 }
            $out = & fsutil hardlink list "$Path" 2>$null
            if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return 1 }
            $n = 0
            foreach ($line in @($out)) { if ("$line".Trim().Length -gt 0) { $n++ } }
            if ($n -lt 1) { return 1 }
            return $n
        } else {
            if (-not (Test-Have 'stat')) { return 1 }
            $out = & stat -c '%h' -- "$Path" 2>$null
            if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return 1 }
            $v = 0
            if ([int]::TryParse("$out".Trim(), [ref]$v) -and $v -ge 1) { return $v }
            return 1
        }
    } catch { return 1 }
}

function Get-FileInode {
    param([string]$Path)
    try {
        if (Test-IsWindows) {
            if (-not (Test-Have 'fsutil')) { return '' }
            $out = & fsutil file queryfileid "$Path" 2>$null
            if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return '' }
            return ("$out" -join '').Trim()
        } else {
            if (-not (Test-Have 'stat')) { return '' }
            $out = & stat -c '%i' -- "$Path" 2>$null
            if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return '' }
            return ("$out" -join '').Trim()
        }
    } catch { return '' }
}

# Unix permission bits. .NET 10 (PowerShell 7.6) exposes them natively as
# FileInfo.UnixFileMode, so no external `stat`/`chmod` is involved.
function Get-FileUnixMode {
    param([string]$Path)
    if (Test-IsWindows) { return $null }
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if (-not $fi.Exists) { return $null }
        return $fi.UnixFileMode
    } catch { return $null }
}

function Set-FileUnixMode {
    param([string]$Path, $Mode)
    if (Test-IsWindows -or $null -eq $Mode) { return $false }
    try {
        [System.IO.File]::SetUnixFileMode($Path, $Mode)
        return $true
    } catch { return $false }
}

function Get-FileOwnerIds {
    param([string]$Path)
    if (Test-IsWindows) { return '' }
    if (-not (Test-Have 'stat')) { return '' }
    try {
        $out = & stat -c '%u %g' -- "$Path" 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return '' }
        return ("$out" -join '').Trim()
    } catch { return '' }
}

function Resolve-FullPath {
    # Canonicalise, following symlinks (the readlink -f equivalent).
    param([string]$Path)
    try {
        $r = [System.IO.Path]::ResolveFullLink($Path, $true)
        if ($r) { return $r }
    } catch { }
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if ($fi.Exists) {
            $t = $fi.ResolveLinkTarget($true)
            if ($null -ne $t) { return $t.FullName }
            return $fi.FullName
        }
        $di = [System.IO.DirectoryInfo]::new($Path)
        if ($di.Exists) {
            $t = $di.ResolveLinkTarget($true)
            if ($null -ne $t) { return $t.FullName }
            return $di.FullName
        }
    } catch { }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Test-IsSymlink {
    param([string]$Path)
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if ($fi.Exists) { return ($fi.LinkTarget -ne $null) }
        $di = [System.IO.DirectoryInfo]::new($Path)
        if ($di.Exists) { return ($di.LinkTarget -ne $null) }
    } catch { }
    return $false
}

function Test-IsRegularFile {
    param([string]$Path)
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if (-not $fi.Exists) { return $false }
        return (($fi.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0)
    } catch { return $false }
}

function Test-IsDirectory {
    param([string]$Path)
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

function Test-FileReadable {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $fs.Dispose()
        return $true
    } catch { return $false }
}

function Test-FileWritable {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Write', 'ReadWrite')
        $fs.Dispose()
        return $true
    } catch { return $false }
}

function Test-DirectoryWritable {
    param([string]$Path)
    try {
        $probe = [System.IO.Path]::Combine($Path, ".cleanbom-probe.$($script:SCRIPT_PID)")
        [System.IO.File]::WriteAllText($probe, '')
        [System.IO.File]::Delete($probe)
        return $true
    } catch { return $false }
}

function Check-Dependencies {
    # The cleaner itself is pure .NET, so the only hard requirement is a usable
    # temp directory (rollback copies and self-test fixtures live there).
    $probeDir = [System.IO.Path]::GetTempPath()
    try {
        $probe = [System.IO.Path]::Combine($probeDir, "$($script:SCRIPT_NAME).$($script:SCRIPT_PID).probe")
        [System.IO.File]::WriteAllText($probe, '')
        [System.IO.File]::Delete($probe)
    } catch {
        Write-LogError "No write access to temp directory: $probeDir"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'temp dir')
    }
}

#------------------------------------------------------------------------------
# Byte-exact encoding analysis
#------------------------------------------------------------------------------

# First four bytes as a lowercase hex string ("" for empty files). Reading from
# offset 0 keeps every hex pair byte-aligned, so prefix matching is exact.
function Get-MagicHex {
    param([byte[]]$Content)
    if ($null -eq $Content) { return '' }
    $n = [Math]::Min(4, $Content.Length)
    $sb = [System.Text.StringBuilder]::new($n * 2)
    for ($i = 0; $i -lt $n; $i++) { $null = $sb.Append($Content[$i].ToString('x2')) }
    return $sb.ToString()
}

# Classify the BOM. Order matters: FF FE 00 00 (UTF-32LE) must be tested
# before FF FE (UTF-16LE) because the former extends the latter.
function Get-BomClass {
    param([string]$Magic)
    if ($Magic.StartsWith('efbbbf')) { return 'utf8-bom' }
    if ($Magic.StartsWith('fffe0000')) { return 'utf32le' }
    if ($Magic.StartsWith('fffe')) { return 'utf16le' }
    if ($Magic.StartsWith('feff')) { return 'utf16be' }
    if ($Magic.StartsWith('0000feff')) { return 'utf32be' }
    return 'none'
}

function Test-IsUtf16or32 {
    param([string]$Enc)
    return ($Enc -ceq 'utf16le' -or $Enc -ceq 'utf16be' -or $Enc -ceq 'utf32le' -or $Enc -ceq 'utf32be')
}

# True when the content contains at least one REAL CRLF pair (CR immediately
# before LF), scanned over the whole file - byte-exact, none of the hex-window
# false positives/negatives v2 had.
#
# A CR as the very LAST byte of a file that does not end with LF is NOT a CRLF
# and never flags the file (CR-only "old Mac" files stay untouched) - which
# falls out of IndexOf for free, because such a CR has no following byte.
# When a file IS rewritten because of real CRLFs, a trailing CR at EOF follows
# the documented v2 sed semantics and is removed too.
function Test-HasCrlf {
    param([byte[]]$Content)
    if ($null -eq $Content -or $Content.Length -lt 2) { return $false }
    $i = [System.Array]::IndexOf($Content, [byte]13, 0, $Content.Length - 1)
    while ($i -ge 0) {
        if ($Content[$i + 1] -eq 10) { return $true }
        $next = $i + 1
        if ($next -ge ($Content.Length - 1)) { break }
        $i = [System.Array]::IndexOf($Content, [byte]13, $next, $Content.Length - 1 - $next)
    }
    return $false
}

# True when the content contains NUL bytes (binary data, or UTF-16/32 without
# a BOM).
function Test-HasNul {
    param([byte[]]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $false }
    return ([System.Array]::IndexOf($Content, [byte]0) -ge 0)
}

# True when the whole content is valid UTF-8 (a leading UTF-8 BOM is valid
# UTF-8 - it decodes to U+FEFF). This is the .NET equivalent of
# `iconv -f UTF-8 -t UTF-8`, which the reference uses.
#
# Measured, not assumed: UTF8Encoding.GetByteCount() does NOT validate - it
# happily counts C3 28, ED A0 80 and a lone FF as if they were fine, because
# counting never runs the fallback. GetString() does validate but materialises
# the whole decoded string (up to --max-size). Decoder.Convert() validates
# incrementally into a small char buffer, keeps state across chunks so a
# multi-byte sequence split at a chunk boundary is not a false positive, and
# the final flush:true catches a truncated sequence at EOF.
function Test-IsValidUtf8 {
    param([byte[]]$Content)
    if ($null -eq $Content -or $Content.Length -eq 0) { return $true }
    $decoder = $script:UTF8_STRICT.GetDecoder()
    $chars = [char[]]::new(4096)
    $total = $Content.Length
    $pos = 0
    $chunk = 65536
    try {
        while ($pos -lt $total) {
            $len = [Math]::Min($chunk, $total - $pos)
            $pos = $pos + $len
            $bytesUsed = 0; $charsUsed = 0; $completed = $false
            $decoder.Convert($Content, $pos - $len, $len, $chars, 0, $chars.Length,
                ($pos -ge $total), [ref]$bytesUsed, [ref]$charsUsed, [ref]$completed)
        }
        return $true
    } catch { return $false }
}

# True when the content (AFTER a UTF-8 BOM, if present) contains non-ASCII
# bytes. Used by the Smart BOM Policy for sensitive extensions.
function Test-HasNonAscii {
    param([byte[]]$Content, [string]$Enc)
    $start = 0
    if ($Enc -ceq 'utf8-bom' -and $null -ne $Content -and $Content.Length -ge 3) { $start = 3 }
    if ($null -eq $Content) { return $false }
    for ($i = $start; $i -lt $Content.Length; $i++) {
        if ($Content[$i] -gt 127) { return $true }
    }
    return $false
}

function Get-ExtensionLower {
    param([string]$Path)
    $base = [System.IO.Path]::GetFileName($Path)
    $dot = $base.LastIndexOf('.')
    if ($dot -le 0 -or $dot -eq ($base.Length - 1)) {
        # `case $base in *.*) ext="${base##*.}";; *) ext=""` - a leading dot or
        # a trailing dot yields no extension in the reference.
        if ($dot -eq 0) { return '' }
        if ($dot -eq ($base.Length - 1)) { return '' }
        return ''
    }
    return $base.Substring($dot + 1).ToLowerInvariant()
}

function Test-InList {
    param([string]$Needle, [string]$List)
    foreach ($m in [regex]::Matches($List, '[^\s]+')) {
        if ($m.Value -ceq $Needle) { return $true }
    }
    return $false
}

# strip | sensitive | unknown   (unknown behaves as sensitive while a sensitive
# list exists - the safe default for user-supplied extensions we have no
# consumer knowledge about; --sensitive-ext '' disables sensitivity entirely,
# including for unknown extensions)
function Get-ExtClass {
    param([string]$Ext)
    if ($script:SENSITIVE_EXTS -cne '' -and (Test-InList -Needle $Ext -List $script:SENSITIVE_EXTS)) {
        return 'sensitive'
    }
    if (Test-InList -Needle $Ext -List $script:STRIP_ALWAYS) { return 'strip' }
    return 'unknown'
}

# True when the extension's UTF-8 BOM deserves the "may be required" treatment.
function Test-ClassIsSensitive {
    param([string]$Class)
    if ($Class -ceq 'sensitive') { return $true }
    if ($Class -ceq 'unknown') { return ($script:SENSITIVE_EXTS -cne '') }
    return $false
}

#------------------------------------------------------------------------------
# Transformation core (pure byte functions - the same arithmetic in every port)
#------------------------------------------------------------------------------

# Delete every CR that is immediately followed by LF; additionally delete a CR
# as the final byte of the file (the documented v2 `sed s/\r$//` semantics,
# which only ever runs on a file that is being rewritten anyway). Lone CRs
# mid-line are preserved.
function Convert-CrlfBytes {
    param([byte[]]$Content)
    # Delete every CR that terminates a line, and a CR at EOF, but emit at most
    # one LF per line: a RUN of CRs before the LF collapses into it.
    #
    # The single-CR rule this replaced (`if (next is LF or at EOF) drop the CR`)
    # was NOT idempotent on a run - against the reference it left `x CR CR LF`
    # as `x LF CR LF`, which Test-CleanContentValid below then rejected, so the
    # port logged "Verification failed after cleaning" and refused to write a
    # file it should have cleaned. The reference collapsed the run because sed
    # matched the trailing CR once per pass; this now collapses it explicitly.
    $n = $Content.Length
    $out = [byte[]]::new($n)
    $j = 0
    for ($i = 0; $i -lt $n; $i++) {
        $b = $Content[$i]
        if ($b -eq 13) {
            # Skip the whole run; only its first CR is examined.
            if ($i -gt 0 -and $Content[$i - 1] -eq 13) { continue }
            $k = $i
            while ($k -lt $n -and $Content[$k] -eq 13) { $k++ }
            if ($k -eq $n) { break }                  # the run ends the file
            if ($Content[$k] -ne 10) {
                # A lone CR (mid-line, or a CR-only file): preserved as-is.
                $out[$j] = $b; $j++
                continue
            }
            # Keep the line end exactly once, then resume right after it.
            $out[$j] = 10; $j++
            $i = $k
            continue
        }
        $out[$j] = $b
        $j++
    }
    if ($j -eq $n) { return , $Content }
    $res = [byte[]]::new($j)
    [System.Array]::Copy($out, 0, $res, 0, $j)
    return , $res
}

# Build the cleaned content according to the plan: BOM first, then CRLF
# (equivalently one pass producing identical bytes - contract section 7.3).
function Get-CleanContent {
    param([byte[]]$Content, [int]$StripBom, [int]$FixCrlf)
    $src = $Content
    if ($StripBom -eq 1 -and $src.Length -ge 3) {
        $t = [byte[]]::new($src.Length - 3)
        [System.Array]::Copy($src, 3, $t, 0, $t.Length)
        $src = $t
    }
    if ($FixCrlf -eq 1) {
        $src = Convert-CrlfBytes $src
    }
    # A trailing CR goes only when CRLF normalization ran (Convert-CrlfBytes
    # above handles it). The reference's sed runs on the strip-bom-only path
    # too, but there the input reached that path precisely because it has no
    # `0D 0A` pair, so it cannot end in a CR that terminates a line: a bare CR
    # there is a lone CR and is preserved (measured against the reference - a
    # CR at EOF with no LF keeps its byte on both sides).
    return , $src
}

# Defence in depth: never install content that still violates the plan.
function Test-CleanContentValid {
    param([byte[]]$Content, [int]$StripBom, [int]$FixCrlf)
    if ($StripBom -eq 1) {
        if ((Get-MagicHex $Content).StartsWith('efbbbf')) { return $false }
    }
    if ($FixCrlf -eq 1 -and (Test-HasCrlf $Content)) { return $false }
    return $true
}

#------------------------------------------------------------------------------
# Full-file analysis. Returns a hashtable; verdicts live in the values so the
# caller never confuses "status" with "failure".
#------------------------------------------------------------------------------
function Get-FileAnalysis {
    param([string]$Path)
    $A = @{
        enc = 'none'; hasCrlf = 0; binary = 0; validUtf8 = 1; nonAscii = 0
        candidate = 0; oversize = 0; size = [long]0; ext = ''; extClass = 'unknown'
    }

    $A.size = Get-FileSizeBytes $Path
    if ($A.size -gt $script:MAX_SIZE) {
        $A.oversize = 1
        $script:A = $A
        return $A
    }

    $A.ext = Get-ExtensionLower $Path
    $A.extClass = Get-ExtClass $A.ext

    $content = [System.IO.File]::ReadAllBytes($Path)
    $A.enc = Get-BomClass (Get-MagicHex $content)

    $bomActionable = 0
    if ($A.enc -ceq 'utf8-bom' -and $script:NO_BOM_CLEAR -eq 0) { $bomActionable = 1 }
    $crlfActionable = 1 - $script:NO_CRLF_NORMALIZE

    # UTF-16/UTF-32: the BOM is part of the format. The file becomes a
    # candidate ONLY if a real CRLF was detected (then it must be protected,
    # because v2-style byte tools would corrupt it); otherwise it is clean and
    # stays silent.
    if (Test-IsUtf16or32 $A.enc) {
        if ($crlfActionable -eq 1 -and (Test-HasCrlf $content)) {
            $A.hasCrlf = 1
            $A.candidate = 1
        }
        $script:A = $A
        return $A
    }

    if ($bomActionable -eq 0 -and $crlfActionable -eq 0) {
        $script:A = $A
        return $A   # every transformation disabled - nothing can happen
    }

    if ($crlfActionable -eq 1 -and (Test-HasCrlf $content)) { $A.hasCrlf = 1 }

    if ($bomActionable -eq 0 -and $A.hasCrlf -eq 0) {
        $script:A = $A
        return $A   # clean fast path: no deep scans on a clean tree
    }
    $A.candidate = 1

    # Deep safety checks run ONLY for modification candidates.
    if (Test-HasNul $content) {
        $A.binary = 1
        $script:A = $A
        return $A
    }
    if (-not (Test-IsValidUtf8 $content)) {
        $A.validUtf8 = 0
        $script:A = $A
        return $A
    }
    if ($bomActionable -eq 1 -and (Test-ClassIsSensitive $A.extClass)) {
        if (Test-HasNonAscii -Content $content -Enc $A.enc) { $A.nonAscii = 1 }
    }
    $script:A = $A
    return $A
}

#------------------------------------------------------------------------------
# Policy engine: builds the plan from the analysis + CLI flags.
# The decision table is documented in docs/SMART-BOM.md - keep both in sync.
#------------------------------------------------------------------------------
function Get-FilePlan {
    param($A)
    $P = @{ stripBom = 0; fixCrlf = 0; bomKept = 0; status = 'clean'; reason = '' }

    if ($A.oversize -eq 1) {
        $P.status = 'skip-size'
        $P.reason = "larger than --max-size ($(Format-FileSize $script:MAX_SIZE))"
        $script:P = $P
        return $P
    }
    if ($A.candidate -eq 0) { $script:P = $P; return $P }

    # --- Hard refusals: NEVER modified, not even under --force -------------
    if (Test-IsUtf16or32 $A.enc) {
        $P.status = 'protect'
        $P.reason = "bom-required-$($A.enc)"
        $script:P = $P
        return $P
    }
    if ($A.binary -eq 1) {
        $P.status = 'protect'
        $P.reason = 'binary-nul-bytes'
        $script:P = $P
        return $P
    }
    if ($A.validUtf8 -eq 0 -and $script:FORCE -eq 0) {
        $P.status = 'protect'
        $P.reason = 'invalid-utf8'
        $script:P = $P
        return $P
    }

    # --- BOM action ---------------------------------------------------------
    if ($A.enc -ceq 'utf8-bom' -and $script:NO_BOM_CLEAR -eq 0) {
        switch -CaseSensitive ($script:BOM_POLICY) {
            'keep' {
                $P.stripBom = 0
                $P.bomKept = 1
                $P.reason = 'bom-policy-keep'
            }
            'strip' {
                $P.stripBom = 1
            }
            'auto' {
                if ($script:FORCE -eq 1) {
                    $P.stripBom = 1
                } elseif ((Test-ClassIsSensitive $A.extClass) -and $A.nonAscii -eq 1) {
                    # The BOM may be load-bearing for this file type (Excel /
                    # legacy Notepad / csv tools; Windows PowerShell 5.1 parses
                    # BOM-less non-ASCII scripts as ANSI).
                    $P.stripBom = 0
                    $P.bomKept = 1
                    $P.reason = 'bom-may-be-required'
                } else {
                    $P.stripBom = 1
                }
            }
        }
    }

    # --- CRLF action --------------------------------------------------------
    if ($A.hasCrlf -eq 1 -and $script:NO_CRLF_NORMALIZE -eq 0) {
        if (-not (Test-IsUtf16or32 $A.enc)) { $P.fixCrlf = 1 }   # unreachable: refused above
    }

    # --- Verdict ------------------------------------------------------------
    if ($P.stripBom -eq 1 -or $P.fixCrlf -eq 1) {
        $P.status = 'change'
    } elseif ($P.bomKept -eq 1) {
        $P.status = 'keep'
    } elseif ($A.validUtf8 -eq 0 -and $script:FORCE -eq 0) {
        $P.status = 'protect'
        $P.reason = 'invalid-utf8'
    }
    $script:P = $P
    return $P
}

function Format-FileSize {
    param([long]$Bytes)
    $g = [long]1024 * 1024 * 1024
    $m = [long]1024 * 1024
    if ($Bytes -ge $g -and ($Bytes % $g) -eq 0) { return "$([long]($Bytes / $g))G" }
    if ($Bytes -ge $m -and ($Bytes % $m) -eq 0) { return "$([long]($Bytes / $m))M" }
    if ($Bytes -ge 1024 -and ($Bytes % 1024) -eq 0) { return "$([long]($Bytes / 1024))K" }
    return "${Bytes}B"
}

#------------------------------------------------------------------------------
# JSON helpers (stdout is the machine channel; entries are buffered per line)
#------------------------------------------------------------------------------
function ConvertTo-JsonEscaped {
    # Escapes \, ", control bytes and embedded newlines. Non-ASCII characters
    # are emitted verbatim (the report is UTF-8, exactly like the reference).
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $sb = [System.Text.StringBuilder]::new($Text.Length + 8)
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '\') { $null = $sb.Append('\\') }
        elseif ($ch -eq '"') { $null = $sb.Append('\"') }
        elseif ($code -lt 32) { $null = $sb.Append('\u' + $code.ToString('x4')) }
        else { $null = $sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-JsonBool {
    param([int]$Value)
    if ($Value -eq 1) { return 'true' }
    return 'false'
}

function Add-JsonEntry {
    param([string]$Path, [string]$Status, [string]$Encoding, [string]$Reason,
        [string]$Actions, [int]$BomKept)
    $actionsJson = ''
    if ($Actions -cne '') {
        $first = $true
        foreach ($m in [regex]::Matches($Actions, '[^,]+')) {
            $a = $m.Value
            if ($first) { $first = $false } else { $actionsJson = "$actionsJson, " }
            $actionsJson = "$actionsJson`"$a`""
        }
    }
    $reasonJson = 'null'
    if ($Reason -cne '') { $reasonJson = '"' + (ConvertTo-JsonEscaped $Reason) + '"' }
    $line = '{"path": "' + (ConvertTo-JsonEscaped $Path) + '", "status": "' + $Status +
    '", "encoding": "' + $Encoding + '", "actions": [' + $actionsJson +
    '], "bomKept": ' + (Get-JsonBool $BomKept) + ', "reason": ' + $reasonJson + '}'
    $script:JSON_ENTRIES.Add($line)
}

function Write-JsonReport {
    $dur = [int][Math]::Floor(((Get-Date) - $script:START_TIME).TotalSeconds)
    if ($script:CHECK_MODE -eq 1) { $modeStr = 'check' }
    elseif ($script:DRY_RUN -eq 1) { $modeStr = 'dry-run' }
    else { $modeStr = 'fix' }

    $sb = [System.Text.StringBuilder]::new(1024)
    $null = $sb.Append("{`n")
    $null = $sb.Append("  `"tool`": `"clean-bom-senior`",`n")
    $null = $sb.Append("  `"version`": `"$($script:VERSION)`",`n")
    $null = $sb.Append("  `"mode`": `"$modeStr`",`n")
    $null = $sb.Append("  `"startedAt`": `"$($script:START_TIME_ISO)`",`n")
    $null = $sb.Append("  `"durationSeconds`": $dur,`n")
    $null = $sb.Append("  `"cwd`": `"$(ConvertTo-JsonEscaped (Get-Location).ProviderPath)`",`n")
    $null = $sb.Append("  `"options`": {`n")
    $null = $sb.Append("    `"bomPolicy`": `"$($script:BOM_POLICY)`",`n")
    $null = $sb.Append("    `"noBomClear`": $(Get-JsonBool $script:NO_BOM_CLEAR),`n")
    $null = $sb.Append("    `"noCrlfNormalize`": $(Get-JsonBool $script:NO_CRLF_NORMALIZE),`n")
    $null = $sb.Append("    `"force`": $(Get-JsonBool $script:FORCE),`n")
    $null = $sb.Append("    `"extensions`": `"$(ConvertTo-JsonEscaped $script:EXTENSIONS)`",`n")
    $null = $sb.Append("    `"sensitiveExtensions`": `"$(ConvertTo-JsonEscaped $script:SENSITIVE_EXTS)`",`n")
    $null = $sb.Append("    `"maxSizeBytes`": $($script:MAX_SIZE),`n")
    $null = $sb.Append("    `"keepMtime`": $(Get-JsonBool $script:KEEP_MTIME)`n")
    $null = $sb.Append("  },`n")
    $null = $sb.Append("  `"summary`": {`n")
    $null = $sb.Append("    `"scanned`": $($script:SCANNED_COUNT),`n")
    $null = $sb.Append("    `"changed`": $($script:CHANGED_COUNT),`n")
    $null = $sb.Append("    `"wouldChange`": $($script:WOULD_CHANGE_COUNT),`n")
    $null = $sb.Append("    `"clean`": $($script:CLEAN_COUNT),`n")
    $null = $sb.Append("    `"bomKept`": $($script:KEPT_BOM_COUNT),`n")
    $null = $sb.Append("    `"bomRemoved`": $($script:BOM_REMOVED_COUNT),`n")
    $null = $sb.Append("    `"crlfFixed`": $($script:CRLF_FIXED_COUNT),`n")
    $null = $sb.Append("    `"protectedUtf16or32`": $($script:PROTECTED_UTF16_COUNT),`n")
    $null = $sb.Append("    `"protectedBinary`": $($script:PROTECTED_BINARY_COUNT),`n")
    $null = $sb.Append("    `"protectedInvalidUtf8`": $($script:PROTECTED_INVALID_COUNT),`n")
    $null = $sb.Append("    `"skippedOversize`": $($script:SKIPPED_SIZE_COUNT),`n")
    $null = $sb.Append("    `"errors`": $($script:ERROR_COUNT)`n")
    $null = $sb.Append("  },`n")
    $null = $sb.Append("  `"files`": [`n")
    $entries = @($script:JSON_ENTRIES)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $sep = if ($i -lt ($entries.Count - 1)) { ',' } else { '' }
        $null = $sb.Append("    $($entries[$i])$sep`n")
    }
    $null = $sb.Append("  ]`n")
    $null = $sb.Append("}`n")
    Write-StdOut $sb.ToString()
}

#------------------------------------------------------------------------------
# Transformation (atomic, attribute-preserving, verified, with rollback)
#------------------------------------------------------------------------------
function Set-FileAttributes {
    # $Donor = the original, $Target = the temp file that will replace it.
    param([string]$Donor, [string]$Target)
    if (-not (Test-IsWindows)) {
        $mode = Get-FileUnixMode $Donor
        if ($null -ne $mode) {
            if (-not (Set-FileUnixMode -Path $Target -Mode $mode)) {
                Write-LogWarn "Could not set permissions ($mode) on: $Target"
            }
        }
        try {
            if ($env:USER -ceq 'root' -and (Test-Have 'chown')) {
                $ids = Get-FileOwnerIds $Donor
                if ($ids -cne '') {
                    $parts = @([regex]::Matches($ids, '[^\s]+') | ForEach-Object { $_.Value })
                    $null = & chown "$($parts[0]):$($parts[1])" -- "$Target" 2>$null
                    if ($LASTEXITCODE -ne 0) { Write-LogWarn "Could not set ownership ($ids) on: $Target" }
                }
            }
        } catch { }
    }
    if ($script:KEEP_MTIME -eq 1) {
        # Copy atime+mtime from the ORIGINAL onto the temp file BEFORE the
        # atomic rename, so the replacement inode carries the old times.
        # (v2 stamped "now" here and the documented preservation never
        # happened - contract section 7.5.)
        try {
            $fi = [System.IO.FileInfo]::new($Donor)
            $to = [System.IO.FileInfo]::new($Target)
            $to.LastWriteTime = $fi.LastWriteTime
            $to.LastAccessTime = $fi.LastAccessTime
        } catch { Write-LogWarn "Could not preserve timestamps on: $Target" }
    }
}

function New-BackupCopy {
    param([string]$Path)
    if ($script:BACKUP_DIR -cne '') {
        $rel = $Path
        if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
        $root = $script:BACKUP_DIR.TrimEnd([char]'/')
        if ((Test-IsWindows) -and $root.EndsWith('\')) { $root = $root.TrimEnd([char]'\') }
        $dest = [System.IO.Path]::Combine($root, $rel)
        try {
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dest))
        } catch { }
    } else {
        $dest = "$Path.bak.$($script:SCRIPT_PID)"
    }
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        [System.IO.File]::Copy($Path, $dest, $true)
        $di = [System.IO.FileInfo]::new($dest)
        $di.LastWriteTime = $fi.LastWriteTime
        $di.LastAccessTime = $fi.LastAccessTime
        Write-LogProcessing "Backup saved: $dest"
    } catch {
        Write-LogWarn "Could not create backup for: $Path (continuing without it)"
    }
}

# In-place rewrite preserving the inode (hard-linked files; fallback when the
# parent directory is not writable). Keeps a rollback copy until success.
function Write-InPlace {
    param([string]$Path, [byte[]]$Content)
    $rollback = ''
    try {
        $rollback = [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "$($script:SCRIPT_NAME).rb.$($script:SCRIPT_PID).$([System.IO.Path]::GetRandomFileName())")
        Register-TempFile $rollback
        [System.IO.File]::Copy($Path, $rollback, $true)
        $fi = [System.IO.FileInfo]::new($Path)
        $mtime = $fi.LastWriteTime
        $atime = $fi.LastAccessTime
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $fs.Write($Content, 0, $Content.Length) } finally { $fs.Dispose() }
        if ($script:KEEP_MTIME -eq 1) {
            $fi2 = [System.IO.FileInfo]::new($Path)
            $fi2.LastWriteTime = $mtime
            $fi2.LastAccessTime = $atime
        }
        [System.IO.File]::Delete($rollback)
        return $true
    } catch {
        if ($rollback -cne '') {
            try {
                [System.IO.File]::Copy($rollback, $Path, $true)   # rollback
                [System.IO.File]::Delete($rollback)
            } catch { }
        }
        return $false
    }
}

function Invoke-FileTransform {
    # $Path = REAL path of the file to rewrite (the plan is already computed).
    param([string]$Path, [byte[]]$Content, [int]$StripBom, [int]$FixCrlf)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $temp = ''
    try {
        $temp = [System.IO.Path]::Combine($dir, ".cleanbom.$($script:SCRIPT_PID).$([System.IO.Path]::GetRandomFileName())")
        [System.IO.File]::WriteAllBytes($temp, [byte[]]::new(0))
    } catch { $temp = '' }

    if ($temp -ceq '') {
        # Directory not writable - fall back to a guarded in-place rewrite.
        if (Test-FileWritable $Path) {
            Write-LogWarn "Directory not writable, rewriting in place (non-atomic): $Path"
            $cleaned = Get-CleanContent -Content $Content -StripBom $StripBom -FixCrlf $FixCrlf
            if (-not (Test-CleanContentValid -Content $cleaned -StripBom $StripBom -FixCrlf $FixCrlf)) {
                Write-LogError "Verification failed after cleaning (file NOT modified): $Path"
                $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
                return $false
            }
            if ($script:BACKUP -eq 1) { New-BackupCopy $Path }
            if (Write-InPlace -Path $Path -Content $cleaned) { return $true }
            Write-LogError "In-place rewrite failed (original restored): $Path"
            $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
            return $false
        }
        Write-LogError "Cannot create temp file next to: $Path (directory not writable)"
        $script:ERR_ACCESS = $script:ERR_ACCESS + 1
        return $false
    }
    Register-TempFile $temp

    $cleaned = Get-CleanContent -Content $Content -StripBom $StripBom -FixCrlf $FixCrlf
    try { [System.IO.File]::WriteAllBytes($temp, $cleaned) } catch {
        Write-LogError "Failed to process file content: $Path"
        $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
        try { [System.IO.File]::Delete($temp) } catch { }
        return $false
    }
    if (-not (Test-CleanContentValid -Content $cleaned -StripBom $StripBom -FixCrlf $FixCrlf)) {
        Write-LogError "Verification failed after cleaning (file NOT modified): $Path"
        $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
        try { [System.IO.File]::Delete($temp) } catch { }
        return $false
    }

    if ($script:BACKUP -eq 1) { New-BackupCopy $Path }

    $nlink = Get-FileLinkCount $Path
    if ($nlink -gt 1) {
        # Hard-linked: an atomic rename would silently detach the other links.
        # Rewrite through the inode so every link sees the fix.
        Write-LogWarn "File has $nlink hard links __EMDASH__ rewriting in place to keep them intact: $Path"
        if (Write-InPlace -Path $Path -Content $cleaned) {
            try { [System.IO.File]::Delete($temp) } catch { }
            return $true
        }
        Write-LogError "In-place rewrite failed (original restored): $Path"
        $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
        try { [System.IO.File]::Delete($temp) } catch { }
        return $false
    }

    Set-FileAttributes -Donor $Path -Target $temp

    try {
        [System.IO.File]::Move($temp, $Path, $true)
        return $true
    } catch { }

    # Atomic rename failed (e.g. permissions flipped under us): try in place.
    if (Test-FileWritable $Path) {
        Write-LogWarn "Atomic replace failed, retrying in place: $Path"
        if (Write-InPlace -Path $Path -Content $cleaned) {
            try { [System.IO.File]::Delete($temp) } catch { }
            return $true
        }
    }
    Write-LogError "Failed to replace file (original untouched): $Path"
    $script:ERR_PROCESSING = $script:ERR_PROCESSING + 1
    try { [System.IO.File]::Delete($temp) } catch { }
    return $false
}

#------------------------------------------------------------------------------
# Per-file driver
#------------------------------------------------------------------------------
function Invoke-FileHandling {
    # $Display = path as displayed/logged; $Path = real path to operate on
    # (usually the same; differs for symlink arguments, which are resolved).
    param([string]$Display, [string]$Path)

    $script:SCANNED_COUNT = $script:SCANNED_COUNT + 1

    if (-not (Test-IsRegularFile $Path)) {
        Write-LogError "File not found: $Display"
        $script:ERR_ACCESS = $script:ERR_ACCESS + 1
        return $false
    }
    if (-not (Test-FileReadable $Path)) {
        Write-LogError "Cannot read file: $Display"
        $script:ERR_ACCESS = $script:ERR_ACCESS + 1
        return $false
    }

    $A = Get-FileAnalysis $Path
    $P = Get-FilePlan $A

    switch -CaseSensitive ($P.status) {
        'clean' {
            $script:CLEAN_COUNT = $script:CLEAN_COUNT + 1
            Write-LogProcessing "No issues detected, skipping: $Display"
            return $true
        }
        'skip-size' {
            $script:SKIPPED_SIZE_COUNT = $script:SKIPPED_SIZE_COUNT + 1
            Write-LogInfo "Skipped (oversize, $(Format-FileSize $A.size) > $(Format-FileSize $script:MAX_SIZE)): $Display"
            Add-JsonEntry -Path $Display -Status 'skipped-size' -Encoding $A.enc -Reason $P.reason -Actions '' -BomKept 0
            return $true
        }
        'protect' {
            switch -Wildcard ($P.reason) {
                'bom-required-*' {
                    $script:PROTECTED_UTF16_COUNT = $script:PROTECTED_UTF16_COUNT + 1
                    Write-LogWarn "NOT touched __EMDASH__ $($A.enc) BOM is structurally required; stripping it would corrupt the file (convert with iconv if UTF-8 is needed): $Display"
                }
                'binary-nul-bytes' {
                    $script:PROTECTED_BINARY_COUNT = $script:PROTECTED_BINARY_COUNT + 1
                    Write-LogWarn "NOT touched __EMDASH__ contains NUL bytes (binary data or BOM-less UTF-16): $Display"
                }
                'invalid-utf8' {
                    $script:PROTECTED_INVALID_COUNT = $script:PROTECTED_INVALID_COUNT + 1
                    Write-LogWarn "NOT touched __EMDASH__ content is not valid UTF-8; pass --force for byte-level cleaning: $Display"
                }
            }
            Add-JsonEntry -Path $Display -Status 'protected' -Encoding $A.enc -Reason $P.reason -Actions '' -BomKept 0
            return $true
        }
        'keep' {
            $script:KEPT_BOM_COUNT = $script:KEPT_BOM_COUNT + 1
            Write-LogInfo "BOM kept (may be required for .$($A.ext) with non-ASCII content; --force strips it): $Display"
            Add-JsonEntry -Path $Display -Status 'kept' -Encoding $A.enc -Reason $P.reason -Actions '' -BomKept 1
            return $true
        }
    }

    # P.status == change ------------------------------------------------------
    $actions = ''
    if ($P.stripBom -eq 1) { $actions = 'strip-bom' }
    if ($P.fixCrlf -eq 1) {
        if ($actions -cne '') { $actions = "$actions,crlf-to-lf" } else { $actions = 'crlf-to-lf' }
    }
    $actionsPlus = $actions -creplace ',', ' + '

    if ($script:DRY_RUN -eq 1 -or $script:CHECK_MODE -eq 1) {
        $script:WOULD_CHANGE_COUNT = $script:WOULD_CHANGE_COUNT + 1
        if ($P.bomKept -eq 1) { $script:KEPT_BOM_COUNT = $script:KEPT_BOM_COUNT + 1 }
        $script:AFFECTED_FILES.Add($Display)
        if ($script:VERBOSE_ON -eq 1) {
            $extra = ''
            if ($P.bomKept -eq 1) { $extra = '; BOM kept: may be required' }
            Write-StdErr "Would process: $Display (actions: $actionsPlus; encoding: $($A.enc)$extra)`n"
        }
        Add-JsonEntry -Path $Display -Status 'would-change' -Encoding $A.enc -Reason $P.reason -Actions $actions -BomKept $P.bomKept
        return $true
    }

    Write-LogProcessing "Processing: $Display (actions: $actionsPlus, encoding: $($A.enc))"
    if ($A.validUtf8 -eq 0) {
        Write-LogWarn "--force: byte-level cleaning of invalid-UTF-8 file: $Display"
    }

    $content = [System.IO.File]::ReadAllBytes($Path)
    if (Invoke-FileTransform -Path $Path -Content $content -StripBom $P.stripBom -FixCrlf $P.fixCrlf) {
        $script:CHANGED_COUNT = $script:CHANGED_COUNT + 1
        if ($P.stripBom -eq 1) { $script:BOM_REMOVED_COUNT = $script:BOM_REMOVED_COUNT + 1 }
        if ($P.fixCrlf -eq 1) { $script:CRLF_FIXED_COUNT = $script:CRLF_FIXED_COUNT + 1 }
        if ($P.bomKept -eq 1) {
            $script:KEPT_BOM_COUNT = $script:KEPT_BOM_COUNT + 1
            Write-LogInfo "BOM kept (may be required for .$($A.ext)); CRLF normalised: $Display"
        }
        $extName = $A.ext
        if ($extName -ceq '') { $extName = 'other' }
        $script:CHANGED_EXT_LINES.Add($extName)
        $script:AFFECTED_FILES.Add($Display)
        Add-JsonEntry -Path $Display -Status 'changed' -Encoding $A.enc -Reason $P.reason -Actions $actions -BomKept $P.bomKept
        Write-LogSuccess "Successfully processed: $Display ($actionsPlus)"
        return $true
    }

    Add-JsonEntry -Path $Display -Status 'error' -Encoding $A.enc -Reason 'transform-failed' -Actions $actions -BomKept $P.bomKept
    return $false
}

#------------------------------------------------------------------------------
# Selection / walking
#------------------------------------------------------------------------------
function Test-PathExcluded {
    param([string]$Path)
    $p2 = $Path
    if ($p2.StartsWith('./')) { $p2 = $p2.Substring(2) }   # users write --exclude 'dist/*', the walk prints './dist/x'
    foreach ($pat in $script:EXCLUDE_PATTERNS) {
        if ($pat -cne '') {
            # -clike, not -like: PowerShell wildcards are case-INsensitive by
            # default, the shell `case $path in $pat)` is not. `*` matches
            # across directory separators in both.
            if ($Path -clike $pat) { return $true }
            if ($p2 -clike $pat) { return $true }
        }
    }
    foreach ($m in [regex]::Matches($script:EXCLUDE_DIRS, '[^\s]+')) {
        if (("/$Path/").Contains("/$($m.Value)/")) { return $true }
    }
    return $false
}

function Test-SupportedExtension {
    param([string]$Path)
    return (Test-InList -Needle (Get-ExtensionLower $Path) -List $script:EXTENSIONS)
}

# Ordinal (bytewise) sort, equivalent to the reference's `sort` / `sort -z`
# under LC_ALL=C.
#
# Implemented as an LSD radix sort rather than [System.Array]::Sort with a
# [System.Comparison[string]] delegate, and that is not a stylistic choice:
# when .NET invokes a PowerShell script block as a delegate, the block cannot
# resolve script-scope FUNCTIONS, so a comparer that calls one silently returns
# $null, every comparison reads as "equal", and the sort becomes a no-op that
# leaves the input in enumeration order. The failure is invisible except as
# wrong output ordering. A radix sort needs no delegate and no comparer.
#
# Costs O(passes * n) with passes bounded by the longest string, uses only
# integer keys, and - crucially - is deterministic across .NET versions, whose
# introsort is not stable and whose string comparison is culture-sensitive.
function Sort-Ordinal {
    param([string[]]$Items)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($x in $Items) { $list.Add($x) }
    if ($list.Count -lt 2) { return , $list.ToArray() }

    $maxLen = 0
    foreach ($x in $list) { if ($x.Length -gt $maxLen) { $maxLen = $x.Length } }

    for ($pos = $maxLen - 1; $pos -ge 0; $pos--) {
        $buckets = New-Object 'System.Collections.Generic.List[string][]' 257
        for ($b = 0; $b -lt 257; $b++) {
            $buckets[$b] = New-Object System.Collections.Generic.List[string]
        }
        foreach ($x in $list) {
            # bucket 256 = "no character at this position", i.e. the shortest
            # strings, which sort first when they are a prefix of a longer one
            $key = if ($x.Length -gt $pos) { [int]$x[$pos] } else { 256 }
            $buckets[$key].Add($x)
        }
        $list.Clear()
        for ($b = 0; $b -lt 257; $b++) {
            foreach ($x in $buckets[$b]) { $list.Add($x) }
        }
    }
    return , $list.ToArray()
}


# Depth-first walk that never follows symlinks (files or directories), skips
# empty files, prunes excluded directories and filters by extension - the
# `find DIR ( -name X -prune ) -o -type f \( -iname '*.ext' \) -size +0c`
# equivalent. Results are sorted afterwards (the reference pipes into sort -z).
#
# Each hit is returned as Display + Real, built by explicit "$dir/$name"
# concatenation. Neither may come from Path.Combine: Combine('.', 'a.php')
# yields 'a.php', dropping the './' that the v2 display contract requires, and
# EnumerateFileSystemEntries('.') itself yields 'src', not './src'.
function Get-WalkFiles {
    param([string]$Root, [string]$Prefix)
    $result = New-Object System.Collections.Generic.List[object]
    $exts = @([regex]::Matches($script:EXTENSIONS, '[^\s]+') | ForEach-Object { $_.Value })
    $rootPrefix = if ($Prefix -ceq '') { '.' } else { $Prefix }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Real = $Root; Prefix = $rootPrefix })
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $dir = $node.Real
        $dprefix = $node.Prefix
        $entries = @()
        try {
            $entries = [System.IO.Directory]::EnumerateFileSystemEntries($dir)
        } catch { continue }
        $subdirs = New-Object System.Collections.Generic.List[object]
        foreach ($e in $entries) {
            try {
                $name = [System.IO.Path]::GetFileName($e)
                $real = "$dir/$name"
                $disp = "$dprefix/$name"
                $isLink = $false
                $isDir = $false
                $fi = [System.IO.FileInfo]::new($real)
                if ($fi.Exists) {
                    $isDir = $false
                    $isLink = ($null -ne $fi.LinkTarget)
                } else {
                    $di = [System.IO.DirectoryInfo]::new($real)
                    if (-not $di.Exists) { continue }
                    $isDir = $true
                    $isLink = ($null -ne $di.LinkTarget)
                }

                if ($isDir) {
                    if ($isLink) { continue }          # find never follows symlinked dirs
                    $pruned = $false
                    foreach ($m in [regex]::Matches($script:EXCLUDE_DIRS, '[^\s]+')) {
                        if ($name -ceq $m.Value) { $pruned = $true; break }
                    }
                    if ($pruned) { continue }
                    $subdirs.Add([pscustomobject]@{ Real = $real; Prefix = $disp })
                    continue
                }
                if ($isLink) { continue }              # -type f excludes symlinks
                if ($fi.Length -le 0) { continue }     # -size +0c
                $ext = Get-ExtensionLower $name
                $match = $false
                foreach ($x in $exts) { if ($ext -ceq $x) { $match = $true; break } }
                if (-not $match) { continue }

                $result.Add([pscustomobject]@{ Display = $disp; Real = $real })
            } catch { continue }
        }
        foreach ($sd in $subdirs) { $stack.Push($sd) }
    }
    # Sort by the DISPLAY path. Sort-Ordinal takes strings, so the hits are
    # ordered through a parallel index array. A hashtable keyed by path would
    # be wrong here: PowerShell hashtables compare keys case-INsensitively,
    # and two files differing only in case are distinct on Unix.
    $hits = $result.ToArray()
    $displays = [string[]]::new($hits.Count)
    for ($i = 0; $i -lt $hits.Count; $i++) { $displays[$i] = $hits[$i].Display }
    $idx = [int[]]::new($hits.Count)
    for ($i = 0; $i -lt $idx.Count; $i++) { $idx[$i] = $i }

    # LSD radix sort over the index array, keyed by the display path - same
    # algorithm and the same reasoning as Sort-Ordinal (see the comment there).
    $maxLen = 0
    foreach ($d in $displays) { if ($d.Length -gt $maxLen) { $maxLen = $d.Length } }
    for ($pos = $maxLen - 1; $pos -ge 0; $pos--) {
        $buckets = New-Object 'System.Collections.Generic.List[int][]' 257
        for ($b = 0; $b -lt 257; $b++) { $buckets[$b] = New-Object System.Collections.Generic.List[int] }
        foreach ($k in $idx) {
            $key = if ($displays[$k].Length -gt $pos) { [int]$displays[$k][$pos] } else { 256 }
            $buckets[$key].Add($k)
        }
        $n = 0
        for ($b = 0; $b -lt 257; $b++) { foreach ($k in $buckets[$b]) { $idx[$n] = $k; $n++ } }
    }
    $ordered = [object[]]::new($hits.Count)
    for ($i = 0; $i -lt $idx.Count; $i++) { $ordered[$i] = $hits[$idx[$i]] }
    return , $ordered
}

function Invoke-DirectoryScan {
    param([string]$Dir, [string]$Prefix)
    Write-LogProcessing "Scanning directory: $Dir"
    foreach ($hit in (Get-WalkFiles -Root $Dir -Prefix $Prefix)) {
        if (Test-PathExcluded $hit.Display) { continue }
        if (-not (Invoke-FileHandling -Display $hit.Display -Path $hit.Real)) { $script:FILE_ERRORS = 1 }
    }
}

function Invoke-GitScan {
    if (-not (Test-Have 'git')) { Stop-Env '--git requires git(1) in PATH' }
    $rv = (& git rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $rv -cne 'true') {
        Stop-Env '--git: current directory is not inside a git work tree'
    }
    Write-LogInfo 'Git mode: processing tracked files only'
    $pathspec = @($script:GIT_PATHSPEC)
    if ($pathspec.Count -gt 0) {
        $raw = & git ls-files -z -- @pathspec 2>$null
    } else {
        $raw = & git ls-files -z 2>$null
    }
    $joined = ($raw -join '')
    $files = @()
    if ($joined -cne '') {
        $files = @([regex]::Matches($joined, '[^\0]+') | ForEach-Object { $_.Value })
    }
    foreach ($f in (Sort-Ordinal ([string[]]@($files)))) {
        if (-not (Test-IsRegularFile $f)) { continue }
        if (-not (Test-SupportedExtension $f)) { continue }
        if (Test-PathExcluded $f) { continue }
        if (-not (Invoke-FileHandling -Display $f -Path $f)) { $script:FILE_ERRORS = 1 }
    }
}

#------------------------------------------------------------------------------
# Reports
#------------------------------------------------------------------------------
function Write-ExtDistribution {
    if ($script:CHANGED_EXT_LINES.Count -eq 0) { return }
    $groups = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($e in $script:CHANGED_EXT_LINES) {
        $key = if ($e -ceq '') { 'other' } else { $e }
        if ($groups.ContainsKey($key)) { $groups[$key] = $groups[$key] + 1 } else { $groups[$key] = 1 }
    }
    # `sort | uniq -c` orders by the extension name; LC_ALL=C means ordinal.
    # Hashtable key order is randomised per process, so this sort is load
    # bearing: without it the report order changes from run to run.
    foreach ($k in (Sort-Ordinal ([string[]]@($groups.Keys)))) {
        if ($k -ceq '' -or $k -ceq 'other') { Write-StdErr "Other files: $($groups[$k])`n" }
        else { Write-StdErr ".$k files: $($groups[$k])`n" }
    }
}

function Write-Statistics {
    $elapsed = [int][Math]::Floor(((Get-Date) - $script:START_TIME).TotalSeconds)

    Write-StdErr "`n$($script:COL_MAGENTA)=== PROCESSING SUMMARY ===$($script:COL_RESET)`n"
    Write-StdErr "Execution time: $elapsed seconds`n"
    Write-StdErr "Files scanned: $($script:SCANNED_COUNT)`n"
    if ($script:DRY_RUN -eq 1 -or $script:CHECK_MODE -eq 1) {
        Write-StdErr "Files that would be processed: $($script:WOULD_CHANGE_COUNT)`n"
    } else {
        Write-StdErr "Files processed: $($script:CHANGED_COUNT)`n"
    }
    Write-StdErr "Files skipped (clean): $($script:CLEAN_COUNT)`n"
    Write-StdErr "Errors encountered: $($script:ERROR_COUNT)`n"

    if ($script:CHANGED_COUNT -gt 0) {
        Write-StdErr "`n$($script:COL_CYAN)--- Issues Fixed ---$($script:COL_RESET)`n"
        Write-StdErr "BOM signatures removed: $($script:BOM_REMOVED_COUNT)`n"
        Write-StdErr "CRLF line endings fixed: $($script:CRLF_FIXED_COUNT)`n"
        Write-StdErr "`n$($script:COL_CYAN)--- File Type Distribution ---$($script:COL_RESET)`n"
        Write-ExtDistribution
    }

    $keptTotal = $script:KEPT_BOM_COUNT + $script:PROTECTED_UTF16_COUNT +
    $script:PROTECTED_BINARY_COUNT + $script:PROTECTED_INVALID_COUNT + $script:SKIPPED_SIZE_COUNT
    if ($keptTotal -gt 0) {
        Write-StdErr "`n$($script:COL_YELLOW)--- Protected / Kept Unchanged (Smart BOM Policy) ---$($script:COL_RESET)`n"
        if ($script:KEPT_BOM_COUNT -gt 0) { Write-StdErr "UTF-8 BOM kept (may be required): $($script:KEPT_BOM_COUNT)`n" }
        if ($script:PROTECTED_UTF16_COUNT -gt 0) { Write-StdErr "UTF-16/UTF-32 files (BOM required): $($script:PROTECTED_UTF16_COUNT)`n" }
        if ($script:PROTECTED_BINARY_COUNT -gt 0) { Write-StdErr "Binary files (NUL bytes): $($script:PROTECTED_BINARY_COUNT)`n" }
        if ($script:PROTECTED_INVALID_COUNT -gt 0) { Write-StdErr "Invalid UTF-8 files: $($script:PROTECTED_INVALID_COUNT)`n" }
        if ($script:SKIPPED_SIZE_COUNT -gt 0) { Write-StdErr "Oversize files skipped: $($script:SKIPPED_SIZE_COUNT)`n" }
    }

    if ($script:ERROR_COUNT -gt 0) {
        Write-StdErr "`n$($script:COL_RED)--- Error Breakdown ---$($script:COL_RESET)`n"
        Write-StdErr "Access errors: $($script:ERR_ACCESS)`n"
        Write-StdErr "Processing errors: $($script:ERR_PROCESSING)`n"
        Write-StdErr "Other errors: $($script:ERR_OTHER)`n"
    }

    if (($script:DRY_RUN -eq 1 -or $script:CHECK_MODE -eq 1) -and $script:WOULD_CHANGE_COUNT -gt 0) {
        Write-StdErr "`n$($script:COL_YELLOW)--- Files That Would Be Processed ---$($script:COL_RESET)`n"
        foreach ($f in $script:AFFECTED_FILES) { Write-StdErr "$f`n" }
    }

    Write-StdErr "`n$($script:COL_GREEN)Processing completed at: $(Get-Timestamp)$($script:COL_RESET)`n"
}

function Write-Greeting {
    $M = $script:COL_MAGENTA
    $B = $script:COL_BLUE
    $C = $script:COL_CYAN
    $G = $script:COL_GREEN
    $R = $script:COL_RESET

    Write-StdErr "`n$M=== UTF-8 BOM & CRLF Cleaner v$($script:VERSION) ===$R`n"
    Write-StdErr ("$B" + 'Author:' + "$R Mikhail Deynekin (mid1977@gmail.com)`n")
    Write-StdErr ("$B" + 'Website:' + "$R https://deynekin.com`n")
    Write-StdErr ("$B" + 'Started:' + "$R $(Get-Timestamp)`n")
    Write-StdErr "`n$C--- Configuration ---$R`n"
    Write-StdErr ("Verbose mode: " + $(if ($script:VERBOSE_ON -eq 1) { 'ENABLED' } else { 'DISABLED' }) + "`n")
    if ($script:CHECK_MODE -eq 1) {
        Write-StdErr "Check mode: ENABLED (no files will be modified)`n"
    } elseif ($script:DRY_RUN -eq 1) {
        Write-StdErr "Dry-run mode: ENABLED (no files will be modified)`n"
    }
    Write-StdErr ("BOM removal: " + $(if ($script:NO_BOM_CLEAR -eq 1) { 'DISABLED' } else { 'ENABLED' }) + "`n")
    Write-StdErr ("CRLF normalization: " + $(if ($script:NO_CRLF_NORMALIZE -eq 1) { 'DISABLED' } else { 'ENABLED' }) + "`n")
    if ($script:BOM_POLICY -ceq 'auto') {
        Write-StdErr "BOM policy: auto (smart: keep BOM where it may be required)`n"
    } else {
        Write-StdErr "BOM policy: $($script:BOM_POLICY)`n"
    }
    Write-StdErr ("Force mode: " + $(if ($script:FORCE -eq 1) { 'ENABLED' } else { 'DISABLED' }) + "`n")
    Write-StdErr ("Timestamps of modified files: " + $(if ($script:KEEP_MTIME -eq 1) { 'PRESERVED' } else { 'UPDATED' }) + "`n")
    Write-StdErr "Supported extensions: $($script:EXTENSIONS)`n"
    Write-StdErr "Maximum file size: $(Format-FileSize $script:MAX_SIZE)`n"
    if ($script:EXCLUDE_DIRS -cne '') {
        Write-StdErr "Excluded directories: $($script:EXCLUDE_DIRS)`n"
    }
    Write-StdErr ("`n$G" + 'Starting file processing...' + "$R`n`n")
}

#------------------------------------------------------------------------------
# Help system ( --help [TOPIC] )
#------------------------------------------------------------------------------
function Get-HelpTopicsList {
    return 'usage options bom-policy safety exit-codes examples env ci update files json compatibility'
}

function Write-HelpHeader {
    Write-StdOut "Clean BOM Senior v$($script:VERSION) __EMDASH__ UTF-8 BOM & CRLF Cleaner with Smart BOM Policy`n"
    Write-StdOut "Repository: https://github.com/paulmann/Clean_BOM_Senior`n`n"
}

# BEGIN GENERATED HELP (scripts/gen-ps-help.py)
# The help topics are part of the CLI contract (docs/CLI-CONTRACT.md) and
# must stay byte-identical across implementations, so they are derived from
# the shell reference rather than hand-copied. Edit clean-bom-senior.sh,
# then re-run:  python3 scripts/gen-ps-help.py
# `scripts/check-version-consistency.sh` and CI fail on drift.
function Write-HelpUsage {
    $S = $script:SCRIPT_NAME
    $V = $script:VERSION
    $REPO = $script:REPO_SLUG_DEFAULT
    Write-StdOut @"
USAGE
    $S [OPTIONS] [PATH...]

    PATH may be a file or a directory (directories are scanned recursively).
    With no PATH, the current directory is scanned recursively.
    Default exclusions: .git, .svn, .hg, node_modules (--no-default-excludes
    to lift them; --exclude / --exclude-dir to add your own).

QUICK START
    $S                     clean the current tree (smart, safe defaults)
    $S --check             CI gate: exit 10 when anything needs cleaning
    $S --dry-run           preview: what would change, and why
    $S --json              machine-readable report on stdout
    $S src index.php       clean a directory and a file
    $S --help bom-policy   the Smart BOM Policy in detail

"@
}

function Write-HelpOptions {
    Write-StdOut @'
OPTIONS
  Operation
    -n, --dry-run            Analyse and report, modify nothing (implies -v)
    -c, --check              CI gate: like --dry-run but terse; exit 10 if any
                             file needs cleaning, 0 if the tree is clean
    -f, --fix                Clean (the default mode; exists for explicitness)
    -v, --verbose            Per-file processing log
    -q, --quiet              No greeting/summary; warnings and errors only
        --silent             Errors only
    -j, --json               JSON report on stdout (schema: --help json)
        --color WHEN         auto | always | never (honours NO_COLOR,
                             CLICOLOR_FORCE)
        --no-color           Alias for --color=never
        --log-file FILE      Append the full log to FILE

  Selection
        --ext LIST           Comma-separated extensions REPLACING the defaults
                             (default: php,css,js,txt,xml,htm,html)
        --add-ext LIST       Comma-separated extensions ADDED to the defaults
        --exclude GLOB       Repeatable; skip paths matching GLOB
                             (e.g. --exclude 'dist/*' --exclude '*/vendor/*')
        --exclude-dir NAME   Repeatable; never descend into directory NAME
        --no-default-excludes  Descend into .git/.svn/.hg/node_modules too
        --max-size SPEC      Skip files larger than SPEC (default 100M;
                             accepts 512K, 10M, 1G, or a byte count)
        --git                Process only git-tracked files (needs git; PATH
                             arguments become git pathspecs)

  Smart BOM Policy (the safety core __EMDASH__ details: --help bom-policy)
        --bom-policy POL     auto (default) | strip | keep
        --sensitive-ext LIST Comma-separated; extensions whose UTF-8 BOM may be
                             required (default: txt,csv,tsv,ps1,psm1,psd1;
                             an empty list disables sensitivity)
        --force              Strip "may-be-required" BOMs anyway and clean
                             invalid-UTF-8 files at byte level. NEVER
                             overrides hard refusals (UTF-16/32, NUL-binary).

  Transformation
        --no-bom-clear       Do not remove any BOM (v2 compatible)
        --no-rn-normalize    Do not normalise CRLF (v2 compatible name)
        --no-crlf-normalize  Same flag, clearer name
        --update-mtime       Set a fresh mtime on modified files (default:
        --no-keep-mtime      original timestamps are preserved)
        --backup             Keep a backup of every modified file
                             (<file>.bak.<pid> next to the original)
        --backup-dir DIR     Implies --backup; copies mirror the tree in DIR

  Information / maintenance
    -h, --help               Full help; --help TOPIC for one section
        --help TOPIC         Topics: usage options bom-policy safety
                             exit-codes examples env ci update files json
                             compatibility
    -V, --version            Version information
        --check-update       Query the repository; exit 11 if a newer version
                             exists, 0 if up to date
        --update             Self-update from the repository (--help update)
        --self-test          Run the built-in fixture test-suite and report
        --completion         Print a PowerShell completion script
        --strict             Exit 1 if anything was kept/protected/skipped
                             (CI gate for "the tree is fully cleanable")
    --                       End of options (paths may start with '-')

'@
}

function Write-HelpBomPolicy {
    Write-StdOut @'
SMART BOM POLICY __EMDASH__ "does this file actually NEED cleaning, and is its BOM
perhaps load-bearing?"   (full rationale: docs/SMART-BOM.md)

Before touching a file, v3 classifies it by its actual bytes and answers two
questions: (1) is cleaning needed at all? (2) is the BOM safe to remove?

DECISION TABLE (top-down, first match wins)
  1. Oversize (> --max-size)
       __ARROW__ skipped, counted separately, never read in full.
  2. UTF-16/UTF-32 BOM (FF FE, FE FF, FF FE 00 00, 00 00 FE FF)
       __ARROW__ NEVER TOUCHED. For these encodings the BOM is part of the format:
         removing it makes the file unreadable or misinterpreted, and byte-
         level CRLF tools would corrupt UTF-16 content. Such a file is only
         reported when something (a CRLF match) would otherwise have made the
         tool rewrite it. Convert with iconv first if you really need UTF-8.
  3. NUL bytes anywhere in the file
       __ARROW__ NEVER TOUCHED (binary data, or UTF-16 without BOM). Reported as
         "binary-nul-bytes". v2 rewrote such files __EMDASH__ a corruption risk.
  4. Content is not valid UTF-8
       __ARROW__ NOT TOUCHED by default (the file is not what its BOM/extension
         claims; rewriting could destroy data). Reported as "invalid-utf8".
         --force enables byte-level cleaning: BOM-strip and CRLF__ARROW__LF are safe
         byte operations for ASCII-compatible encodings (cp1251, latin-1__ELLIPSIS__).
  5. UTF-8 BOM present, extension is SENSITIVE (default: txt csv tsv ps1 psm1
     psd1 __EMDASH__ plus any extension not in the known-code table), and the content
     after the BOM is NON-ASCII
       __ARROW__ BOM KEPT by default, with an explanation. Rationale: Excel and legacy
         Windows Notepad render BOM-less UTF-8 as ANSI (mojibake); Windows
         PowerShell 5.1 parses BOM-less non-ASCII .ps1 as ANSI (broken
         scripts). Here the BOM is a feature, not dirt.
         Strip anyway with --force or --bom-policy=strip.
         CRLF in the same file IS still normalised (the BOM stays intact).
  6. UTF-8 BOM present; extension is code (php js css html xml __ELLIPSIS__) or the
     content is pure ASCII
       __ARROW__ BOM REMOVED. In PHP a BOM is outright harmful (breaks header(),
         causes "headers already sent", interferes with declare/namespace in
         edge cases); for a pure-ASCII file the BOM carries zero information,
         so removal is lossless for every consumer, Excel and Notepad
         included.
  7. No BOM, no CRLF
       __ARROW__ File is CLEAN: not rewritten at all __EMDASH__ inode, timestamps and hard
         links stay byte-for-byte intact.

OVERRIDES
  --bom-policy=strip   strip every UTF-8 BOM (still never UTF-16/32 or binary)
  --bom-policy=keep    never strip any BOM (CRLF is still normalised)
  --force              = strip policy + byte-level cleaning of invalid UTF-8
  --sensitive-ext LST  redefine the sensitive set ("" disables sensitivity)
  --no-bom-clear       v2-compatible global BOM switch-off

Every keep/protect decision is logged with its reason and appears in --json
("status": "kept"|"protected", "reason": __ELLIPSIS__). Nothing is ever modified
silently, and files that need no modification are never rewritten.

'@
}

function Write-HelpSafety {
    Write-StdOut @'
SAFETY GUARANTEES
  __BULLET__ Atomic replace: cleaned content is built in a temp file in the SAME
    directory (same filesystem), verified (BOM gone / CRLF gone / no new
    trailing newline), then rename(2)d over the original. A crash mid-way can
    never leave a half-written file.
  __BULLET__ Hard links: detected (nlink > 1) and rewritten IN PLACE through the inode,
    so linked copies stay linked. A warning is logged.
  __BULLET__ Symlink arguments are resolved to their targets; the recursive walk never
    follows symlinks (files or directories).
  __BULLET__ Ownership/permissions are transferred to the new inode; timestamps of
    MODIFIED files are preserved by default (opt out: --update-mtime). Clean
    files are never rewritten at all, so their mtime never changes.
  __BULLET__ Read-only directories: automatic fallback to a guarded in-place rewrite
    (rollback copy kept until the write succeeds).
  __BULLET__ Backups: --backup keeps <file>.bak.<pid>; --backup-dir DIR mirrors the
    tree. The atomic replace itself needs no backup __EMDASH__ the original stays
    intact until the verified rename.
  __BULLET__ Self-update replaces the script via rename(2): the running process keeps
    its old inode __EMDASH__ updating mid-run is safe.
  __BULLET__ The tool never deletes files and never creates files other than temps,
    requested backups and the log file.

'@
}

function Write-HelpExitCodes {
    Write-StdOut @'
EXIT CODES
  0   Success (tree clean, or everything cleaned)
  1   Completed, but some files had processing errors (see Error Breakdown),
      or --strict saw kept/protected/skipped files
  2   Invalid command line usage
  3   Environment problem: missing dependency, unusable temp dir, network
      failure during --check-update, or --update attempted on an npm-managed
      installation (use: npm install -g clean-bom-senior@latest)
  4   Critical internal error
  10  --check: at least one file needs cleaning (CI gate)
  11  --check-update: a newer version exists in the repository

Precedence when several apply: 2/3/4 (fatal) > 1 (file errors / strict) >
10 (check findings) > 0.

'@
}

function Write-HelpExamples {
    $S = $script:SCRIPT_NAME
    $V = $script:VERSION
    $REPO = $script:REPO_SLUG_DEFAULT
    Write-StdOut @"
EXAMPLES
    $S                            clean current tree, smart defaults
    $S /path/to/project src       clean specific directories
    $S --check                    CI gate (exit 10 = needs cleaning)
    $S --check --json > r.json    machine-readable CI report
    $S --dry-run -v               explain every decision
    $S --git                      only git-tracked files
    $S --ext php,phtml,inc        custom extension set
    $S --add-ext md,json          extend the default set
    $S --exclude 'dist/*' --exclude-dir build
    $S --force notes.txt          strip a "may-be-required" BOM
    $S --bom-policy=keep          CRLF only, never touch BOMs
    $S --no-bom-clear             v2-compatible: CRLF only
    $S --backup --backup-dir /tmp/bak   keep mirrored backups
    $S --check-update             is there a new release? (exit 11)
    $S --update                   self-update from the repository
    $S --self-test                verify the tool on this machine

GIT PRE-COMMIT HOOK  (.git/hooks/pre-commit, chmod +x)
    #!/bin/sh
    clean-bom-senior.sh --check --git --quiet || {
      echo "BOM/CRLF issues found. Run: clean-bom-senior.sh --git" >&2
      exit 1
    }

"@
}

function Write-HelpEnv {
    Write-StdOut @'
ENVIRONMENT
  CLEAN_BOM_OPTS        Extra options prepended to argv (CI-wide defaults,
                        e.g. CLEAN_BOM_OPTS="--quiet --strict"). Simple
                        whitespace splitting __EMDASH__ no quoting inside.
  CLEAN_BOM_GITHUB_REPO Repository slug used by --check-update/--update
                        (default: paulmann/Clean_BOM_Senior)
  CLEAN_BOM_UPDATE_URL  Base URL override for updates (mirrors / air-gapped
                        setups). Must serve VERSION and clean-bom-senior.ps1;
                        file:// URLs work (used by the test-suite).
  NO_COLOR              Any value disables colours (https://no-color.org)
  CLICOLOR_FORCE=1      Force colours even when stderr is not a TTY
  TMPDIR                Temp directory for rollback copies (default /tmp)

'@
}

function Write-HelpCi {
    Write-StdOut @'
CI / CD RECIPES
  Gate (fail the build when the tree is dirty):
      clean-bom-senior.sh --check --quiet          # exit 10 = dirty
  Gate + machine report as an artifact:
      clean-bom-senior.sh --check --json > bom-report.json; rc=$?
  Auto-fix job:
      clean-bom-senior.sh --quiet && git diff --exit-code
  Strict policy ("no protected/kept files may exist in this repo"):
      clean-bom-senior.sh --check --strict
  Updates: never run --update inside CI; pin the release tag instead.
  GitHub Actions: see .github/workflows/ci.yml for a ready-made job.

'@
}

function Write-HelpUpdate {
    $S = $script:SCRIPT_NAME
    $V = $script:VERSION
    $REPO = $script:REPO_SLUG_DEFAULT
    Write-StdOut @"
AUTO-UPDATE
    $S --check-update    compare local v$V with the repository
    $S --update          download and replace this script

  How it works:
    1. Fetch VERSION from the repository (release tag first, default branch
       as fallback; base URL overridable via CLEAN_BOM_UPDATE_URL).
    2. Compare numeric major.minor.patch against the running version.
    3. --update downloads clean-bom-senior.ps1 of that release, verifies it
       (#Requires header + embedded version stamp), then replaces the
       running file atomically __EMDASH__ safe while this process keeps running.

  Notes:
    __BULLET__ Requires curl (Invoke-WebRequest is the fallback). There is no telemetry:
      nothing is fetched unless you pass --check-update / --update.
    __BULLET__ npm-managed installations are detected and refused (exit 3) __EMDASH__ update
      those with: npm install -g clean-bom-senior@latest
    __BULLET__ Read-only install locations: re-run with sufficient privileges, or
      download manually:
      https://raw.githubusercontent.com/$REPO/main/clean-bom-senior.ps1

"@
}

function Write-HelpFiles {
    Write-StdOut @'
FILE TYPES & LIMITS
  Default extensions cleaned:   php css js txt xml htm html
  Always-safe-to-strip (code):  php phtml phps inc php3 php4 php5 php7 php8 js mjs cjs jsx ts tsx vue json jsonc json5 css scss sass less htm html xhtml xml svg xsl xslt mustache hbs twig blade sh bash zsh fish py rb pl lua sql yaml yml toml
  Sensitive (UTF-8 BOM may be required; kept when content is non-ASCII):
                                txt csv tsv ps1 psm1 psd1
  Unknown extensions added via --ext/--add-ext are treated as sensitive
  (the safe default). Redefine with --sensitive-ext / --bom-policy.
  Max file size:                100M by default (--max-size)
  Empty files:                  skipped by the walk (nothing to clean)
  UTF-16/UTF-32 files:          never modified (their BOM is part of the format)
  Binary (NUL) files:           never modified

'@
}

function Write-HelpJson {
    Write-StdOut @'
JSON REPORT (--json, printed on stdout)
  {
    "tool": "clean-bom-senior", "version": "3.0.0",
    "mode": "fix|dry-run|check",
    "startedAt": "<ISO-8601 UTC>", "durationSeconds": N, "cwd": "...",
    "options": { bomPolicy, noBomClear, noCrlfNormalize, force, extensions,
                 sensitiveExtensions, maxSizeBytes, keepMtime },
    "summary": { scanned, changed, wouldChange, clean, bomKept, bomRemoved,
                 crlfFixed, protectedUtf16or32, protectedBinary,
                 protectedInvalidUtf8, skippedOversize, errors },
    "files": [ { "path", "status", "encoding", "actions", "bomKept",
                 "reason" } ]
  }
  file.status __ELEMENTOF__ changed | would-change | kept | protected | skipped-size |
                error
  Clean files are counted in summary.clean but NOT listed in "files" (keeps
  reports small on big trees). Logs stay on stderr __EMDASH__ stdout is pure JSON.

'@
}

function Write-HelpCompatibility {
    Write-StdOut @'
COMPATIBILITY & IMPLEMENTATIONS
  All v2 flags are supported: -h -V -v -n --no-bom-clear --no-rn-normalize
  -- and the "FILES..." positional form. Behavioural upgrades in v3 (details
  in CHANGELOG.md): byte-exact detection, real timestamp preservation, a
  working --no-rn-normalize under MSYS, binary/UTF-16 protection, Smart BOM
  Policy, default exclusion of .git/node_modules, directory arguments,
  consistent exit codes, macOS (BSD stat) support.

  Implementation matrix:
    clean-bom-senior.sh   3.x    reference (Linux/macOS/WSL/Git Bash)
    bin/bom.js (npm CLI)  3.x    native Node.js __EMDASH__ all platforms incl. Windows
    clean-bom-senior.ps1  3.x    PowerShell 7.6+ (Windows/Linux/macOS)
    clean-bom-senior.bat  2.07   legacy cmd.exe port (v2 contract, frozen)
  On Windows, use the npm CLI or the PowerShell port for v3 features:
      npm i -g clean-bom-senior
      ./clean-bom-senior.ps1 --help
  The first three are pinned to each other by differential tests
  (tests/node, tests/ps); the cmd.exe port is frozen __EMDASH__ see docs/BAT-PORT.md.

'@
}

# END GENERATED HELP

function Show-Help {
    param([string]$Topic)
    Write-HelpHeader
    switch -CaseSensitive ($Topic) {
        '' {
            Write-HelpUsage
            Write-StdOut "`n"
            Write-HelpOptions
            Write-StdOut "`n"
            Write-HelpBomPolicy
            Write-StdOut "`n"
            Write-HelpSafety
            Write-StdOut "`n"
            Write-HelpExitCodes
            Write-StdOut "`n"
            Write-HelpExamples
            Write-StdOut "`n"
            Write-HelpEnv
            Write-StdOut "`n"
            Write-StdOut "Topic help: $($script:SCRIPT_NAME) --help TOPIC`nTopics: $(Get-HelpTopicsList)`n"
        }
        'usage' { Write-HelpUsage }
        'options' { Write-HelpOptions }
        'selection' { Write-HelpOptions }
        'bom-policy' { Write-HelpBomPolicy }
        'bom' { Write-HelpBomPolicy }
        'policy' { Write-HelpBomPolicy }
        'safety' { Write-HelpSafety }
        'exit-codes' { Write-HelpExitCodes }
        'exit' { Write-HelpExitCodes }
        'examples' { Write-HelpExamples }
        'env' { Write-HelpEnv }
        'environment' { Write-HelpEnv }
        'ci' { Write-HelpCi }
        'update' { Write-HelpUpdate }
        'files' { Write-HelpFiles }
        'json' { Write-HelpJson }
        'compatibility' { Write-HelpCompatibility }
        'compat' { Write-HelpCompatibility }
        'topics' { Write-StdOut "Topics: $(Get-HelpTopicsList)`n" }
        default {
            Write-StdErr "Unknown help topic: $Topic`nTopics: $(Get-HelpTopicsList)`n"
            throw [CleanBomFatalException]::new($script:EXIT_USAGE, "unknown help topic: $Topic")
        }
    }
}

function Show-Version {
    Write-StdOut "$($script:SCRIPT_NAME) version $($script:VERSION)`n"
    Write-StdOut "Author: Mikhail Deynekin <mid1977@gmail.com>`n"
    Write-StdOut "Website: https://deynekin.com`n"
}

# Divergence #1: the reference emits bash completion; this port emits the
# PowerShell-native equivalent (Register-ArgumentCompleter).
function Show-Completion {
    Write-StdOut @'
# PowerShell completion for clean-bom-senior - dot-source this output:
#   Invoke-Expression (& .\clean-bom-senior.ps1 --completion | Out-String)
$__cleanBomSeniorOptions = @(
    '-h', '--help', '-V', '--version', '-v', '--verbose', '-n', '--dry-run',
    '-c', '--check', '-f', '--fix', '-q', '--quiet', '--silent', '-j', '--json',
    '--color', '--no-color', '--log-file', '--ext', '--add-ext', '--exclude',
    '--exclude-dir', '--no-default-excludes', '--max-size', '--git',
    '--bom-policy', '--sensitive-ext', '--force', '--strict', '--no-bom-clear',
    '--no-rn-normalize', '--no-crlf-normalize', '--update-mtime',
    '--no-keep-mtime', '--backup', '--backup-dir', '--check-update', '--update',
    '--self-test', '--completion'
)
$__cleanBomSeniorCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)
    $prev = $commandAst.CommandElements[-2]
    if ($prev) {
        switch ($prev.ToString()) {
            '--color' {
                return @('auto', 'always', 'never') |
                    Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            }
            '--bom-policy' {
                return @('auto', 'strip', 'keep') |
                    Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            }
            '--help' {
                return @('usage', 'options', 'bom-policy', 'safety', 'exit-codes',
                    'examples', 'env', 'ci', 'update', 'files', 'json', 'compatibility') |
                    Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
            }
        }
    }
    if ($wordToComplete -like '-*') {
        return $__cleanBomSeniorOptions |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_) }
    }
    return [System.Management.Automation.CompletionResult]::new(
        $wordToComplete, $wordToComplete, 'ProviderItem', $wordToComplete)
}
foreach ($__cmd in 'clean-bom-senior.ps1', 'clean-bom-senior', 'bom') {
    Register-ArgumentCompleter -CommandName $__cmd -ScriptBlock $__cleanBomSeniorCompleter -Native
}

'@
}

#------------------------------------------------------------------------------
# Self-test helpers.
#
# Invocation note: `& $script child.ps1 '--a','b'` and `& $script child.ps1
# @('--a','b')` BOTH hand the child a single string argument "--a b" - a
# literal comma list is one expression, and `@(...)` around an expression is
# not splatting. Splatting only happens against a variable holding a real
# array, so every helper below takes [string[]] and forwards it as `& $t @A`.
# (Start-Process -ArgumentList also works; it is slower and needs quoting.)
#------------------------------------------------------------------------------
function Get-SelfTestHex {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sb = [System.Text.StringBuilder]::new($bytes.Length * 2)
    foreach ($b in $bytes) { $null = $sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Invoke-SelfTestTool {
    param([string]$Dir, [string]$Tool, [string[]]$ToolArgs)
    $savedCwd = [Environment]::CurrentDirectory
    try {
        # Push-Location changes PowerShell's location but NOT the process
        # current directory, and every [System.IO.*] call in the child
        # resolves relative paths against the latter. Sync both, or the child
        # reports "File not found" for a fixture that plainly exists.
        [Environment]::CurrentDirectory = $Dir
        Push-Location -LiteralPath $Dir
        try { & $Tool @ToolArgs *> $null } finally { Pop-Location }
    } finally {
        [Environment]::CurrentDirectory = $savedCwd
    }
    return $LASTEXITCODE
}

function Add-SelfTestVerdict {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    if ($Passed) {
        $script:ST_PASS = $script:ST_PASS + 1
        Write-StdOut "ok   $Name`n"
    } else {
        $script:ST_FAIL = $script:ST_FAIL + 1
        if ($Detail -cne '') { Write-StdOut "FAIL ${Name}: $Detail`n" }
        else { Write-StdOut "FAIL $Name`n" }
    }
}

#------------------------------------------------------------------------------
# Self-test: proves THIS installation works on THIS machine (no repo needed).
#------------------------------------------------------------------------------
function Invoke-SelfTest {
    $td = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
        "cleanbom-selftest.$([System.IO.Path]::GetRandomFileName())")
    $null = [System.IO.Directory]::CreateDirectory($td)
    $tool = $script:SCRIPT_PATH_RESOLVED
    $script:ST_PASS = 0
    $script:ST_FAIL = 0
    $bom = [byte[]](0xEF, 0xBB, 0xBF)

    try {
        # t1 - PHP: BOM stripped, CRLF -> LF
        [System.IO.File]::WriteAllBytes("$td/t1.php",
            $bom + $script:LATIN1.GetBytes("<?php`r`necho 1;`r`n"))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't1.php')
        $got = Get-SelfTestHex "$td/t1.php"
        Add-SelfTestVerdict -Name 't1 php: BOM stripped, CRLF->LF' `
            -Passed ($got -ceq '3c3f7068700a6563686f20313b0a') -Detail "got [$got] want [3c3f7068700a6563686f20313b0a]"

        # t2 - UTF-16LE: never touched
        [System.IO.File]::WriteAllBytes("$td/t2.txt",
            [byte[]](0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x0D, 0x00, 0x0A, 0x00))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't2.txt')
        $got = Get-SelfTestHex "$td/t2.txt"
        Add-SelfTestVerdict -Name 't2 utf16le: never touched' `
            -Passed ($got -ceq 'fffe680069000d000a00') -Detail "got [$got] want [fffe680069000d000a00]"

        # t3 - sensitive .txt with non-ASCII: BOM kept, CRLF fixed
        [System.IO.File]::WriteAllBytes("$td/t3.txt",
            $bom + $script:LATIN1.GetBytes('caf') + [byte[]](0xC3, 0xA9, 0x0D, 0x0A))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't3.txt')
        $got = Get-SelfTestHex "$td/t3.txt"
        Add-SelfTestVerdict -Name 't3 sensitive txt: BOM kept, CRLF fixed' `
            -Passed ($got -ceq 'efbbbf636166c3a90a') -Detail "got [$got] want [efbbbf636166c3a90a]"

        # t4 - --force strips the "may-be-required" BOM
        [System.IO.File]::WriteAllBytes("$td/t4.txt",
            $bom + $script:LATIN1.GetBytes('caf') + [byte[]](0xC3, 0xA9, 0x0D, 0x0A))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', '--force', 't4.txt')
        $got = Get-SelfTestHex "$td/t4.txt"
        Add-SelfTestVerdict -Name 't4 --force strips sensitive BOM' `
            -Passed ($got -ceq '636166c3a90a') -Detail "got [$got] want [636166c3a90a]"

        # t5 - pure-ASCII .txt: the BOM carries no information, so it goes
        [System.IO.File]::WriteAllBytes("$td/t5.txt",
            $bom + $script:LATIN1.GetBytes("plain ascii`r`n"))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't5.txt')
        $got = Get-SelfTestHex "$td/t5.txt"
        Add-SelfTestVerdict -Name 't5 ascii-only txt: BOM stripped' `
            -Passed ($got -ceq '706c61696e2061736369690a') -Detail "got [$got] want [706c61696e2061736369690a]"

        # t6 - NUL byte: binary, never touched
        [System.IO.File]::WriteAllBytes("$td/t6.js",
            $script:LATIN1.GetBytes('BIN') + [byte[]](0x00) + $script:LATIN1.GetBytes("ARY`r`n"))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't6.js')
        $got = Get-SelfTestHex "$td/t6.js"
        Add-SelfTestVerdict -Name 't6 binary (NUL): never touched' `
            -Passed ($got -ceq '42494e004152590d0a') -Detail "got [$got] want [42494e004152590d0a]"

        # t7 - a clean file is not rewritten at all (identity is stable)
        [System.IO.File]::WriteAllBytes("$td/t7.css", $script:LATIN1.GetBytes("clean file`r`n"))
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't7.css')
        $id1 = Get-FileInode "$td/t7.css"
        $ts1 = [System.IO.FileInfo]::new("$td/t7.css").LastWriteTimeUtc
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't7.css')
        $id2 = Get-FileInode "$td/t7.css"
        $ts2 = [System.IO.FileInfo]::new("$td/t7.css").LastWriteTimeUtc
        $stable = if ($id1 -cne '') { ($id1 -ceq $id2) } else { ($ts1 -eq $ts2) }
        $got = Get-SelfTestHex "$td/t7.css"
        Add-SelfTestVerdict -Name 't7 clean file not rewritten (inode stable)' `
            -Passed ($stable -and $got -ceq '636c65616e2066696c650a') -Detail ''

        # t8 - --check exits 10 on a dirty file
        [System.IO.File]::WriteAllBytes("$td/t8.php", $script:LATIN1.GetBytes("x`r`n"))
        $rc8 = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--check', 't8.php')
        Add-SelfTestVerdict -Name 't8 --check exit 10 on dirty file' `
            -Passed ($rc8 -eq 10) -Detail "rc=$rc8"

        # t9 - --check exits 0 once the file is clean
        $null = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--quiet', 't8.php')
        $rc9 = Invoke-SelfTestTool -Dir $td -Tool $tool -ToolArgs @('--check', 't8.php')
        Add-SelfTestVerdict -Name 't9 --check exit 0 when clean' `
            -Passed ($rc9 -eq 0) -Detail "rc=$rc9"

        # t10 - --json emits valid JSON on stdout.
        # The tool writes with [Console]::Out.Write, which bypasses PowerShell's
        # stream plumbing entirely, so a pipeline capture would leak the report
        # to the console. Swap the process-level stdout for a StringWriter
        # instead - the child runs in this same process and sees the swap.
        $sw = [System.IO.StringWriter]::new()
        $realOut = [Console]::Out
        $realErr = [Console]::Error
        $swErr = [System.IO.StringWriter]::new()
        [string[]]$jsonArgs = @('--json', 't8.php')
        $savedCwd = [Environment]::CurrentDirectory
        try {
            [Console]::SetOut($sw)
            [Console]::SetError($swErr)
            [Environment]::CurrentDirectory = $td
            Push-Location -LiteralPath $td
            try { $null = & $tool @jsonArgs } finally { Pop-Location }
        } finally {
            [Console]::SetOut($realOut)
            [Console]::SetError($realErr)
            [Environment]::CurrentDirectory = $savedCwd
        }
        $json = $sw.ToString()
        $valid = $false
        try { $null = $json | ConvertFrom-Json; $valid = $true } catch { $valid = $false }
        Add-SelfTestVerdict -Name 't10 --json emits valid JSON' -Passed $valid -Detail ''
    } finally {
        try { [System.IO.Directory]::Delete($td, $true) } catch { }
    }

    Write-StdOut "`nself-test: $($script:ST_PASS) passed, $($script:ST_FAIL) failed`n"
    if ($script:ST_FAIL -eq 0) { $script:ExitCode = $script:EXIT_OK }
    else { $script:ExitCode = $script:EXIT_FILE_ERRORS }
    throw [CleanBomFatalException]::new($script:ExitCode, 'self-test finished')
}

#------------------------------------------------------------------------------
# Update machinery (--check-update / --update)
#------------------------------------------------------------------------------
function Get-UpdateBaseUrl {
    if ($null -ne $env:CLEAN_BOM_UPDATE_URL -and $env:CLEAN_BOM_UPDATE_URL -cne '') {
        return $env:CLEAN_BOM_UPDATE_URL.TrimEnd([char]'/')
    }
    $repo = $script:REPO_SLUG_DEFAULT
    if ($null -ne $env:CLEAN_BOM_GITHUB_REPO -and $env:CLEAN_BOM_GITHUB_REPO -cne '') {
        $repo = $env:CLEAN_BOM_GITHUB_REPO
    }
    return "https://raw.githubusercontent.com/$repo/refs/heads/main"
}

# Returns $null on failure. `file://` is handled directly so the test-suite can
# point the update machinery at a local fixture repository.
function Get-RemoteText {
    param([string]$Url)
    try {
        if ($Url.StartsWith('file://')) {
            $local = ([System.Uri]$Url).LocalPath
            if (-not [System.IO.File]::Exists($local)) { return $null }
            return [System.IO.File]::ReadAllText($local)
        }
        if (Test-Have 'curl') {
            $out = & curl -fsSL --connect-timeout 10 --max-time 60 -- "$Url" 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return (($out | Out-String) -replace "`r`n", "`n")
        }
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        return $r.Content
    } catch { return $null }
}

function Get-RemoteVersion {
    $text = Get-RemoteText ("$(Get-UpdateBaseUrl)/VERSION")
    if ($null -eq $text) { return $null }
    $first = @([regex]::Matches($text, '[^\n]*'))[0].Value
    $v = ($first -replace '\s', '')
    if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { return $v }
    return $null
}

function Test-SemverGreater {
    # True when $A > $B (numeric major.minor.patch; any suffix is ignored).
    param([string]$A, [string]$B)
    $pa = @([regex]::Matches(($A -replace '[^0-9.].*$', ''), '[^\.]+') | ForEach-Object { $_.Value })
    $pb = @([regex]::Matches(($B -replace '[^0-9.].*$', ''), '[^\.]+') | ForEach-Object { $_.Value })
    $av = @(0, 0, 0)
    $bv = @(0, 0, 0)
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; if ($i -lt $pa.Count -and [int]::TryParse($pa[$i], [ref]$x)) { $av[$i] = $x }
        $y = 0; if ($i -lt $pb.Count -and [int]::TryParse($pb[$i], [ref]$y)) { $bv[$i] = $y }
    }
    if ($av[0] -ne $bv[0]) { return ($av[0] -gt $bv[0]) }
    if ($av[1] -ne $bv[1]) { return ($av[1] -gt $bv[1]) }
    return ($av[2] -gt $bv[2])
}

function Invoke-CheckUpdate {
    $remote = Get-RemoteVersion
    if ($null -eq $remote) {
        Write-LogError "Could not determine the latest version from: $(Get-UpdateBaseUrl)"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'update check failed')
    }
    if (Test-SemverGreater -A $remote -B $script:VERSION) {
        Write-LogWarn "Update available: $($script:VERSION) -> $remote (run: $($script:SCRIPT_NAME) --update)"
        throw [CleanBomFatalException]::new($script:EXIT_UPDATE_AVAILABLE, 'update available')
    }
    Write-LogInfo "Up to date (local $($script:VERSION), remote $remote)"
    throw [CleanBomFatalException]::new($script:EXIT_OK, 'up to date')
}

function Invoke-SelfUpdate {
    $remote = Get-RemoteVersion
    if ($null -eq $remote) {
        Write-LogError "Could not determine the latest version from: $(Get-UpdateBaseUrl)"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'update failed')
    }
    if (-not (Test-SemverGreater -A $remote -B $script:VERSION)) {
        Write-LogInfo "Already up to date (local $($script:VERSION), remote $remote)"
        throw [CleanBomFatalException]::new($script:EXIT_OK, 'already up to date')
    }

    $resolved = $script:SCRIPT_PATH_RESOLVED
    $norm = $resolved -creplace '\\', '/'
    if ($norm.Contains('/node_modules/')) {
        Write-LogError "This installation is npm-managed: $resolved"
        Write-LogError 'Update it with: npm install -g clean-bom-senior@latest'
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'npm-managed install')
    }
    if (-not (Test-FileWritable $resolved)) {
        $repo = $script:REPO_SLUG_DEFAULT
        if ($null -ne $env:CLEAN_BOM_GITHUB_REPO -and $env:CLEAN_BOM_GITHUB_REPO -cne '') { $repo = $env:CLEAN_BOM_GITHUB_REPO }
        Write-LogError "Cannot write to $resolved __EMDASH__ re-run with sufficient privileges,"
        Write-LogError "or download manually: https://raw.githubusercontent.com/$repo/refs/tags/v$remote/clean-bom-senior.ps1"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'read-only install')
    }

    # Prefer the release tag; fall back to the default branch / mirror.
    $content = $null
    if ($null -eq $env:CLEAN_BOM_UPDATE_URL -or $env:CLEAN_BOM_UPDATE_URL -ceq '') {
        $repo = $script:REPO_SLUG_DEFAULT
        if ($null -ne $env:CLEAN_BOM_GITHUB_REPO -and $env:CLEAN_BOM_GITHUB_REPO -cne '') { $repo = $env:CLEAN_BOM_GITHUB_REPO }
        $tagUrl = "https://raw.githubusercontent.com/$repo/refs/tags/v$remote/clean-bom-senior.ps1"
        $c = Get-RemoteText $tagUrl
        if ($null -ne $c -and $c.Trim() -cne '') { $content = $c }
    }
    if ($null -eq $content) {
        $c = Get-RemoteText ("$(Get-UpdateBaseUrl)/clean-bom-senior.ps1")
        if ($null -ne $c -and $c.Trim() -cne '') { $content = $c }
    }
    if ($null -eq $content) {
        Write-LogError "Download failed (tried the release tag and $(Get-UpdateBaseUrl))"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'download failed')
    }

    # Verify what we are about to install: PowerShell header + version stamp
    # (divergence #4 - the shell reference checks a shebang + VERSION="x.y.z").
    if (-not ($content -match '(?m)^#Requires\s+-Version\s')) {
        Write-LogError 'Downloaded content failed verification (bad PowerShell header) __EMDASH__ refusing to install'
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'verification failed')
    }
    $stamp = "`$script:VERSION = '$remote';"
    if (-not $content.Contains($stamp)) {
        Write-LogError "Downloaded content failed verification (version stamp != $remote) __EMDASH__ refusing to install"
        throw [CleanBomFatalException]::new($script:EXIT_ENV, 'verification failed')
    }

    $targetDir = [System.IO.Path]::GetDirectoryName($resolved)
    $tmp = [System.IO.Path]::Combine($targetDir, ".cleanbom-update.$([System.IO.Path]::GetRandomFileName())")
    Register-TempFile $tmp
    $origMode = Get-FileUnixMode $resolved
    [System.IO.File]::WriteAllText($tmp, $content, $script:UTF8_NO_BOM_ENC)
    if ($null -ne $origMode) {
        # Carry the installation's own permission bits over to the new file, so
        # a directly-invoked (0755) install stays executable after the update.
        if (-not (Set-FileUnixMode -Path $tmp -Mode $origMode)) {
            $null = Set-FileUnixMode -Path $tmp -Mode ([System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')
        }
    }
    [System.IO.File]::Move($tmp, $resolved, $true)
    Write-StdErr "Updated $($script:SCRIPT_NAME): $($script:VERSION) -> $remote ($resolved)`n"
    throw [CleanBomFatalException]::new($script:EXIT_OK, 'updated')
}

#------------------------------------------------------------------------------
# Argument parsing (GNU-style interspersed; every v2 flag preserved)
#------------------------------------------------------------------------------
function Format-ExtList {
    # "PHP, .Js ,,ts" -> "php js ts"
    #
    # Deliberately NOT `-split`: PowerShell's -split sorts the match collection
    # using the current culture, so under a case-insensitive collation
    # "--ext php,js" came out as "js php". [regex]::Matches preserves input
    # order, which is what the LC_ALL=C reference produces.
    param([string]$List)
    $t = $List -creplace '[,.]', ' '
    $t = $t.ToLowerInvariant()
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($t, '[^\s]+')) { $parts.Add($m.Value) }
    return ($parts -join ' ')
}

function ConvertFrom-SizeSpec {
    param([string]$Spec)
    $num = ''
    $rest = $Spec
    for ($i = 0; $i -lt $Spec.Length; $i++) {
        $c = $Spec[$i]
        if ($c -ge '0' -and $c -le '9') { $num = "$num$c" } else { $rest = $Spec.Substring($i); break }
        if ($i -eq ($Spec.Length - 1)) { $rest = '' }
    }
    if ($num -ceq '') { return $null }
    $unit = $rest.ToUpperInvariant()
    $n = [long]0
    if (-not [long]::TryParse($num, [ref]$n)) { return $null }
    switch ($unit) {
        '' { return $n }
        'B' { return $n }
        'K' { return $n * 1024 }
        'KB' { return $n * 1024 }
        'M' { return $n * 1024 * 1024 }
        'MB' { return $n * 1024 * 1024 }
        'G' { return $n * 1024 * 1024 * 1024 }
        'GB' { return $n * 1024 * 1024 * 1024 }
        default { return $null }
    }
}

function Invoke-ArgumentParsing {
    param([string[]]$ArgList)
    $a = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $ArgList) { $a.Add($x) }
    $i = 0

    while ($i -lt $a.Count) {
        $arg = $a[$i]
        $i = $i + 1
        switch -CaseSensitive ($arg) {
            '-h' {
                $script:SHOW_HELP = 1
                if ($i -lt $a.Count -and -not $a[$i].StartsWith('-')) {
                    $script:HELP_TOPIC = $a[$i]; $i = $i + 1
                }
                continue
            }
            '--help' {
                $script:SHOW_HELP = 1
                if ($i -lt $a.Count -and -not $a[$i].StartsWith('-')) {
                    $script:HELP_TOPIC = $a[$i]; $i = $i + 1
                }
                continue
            }
            '-V' { $script:SHOW_VERSION = 1; continue }
            '--version' { $script:SHOW_VERSION = 1; continue }
            '-v' { $script:VERBOSE_ON = 1; continue }
            '--verbose' { $script:VERBOSE_ON = 1; continue }
            '-n' { $script:DRY_RUN = 1; $script:VERBOSE_ON = 1; continue }
            '--dry-run' { $script:DRY_RUN = 1; $script:VERBOSE_ON = 1; continue }
            '-c' { $script:CHECK_MODE = 1; $script:QUIET = 1; continue }
            '--check' { $script:CHECK_MODE = 1; $script:QUIET = 1; continue }
            '-f' { continue }   # default mode; accepted for explicitness
            '--fix' { continue }
            '-q' { $script:QUIET = 1; continue }
            '--quiet' { $script:QUIET = 1; continue }
            '--silent' { $script:QUIET = 1; $script:SILENT = 1; continue }
            '-j' { $script:JSON_OUT = 1; continue }
            '--json' { $script:JSON_OUT = 1; continue }
            '--color' {
                if ($i -ge $a.Count) { Stop-Usage '--color requires a value (auto|always|never)' }
                $script:COLOR_MODE = $a[$i]; $i = $i + 1; continue
            }
            '--no-color' { $script:COLOR_MODE = 'never'; continue }
            '--log-file' {
                if ($i -ge $a.Count) { Stop-Usage '--log-file requires a value' }
                $script:LOG_FILE = $a[$i]; $i = $i + 1; continue
            }
            '--ext' {
                if ($i -ge $a.Count) { Stop-Usage '--ext requires a value' }
                $script:EXTENSIONS = Format-ExtList $a[$i]; $i = $i + 1; continue
            }
            '--add-ext' {
                if ($i -ge $a.Count) { Stop-Usage '--add-ext requires a value' }
                $add = Format-ExtList $a[$i]
                $script:EXTENSIONS = Format-ExtList "$($script:EXTENSIONS) $add"
                $i = $i + 1; continue
            }
            '--sensitive-ext' {
                if ($i -ge $a.Count) { Stop-Usage "--sensitive-ext requires a value (use '' to disable)" }
                $script:SENSITIVE_EXTS = Format-ExtList $a[$i]; $i = $i + 1; continue
            }
            '--exclude' {
                if ($i -ge $a.Count) { Stop-Usage '--exclude requires a pattern' }
                $script:EXCLUDE_PATTERNS.Add($a[$i]); $i = $i + 1; continue
            }
            '--exclude-dir' {
                if ($i -ge $a.Count) { Stop-Usage '--exclude-dir requires a name' }
                $script:EXCLUDE_DIRS = "$($script:EXCLUDE_DIRS) $($a[$i])"
                $script:USER_EXCLUDE_DIRS = "$($script:USER_EXCLUDE_DIRS) $($a[$i])"
                $i = $i + 1; continue
            }
            '--no-default-excludes' { $script:USE_DEFAULT_EXCLUDES = 0; continue }
            '--max-size' {
                if ($i -ge $a.Count) { Stop-Usage '--max-size requires a value' }
                $parsed = ConvertFrom-SizeSpec $a[$i]
                if ($null -eq $parsed) { Stop-Usage "Invalid --max-size: $($a[$i]) (examples: 512K, 10M, 1G, 1048576)" }
                $script:MAX_SIZE = [long]$parsed; $i = $i + 1; continue
            }
            '--bom-policy' {
                if ($i -ge $a.Count) { Stop-Usage '--bom-policy requires a value (auto|strip|keep)' }
                $script:BOM_POLICY = $a[$i]; $i = $i + 1; continue
            }
            '--force' { $script:FORCE = 1; continue }
            '--strict' { $script:STRICT = 1; continue }
            '--git' { $script:GIT_MODE = 1; continue }
            '--no-bom-clear' { $script:NO_BOM_CLEAR = 1; continue }
            '--no-rn-normalize' { $script:NO_CRLF_NORMALIZE = 1; continue }
            '--no-crlf-normalize' { $script:NO_CRLF_NORMALIZE = 1; continue }
            '--update-mtime' { $script:KEEP_MTIME = 0; continue }
            '--no-keep-mtime' { $script:KEEP_MTIME = 0; continue }
            '--backup' { $script:BACKUP = 1; continue }
            '--backup-dir' {
                if ($i -ge $a.Count) { Stop-Usage '--backup-dir requires a directory' }
                $script:BACKUP = 1; $script:BACKUP_DIR = $a[$i]; $i = $i + 1; continue
            }
            '--check-update' { $script:DO_CHECK_UPDATE = 1; continue }
            '--update' { $script:DO_UPDATE = 1; continue }
            '--self-test' { $script:SELF_TEST = 1; continue }
            '--completion' { $script:SHOW_COMPLETION = 1; continue }
            '--' {
                while ($i -lt $a.Count) { $script:POSITIONAL.Add($a[$i]); $i = $i + 1 }
                continue
            }
            default {
                if ($arg.StartsWith('--color=')) { $script:COLOR_MODE = $arg.Substring(8); continue }
                if ($arg.StartsWith('--log-file=')) { $script:LOG_FILE = $arg.Substring(11); continue }
                if ($arg.StartsWith('--ext=')) { $script:EXTENSIONS = Format-ExtList $arg.Substring(6); continue }
                if ($arg.StartsWith('--add-ext=')) {
                    $add = Format-ExtList $arg.Substring(10)
                    $script:EXTENSIONS = Format-ExtList "$($script:EXTENSIONS) $add"
                    continue
                }
                if ($arg.StartsWith('--sensitive-ext=')) { $script:SENSITIVE_EXTS = Format-ExtList $arg.Substring(16); continue }
                if ($arg.StartsWith('--exclude=')) { $script:EXCLUDE_PATTERNS.Add($arg.Substring(10)); continue }
                if ($arg.StartsWith('--exclude-dir=')) {
                    $v = $arg.Substring(14)
                    $script:EXCLUDE_DIRS = "$($script:EXCLUDE_DIRS) $v"
                    $script:USER_EXCLUDE_DIRS = "$($script:USER_EXCLUDE_DIRS) $v"
                    continue
                }
                if ($arg.StartsWith('--max-size=')) {
                    $parsed = ConvertFrom-SizeSpec $arg.Substring(11)
                    if ($null -eq $parsed) { Stop-Usage "Invalid --max-size: $($arg.Substring(11))" }
                    $script:MAX_SIZE = [long]$parsed; continue
                }
                if ($arg.StartsWith('--bom-policy=')) { $script:BOM_POLICY = $arg.Substring(13); continue }
                if ($arg.StartsWith('--backup-dir=')) { $script:BACKUP = 1; $script:BACKUP_DIR = $arg.Substring(13); continue }
                if ($arg.StartsWith('-')) {
                    # Deliberately NOT Stop-Usage. The reference emits the
                    # "Try ... --help" hint from die_usage, which every other
                    # usage error goes through, but handles an unknown token
                    # inline with log_error + exit 2 and therefore WITHOUT the
                    # hint. bin/bom.js does the same. Matching that exactly is
                    # what keeps the stderr contract identical across ports.
                    Write-LogError "Unknown option: $arg"
                    throw [CleanBomFatalException]::new($script:EXIT_USAGE, "Unknown option: $arg")
                }
                $script:POSITIONAL.Add($arg)
                continue
            }
        }
    }

    switch -CaseSensitive ($script:BOM_POLICY) {
        'auto' { }
        'strip' { }
        'keep' { }
        default { Stop-Usage "Invalid --bom-policy: $($script:BOM_POLICY) (expected auto|strip|keep)" }
    }
    $script:EXTENSIONS = Format-ExtList $script:EXTENSIONS
    if ($script:EXTENSIONS -ceq '') {
        Stop-Usage 'Extension list is empty __EMDASH__ nothing to do (check --ext/--add-ext)'
    }
    $keepDirs = if ($script:USE_DEFAULT_EXCLUDES -eq 0) { $script:USER_EXCLUDE_DIRS } else { $script:EXCLUDE_DIRS }
    $dirParts = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($keepDirs, '[^\s]+')) { $dirParts.Add($m.Value) }
    $script:EXCLUDE_DIRS = ($dirParts -join ' ')
    $script:SENSITIVE_EXTS = Format-ExtList $script:SENSITIVE_EXTS
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
function Invoke-Main {
    param([string[]]$ArgList)

    $script:START_TIME = Get-Date
    $script:START_TIME_ISO = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $script:SCRIPT_PATH_RESOLVED = Resolve-FullPath $script:SCRIPT_PATH

    # CLEAN_BOM_OPTS: CI-wide default options (see --help env).
    $all = New-Object System.Collections.Generic.List[string]
    if ($null -ne $env:CLEAN_BOM_OPTS -and $env:CLEAN_BOM_OPTS.Trim() -cne '') {
        foreach ($m in [regex]::Matches($env:CLEAN_BOM_OPTS, '[^\s]+')) { $all.Add($m.Value) }
    }
    foreach ($o in $ArgList) { $all.Add($o) }
    Invoke-ArgumentParsing -ArgList $all.ToArray()

    Initialize-Color

    if ($script:LOG_FILE -cne '') {
        try {
            [System.IO.File]::AppendAllText($script:LOG_FILE, '', $script:UTF8_NO_BOM_ENC)
        } catch { Stop-Env "Cannot write to log file: $($script:LOG_FILE)" }
        [System.IO.File]::AppendAllText($script:LOG_FILE,
            "`n===== $($script:SCRIPT_NAME) v$($script:VERSION) run at $(Get-Timestamp) =====`n",
            $script:UTF8_NO_BOM_ENC)
    }

    # Information modes short-circuit everything else.
    if ($script:SHOW_COMPLETION -eq 1) {
        Show-Completion
        throw [CleanBomFatalException]::new($script:EXIT_OK, 'completion')
    }
    if ($script:SHOW_HELP -eq 1) {
        Show-Help -Topic $script:HELP_TOPIC
        throw [CleanBomFatalException]::new($script:EXIT_OK, 'help')
    }
    if ($script:SHOW_VERSION -eq 1) {
        Show-Version
        throw [CleanBomFatalException]::new($script:EXIT_OK, 'version')
    }

    Check-Dependencies

    if ($script:SELF_TEST -eq 1) { Invoke-SelfTest }
    if ($script:DO_CHECK_UPDATE -eq 1) { Invoke-CheckUpdate }
    if ($script:DO_UPDATE -eq 1) { Invoke-SelfUpdate }

    if ($script:CHECK_MODE -eq 0 -and $script:QUIET -eq 0 -and $script:JSON_OUT -eq 0) {
        Write-Greeting
    }

    if ($script:GIT_MODE -eq 1) {
        if ($script:POSITIONAL.Count -gt 0) {
            foreach ($p in $script:POSITIONAL) { $script:GIT_PATHSPEC.Add($p) }
        }
        Invoke-GitScan
    } elseif ($script:POSITIONAL.Count -eq 0) {
        Write-LogInfo "Recursive mode: scanning '.' for extensions: $($script:EXTENSIONS)"
        Invoke-DirectoryScan -Dir '.' -Prefix '.'
    } else {
        foreach ($arg in @($script:POSITIONAL)) {
            if ((Test-IsDirectory $arg) -and -not (Test-IsSymlink $arg)) {
                Write-LogInfo "Directory mode: scanning '$arg' for extensions: $($script:EXTENSIONS)"
                Invoke-DirectoryScan -Dir $arg -Prefix $arg
            } elseif ((Test-IsSymlink $arg) -and (Test-IsDirectory $arg)) {
                Write-LogInfo "Directory mode (symlink resolved): scanning '$arg'"
                $rt = Resolve-FullPath $arg
                Invoke-DirectoryScan -Dir $rt -Prefix $rt
            } elseif ((Test-IsRegularFile $arg) -or (Test-IsSymlink $arg)) {
                if (Test-IsSymlink $arg) {
                    $target = Resolve-FullPath $arg
                    Write-LogInfo "Symlink argument resolved: $arg -> $target"
                    if (-not (Invoke-FileHandling -Display $arg -Path $target)) { $script:FILE_ERRORS = 1 }
                } else {
                    if (-not (Invoke-FileHandling -Display $arg -Path $arg)) { $script:FILE_ERRORS = 1 }
                }
            } else {
                Write-LogError "File not found: $arg"
                $script:ERR_ACCESS = $script:ERR_ACCESS + 1
                $script:FILE_ERRORS = 1
            }
        }
    }

    # ---- reporting ---------------------------------------------------------
    if ($script:JSON_OUT -eq 1) { Write-JsonReport }
    if ($script:CHECK_MODE -eq 1) {
        if ($script:QUIET -eq 1 -and $script:VERBOSE_ON -eq 0) {
            $kp = $script:KEPT_BOM_COUNT + $script:PROTECTED_UTF16_COUNT +
            $script:PROTECTED_BINARY_COUNT + $script:PROTECTED_INVALID_COUNT
            Write-StdErr "check: $($script:WOULD_CHANGE_COUNT) file(s) need cleaning, $kp kept/protected, $($script:ERROR_COUNT) error(s)`n"
        } else {
            Write-Statistics
        }
    } elseif ($script:QUIET -eq 0 -and $script:SILENT -eq 0) {
        Write-Statistics
    }

    # ---- exit code ---------------------------------------------------------
    $rc = 0
    if ($script:FILE_ERRORS -eq 1 -or $script:ERROR_COUNT -gt 0) {
        $rc = $script:EXIT_FILE_ERRORS
    } else {
        $strictTotal = $script:KEPT_BOM_COUNT + $script:PROTECTED_UTF16_COUNT +
        $script:PROTECTED_BINARY_COUNT + $script:PROTECTED_INVALID_COUNT + $script:SKIPPED_SIZE_COUNT
        if ($script:STRICT -eq 1 -and $strictTotal -gt 0) {
            Write-LogWarn "--strict: $strictTotal file(s) kept/protected/skipped"
            $rc = $script:EXIT_FILE_ERRORS
        } elseif ($script:CHECK_MODE -eq 1 -and $script:WOULD_CHANGE_COUNT -gt 0) {
            $rc = $script:EXIT_CHECK_FOUND
        }
    }
    throw [CleanBomFatalException]::new($rc, 'finished')
}

#------------------------------------------------------------------------------
# Entry point
#------------------------------------------------------------------------------
$script:UTF8_NO_BOM_ENC = New-Object System.Text.UTF8Encoding($false)

# stdout is the machine channel (--json / --help / --version): make sure the
# bytes on it are UTF-8 regardless of the host console code page, and restore
# whatever we found on the way out.
try { $script:SAVED_OUT_ENC = [Console]::OutputEncoding } catch { $script:SAVED_OUT_ENC = $null }
try { $script:SAVED_ERR_ENC = [Console]::ErrorEncoding } catch { $script:SAVED_ERR_ENC = $null }
try { [Console]::OutputEncoding = $script:UTF8_NO_BOM_ENC } catch { }
try { [Console]::ErrorEncoding = $script:UTF8_NO_BOM_ENC } catch { }

$script:CancelRegistration = $null
try {
    $handler = [System.EventHandler]{
        Remove-RegisteredTempFiles
        [System.Environment]::Exit(130)
    }
    $script:CancelRegistration = [Console]::add_CancelKeyPress($handler)
} catch { }

try {
    $argvList = [string[]]@()
    if ($null -ne $args -and $args.Count -gt 0) {
        $argvList = [string[]]@($args | ForEach-Object { "$_" })
    }
    Invoke-Main -ArgList $argvList
    $script:ExitCode = 0
} catch [CleanBomFatalException] {
    $script:ExitCode = $_.Exception.Code
} catch {
    Write-LogError "Critical internal error: $($_.Exception.Message)"
    $script:ExitCode = $script:EXIT_INTERNAL
} finally {
    if ($null -ne $script:CancelRegistration) {
        try { [Console]::remove_CancelKeyPress($script:CancelRegistration) } catch { }
    }
    Remove-RegisteredTempFiles
    if ($null -ne $script:SAVED_OUT_ENC) { try { [Console]::OutputEncoding = $script:SAVED_OUT_ENC } catch { } }
    if ($null -ne $script:SAVED_ERR_ENC) { try { [Console]::ErrorEncoding = $script:SAVED_ERR_ENC } catch { } }
}

exit $script:ExitCode
