#!/usr/bin/env pwsh
#Requires -Version 7.6
#Requires -PSEdition Core
<#
.SYNOPSIS
    Clean BOM Senior v3 - PowerShell port test suite.

.DESCRIPTION
    Mirrors tests/sh/run-tests.sh against clean-bom-senior.ps1, so the PowerShell
    port is pinned to the same CLI contract (docs/CLI-CONTRACT.md) as the shell
    reference and the Node implementation. The differential run at the end
    compares this port against the reference byte for byte on shared fixtures
    (tests/ps/differential.py).

    The tool is invoked IN-PROCESS through Invoke-Command with a script block,
    which is not a micro-optimisation: spawning pwsh costs about a second, so an
    out-of-process suite of this size would take minutes. Invoke-Command gives a
    child scope, which means the tool's top-level `exit` cannot terminate this
    process - the exit code is read back from the child scope afterwards.

    Two invocation traps are handled here and are worth knowing if you extend
    the suite:
      * `& $script a,b` and `& $script @(a,b)` both hand the script ONE string
        argument "a b". Splatting only works against a variable holding a real
        array, hence `[string[]]$toolArgs` + `& $toolPath @toolArgs`.
      * the tool writes with [Console]::Out / [Console]::Error, which bypasses
        PowerShell's stream plumbing, so capturing needs [Console]::SetOut /
        SetError rather than `2>&1 | Out-String`.

.NOTES
    Usage:  pwsh -NoLogo -NoProfile -File tests/ps/run-tests.ps1 [FILTER]
    Exit:   0 = all passed, 1 = failures, 2 = prerequisite missing.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT = Resolve-Path (Join-Path $HERE '..' '..')
$TOOL = Join-Path $REPO_ROOT 'clean-bom-senior.ps1'
$SH_TOOL = Join-Path $REPO_ROOT 'clean-bom-senior.sh'
$DIFF_PY = Join-Path $HERE 'differential.py'

if (-not (Test-Path $TOOL)) {
    [Console]::Error.Write("FATAL: implementation not found: $TOOL`n")
    exit 2
}

$FILTER = if ($args.Count -ge 1) { $args[0] } else { '' }
$HAVE_BASH = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
$HAVE_PYTHON = $null -ne (Get-Command python3 -ErrorAction SilentlyContinue)
$HAVE_GIT = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$IS_UNIX = -not $IsWindows

$script:PASS = 0
$script:FAIL = 0
$script:FAILED = New-Object System.Collections.Generic.List[string]
$script:WS = $null
$script:LAST_LOG = ''

$color = if ([Console]::IsOutputRedirected) {
    @{ red = ''; grn = ''; ylw = ''; rst = '' }
} else {
    @{ red = "`e[0;31m"; grn = "`e[0;32m"; ylw = "`e[1;33m"; rst = "`e[0m" }
}

# Unicode escapes rather than literals: this file must stay pure ASCII so it can
# be parsed by Windows PowerShell 5.1 too, and so this tool never wants to strip
# a BOM from it (`.ps1` is a sensitive extension under the Smart BOM Policy).
$EMDASH = [string][char]0x2014

#------------------------------------------------------------------------------
# Harness
#------------------------------------------------------------------------------
function New-Ws {
    if ($script:WS -and -not $env:CLEANBOM_PS_KEEPWS) {
    Remove-Item -LiteralPath $script:WS -Recurse -Force -ErrorAction SilentlyContinue
} elseif ($script:WS) {
    [Console]::Out.Write("workspace kept at: $($script:WS)`n")
}
    $script:WS = Join-Path ([System.IO.Path]::GetTempPath()) ("cleanbom-ps-test." + [System.IO.Path]::GetRandomFileName())
    $null = New-Item -ItemType Directory -Path $script:WS -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $script:WS 'work') -Force
    $script:LAST_LOG = Join-Path $script:WS 'stderr.log'
}

function Get-WorkPath { param([string]$Name) return (Join-Path (Join-Path $script:WS 'work') $Name) }

function Write-Fixture {
    # Fixture bytes are given as hex so this file stays ASCII-only.
    param([string]$Name, [string]$Hex)
    $p = Get-WorkPath $Name
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    [System.IO.File]::WriteAllBytes($p, $bytes)
}

function Get-FixtureHex {
    param([string]$Name)
    $p = if ([System.IO.Path]::IsPathRooted($Name)) { $Name } else { Get-WorkPath $Name }
    if (-not (Test-Path $p)) { return '<missing>' }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $sb = [System.Text.StringBuilder]::new($bytes.Length * 2)
    foreach ($b in $bytes) { $null = $sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Invoke-Tool {
    # Runs clean-bom-senior.ps1 in the fixture directory, in-process, capturing
    # both console streams and the exit code.
    param([string[]]$ToolArgs)
    $work = Join-Path $script:WS 'work'
    $outFile = Join-Path $script:WS 'stdout.log'
    $errFile = $script:LAST_LOG
    $toolPath = $TOOL

    $realOut = [Console]::Out
    $realErr = [Console]::Error
    $swOut = [System.IO.StringWriter]::new()
    $swErr = [System.IO.StringWriter]::new()
    $savedCwd = [Environment]::CurrentDirectory
    $rc = 0
    try {
        [Console]::SetOut($swOut)
        [Console]::SetError($swErr)
        [Environment]::CurrentDirectory = $work
        # Push-Location as well, not only the process CWD: PowerShell
        # re-syncs [Environment]::CurrentDirectory to its own Location before
        # launching a native command, so without this every external helper the
        # tool shells out to (stat for the link count, git, chmod) would resolve
        # relative paths against the wrong directory - and a hard-linked file
        # would silently lose its in-place rewrite.
        Push-Location -LiteralPath $work
        # Splatting requires a real array variable; see the header note.
        # The tool prints exclusively through [Console]::Out / [Console]::Error,
        # both redirected above, so the only thing this script block emits is
        # $LASTEXITCODE. Capturing anything else alongside it would turn $r into
        # an array and silently break the cast.
        [string[]]$toolArgs = $ToolArgs
        $r = Invoke-Command -ScriptBlock {
            & $toolPath @toolArgs
            $LASTEXITCODE
        }
        $rc = if ($null -eq $r) { 0 } else { [int]$r }
    } finally {
        Pop-Location
        [Console]::SetOut($realOut)
        [Console]::SetError($realErr)
        [Environment]::CurrentDirectory = $savedCwd
    }
    [System.IO.File]::WriteAllText($outFile, $swOut.ToString(), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($errFile, $swErr.ToString(), [System.Text.UTF8Encoding]::new($false))
    return $rc
}

function Get-ToolStdout { return [System.IO.File]::ReadAllText((Join-Path $script:WS 'stdout.log')) }
function Get-ToolStderr { return [System.IO.File]::ReadAllText($script:LAST_LOG) }

function Write-Ok { param([string]$Name) $script:PASS++; [Console]::Out.Write("$($color.grn)ok$($color.rst)   $Name`n") }
function Write-Bad {
    param([string]$Name, [string]$Detail = '')
    $script:FAIL++
    $script:FAILED.Add($Name)
    [Console]::Out.Write("$($color.red)FAIL$($color.rst) $Name`n")
    if ($Detail -cne '') { [Console]::Out.Write("       $Detail`n") }
}

function Assert-Bytes {
    param([string]$Name, [string]$WantHex, [string]$Label)
    $got = Get-FixtureHex $Name
    if ($got -ceq $WantHex) { Write-Ok $Label } else { Write-Bad $Label "bytes of ${Name}: got [$got] want [$WantHex]" }
}
function Assert-Rc { param([int]$Got, [int]$Want, [string]$Label)
    if ($Got -eq $Want) { Write-Ok "$Label (rc=$Got)" } else { Write-Bad $Label "exit code: got $Got want $Want`n--- stderr ---`n$((Get-ToolStderr).Substring(0, [Math]::Min(600, (Get-ToolStderr).Length)))" }
}
function Assert-Grep { param([string]$Haystack, [string]$Needle, [string]$Label)
    if ($Haystack.Contains($Needle)) { Write-Ok $Label } else { Write-Bad $Label "[$Needle] not found in output" }
}
function Assert-NotGrep { param([string]$Haystack, [string]$Needle, [string]$Label)
    if (-not $Haystack.Contains($Needle)) { Write-Ok $Label } else { Write-Bad $Label "[$Needle] unexpectedly present" }
}
function Assert-NoFile { param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { Write-Ok $Label } else { Write-Bad $Label "unexpected file: $Path" }
}
function Write-Section { param([string]$Title) [Console]::Out.Write("`n$($color.ylw)== $Title ==$($color.rst)`n") }

$script:TESTS = New-Object System.Collections.Generic.List[object]
function Add-Test { param([string]$Name, [scriptblock]$Body) $script:TESTS.Add([pscustomobject]@{ Name = $Name; Body = $Body }) }

$BOM = 'efbbbf'
$CRLF = '0d0a'

#==============================================================================
# 1. Core cleaning
#==============================================================================
Write-Section 'core cleaning'

Add-Test 'core: BOM+CRLF php' {
    New-Ws
    Write-Fixture 'a.php' "${BOM}3c3f706870${CRLF}6563686f20313b${CRLF}"
    $rc = Invoke-Tool @('--quiet', 'a.php')
    Assert-Rc $rc 0 'BOM+CRLF php: exit 0'
    Assert-Bytes 'a.php' '3c3f7068700a6563686f20313b0a' 'BOM stripped, CRLF normalised'
}

Add-Test 'core: BOM only' {
    New-Ws
    Write-Fixture 'b.php' "${BOM}3c3f7068700a"
    $null = Invoke-Tool @('--quiet', 'b.php')
    Assert-Bytes 'b.php' '3c3f7068700a' 'BOM-only file: BOM stripped, LF preserved'
}

Add-Test 'core: CRLF only' {
    New-Ws
    Write-Fixture 'c.css' "636c65616e${CRLF}66696c65${CRLF}"
    $null = Invoke-Tool @('--quiet', 'c.css')
    Assert-Bytes 'c.css' '636c65616e0a66696c650a' 'CRLF-only file normalised, no BOM added'
}

Add-Test 'core: clean file untouched (identity + mtime stable)' {
    New-Ws
    Write-Fixture 'd.php' '3c3f7068700a'
    $before = [System.IO.FileInfo]::new((Get-WorkPath 'd.php'))
    $mtime = $before.LastWriteTimeUtc
    $inode = if ($IS_UNIX) { (& stat -c '%i' -- $before.FullName | Out-String).Trim() } else { '' }
    # age the file so a rewrite would be visible in the timestamp
    $before.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-3)
    $mtime = $before.LastWriteTimeUtc
    $null = Invoke-Tool @('--quiet', 'd.php')
    $after = [System.IO.FileInfo]::new((Get-WorkPath 'd.php'))
    if ($after.LastWriteTimeUtc -eq $mtime) { Write-Ok 'clean file: mtime unchanged' }
    else { Write-Bad 'clean file: mtime unchanged' "was $mtime now $($after.LastWriteTimeUtc)" }
    if (-not $IS_UNIX) { Write-Ok 'clean file: inode check skipped (Windows)' }
    else {
        $inode2 = (& stat -c '%i' -- $after.FullName | Out-String).Trim()
        if ($inode -ceq $inode2) { Write-Ok 'clean file: inode stable (not rewritten)' }
        else { Write-Bad 'clean file: inode stable (not rewritten)' "$inode -> $inode2" }
    }
}

Add-Test 'core: empty file' {
    New-Ws
    Write-Fixture 'e.php' ''
    $rc = Invoke-Tool @('--quiet', 'e.php')
    Assert-Rc $rc 0 'empty file: exit 0'
    Assert-Bytes 'e.php' '' 'empty file stays empty'
}

Add-Test 'core: 3-byte BOM-only file becomes empty' {
    New-Ws
    Write-Fixture 'f.php' $BOM
    $null = Invoke-Tool @('--quiet', 'f.php')
    Assert-Bytes 'f.php' '' 'BOM-only file becomes zero bytes (no newline added)'
}

Add-Test 'core: no trailing newline preserved' {
    New-Ws
    Write-Fixture 'g.php' "${BOM}3c3f7068700a6563686f20313b"
    $null = Invoke-Tool @('--quiet', 'g.php')
    Assert-Bytes 'g.php' '3c3f7068700a6563686f20313b' 'no trailing newline is added'
}

Add-Test 'core: CRLF past byte 1024 (v2 regression)' {
    New-Ws
    $pad = '61' * 1100           # 1100 'a' bytes, well past v2's 1024-byte window
    Write-Fixture 'h.php' "$pad${CRLF}62"
    $null = Invoke-Tool @('--quiet', 'h.php')
    $got = Get-FixtureHex 'h.php'
    if ($got -ceq ($pad + '0a' + '62')) { Write-Ok 'late CRLF is found (whole-file scan)' }
    else { Write-Bad 'late CRLF is found (whole-file scan)' "tail got [$($got.Substring($got.Length - 8))]" }
}

Add-Test 'core: hex false positive regression (30 d0 a5)' {
    New-Ws
    # v2 scanned a HEX RENDERING for the substring "0d0a", so the byte run
    # 30 D0 A5 (which renders as "30d0a5") matched and the file was rewritten.
    Write-Fixture 'i.php' "${BOM}30d0a5"
    $null = Invoke-Tool @('--quiet', 'i.php')
    Assert-Bytes 'i.php' '30d0a5' 'byte run 30 D0 A5 is not mistaken for CRLF (BOM still stripped)'
}

Add-Test 'core: uppercase extension .PHP' {
    New-Ws
    Write-Fixture 'j.PHP' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '.')
    Assert-Bytes 'j.PHP' '780a' 'uppercase extension is matched'
}

Add-Test 'core: lone CRs and EOF CR semantics' {
    New-Ws
    # a lone CR at EOF is not a CRLF: the file must not be flagged
    Write-Fixture 'k.php' '780d'
    $null = Invoke-Tool @('--quiet', 'k.php')
    Assert-Bytes 'k.php' '780d' 'lone CR at EOF: file untouched'
    # a lone CR mid-line survives; the real CRLF at the end is normalised
    Write-Fixture 'l.php' "61${CRLF}620d63${CRLF}"
    $null = Invoke-Tool @('--quiet', 'l.php')
    Assert-Bytes 'l.php' '610a620d630a' 'lone CR mid-line preserved, CRLFs normalised'
    # a file whose only CR is at EOF but which is rewritten for its BOM loses
    # that CR too: the documented v2 `sed s/\r$//` semantics
    Write-Fixture 'm.php' "${BOM}780d"
    $null = Invoke-Tool @('--quiet', 'm.php')
    Assert-Bytes 'm.php' '78' 'EOF CR dropped when the file is rewritten anyway'
}

#==============================================================================
# 2. Smart BOM Policy - the safety core
#==============================================================================
Write-Section 'Smart BOM Policy'

Add-Test 'policy: CRLF detection is byte-exact, not line-based' {
    New-Ws
    # UTF-16LE line break = 0D 00 0A: a CR at end-of-line, but NOT the pair
    # 0D 0A. A line-based detector flags this file and reports it as a
    # protected UTF-16 file, which inflates protectedUtf16or32.
    Write-Fixture 'u16le.txt' 'fffe680069000d000a00'
    Write-Fixture 'u16be.xml' 'feff0068006900000d000a'
    $rc = Invoke-Tool @('--quiet', 'u16le.txt', 'u16be.xml')
    Assert-Bytes 'u16le.txt' 'fffe680069000d000a00' 'utf16le without a 0D0A pair: untouched'
    Assert-Bytes 'u16be.xml' 'feff0068006900000d000a' 'utf16be without a 0D0A pair: untouched'
    Assert-NotGrep (Get-ToolStderr) 'structurally required' 'no UTF-16 refusal is logged'
    $null = Invoke-Tool @('--json', '--quiet', 'u16le.txt', 'u16be.xml')
    $j = Get-ToolStdout | ConvertFrom-Json
    if ($j.summary.protectedUtf16or32 -eq 0) { Write-Ok 'protectedUtf16or32 stays 0' }
    else { Write-Bad 'protectedUtf16or32 stays 0' "got $($j.summary.protectedUtf16or32)" }
    if ($j.summary.clean -eq 2) { Write-Ok 'both are clean, not candidates' }
    else { Write-Bad 'both are clean, not candidates' "got clean=$($j.summary.clean)" }
    # ... while a real 0D 0A pair inside UTF-16 IS a refusal
    Write-Fixture 'u16mix.txt' 'fffe68000d0a5a5a'
    $null = Invoke-Tool @('--quiet', 'u16mix.txt')
    Assert-Bytes 'u16mix.txt' 'fffe68000d0a5a5a' 'utf16le WITH a real 0D0A pair: still never touched'
    Assert-Grep (Get-ToolStderr) 'structurally required' 'the real-CRLF case is refused and explained'
}

Add-Test 'policy: UTF-16LE never touched (incl. embedded ASCII CRLF)' {
    New-Ws
    Write-Fixture 'u16.txt' 'fffe680069000d000a00'
    $null = Invoke-Tool @('--quiet', 'u16.txt')
    Assert-Bytes 'u16.txt' 'fffe680069000d000a00' 'utf16le: never touched'
    Write-Fixture 'u16mix.txt' 'fffe68000d0a5a5a'
    $r = Invoke-Tool @('--quiet', 'u16mix.txt')
    Assert-Bytes 'u16mix.txt' 'fffe68000d0a5a5a' 'utf16le with ASCII CRLF inside: still never touched'
    Assert-Grep (Get-ToolStderr) 'structurally required' 'utf16: refusal explained'
}

Add-Test 'policy: UTF-16BE / UTF-32 protected, even with --force' {
    New-Ws
    Write-Fixture 'u16be.txt' 'feff006800690d0a'
    Write-Fixture 'u32le.txt' 'fffe0000680000000d0a'
    Write-Fixture 'u32be.txt' '0000feff000000680d0a'
    $null = Invoke-Tool @('--quiet', 'u16be.txt', 'u32le.txt', 'u32be.txt')
    Assert-Bytes 'u16be.txt' 'feff006800690d0a' 'utf16be: never touched'
    Assert-Bytes 'u32le.txt' 'fffe0000680000000d0a' 'utf32le: never touched'
    Assert-Bytes 'u32be.txt' '0000feff000000680d0a' 'utf32be: never touched'
    $null = Invoke-Tool @('--quiet', '--force', 'u16be.txt', 'u32le.txt', 'u32be.txt')
    Assert-Bytes 'u16be.txt' 'feff006800690d0a' 'utf16be: --force cannot override a hard refusal'
    Assert-Bytes 'u32le.txt' 'fffe0000680000000d0a' 'utf32le: --force cannot override a hard refusal'
}

Add-Test 'policy: binary NUL never touched (incl. NUL beyond 8 KiB)' {
    New-Ws
    Write-Fixture 'bin1.txt' "${BOM}42494e004152590d0a"
    Write-Fixture 'bin2.js' "42494e004152590d0a"
    $lateNul = ('61' * 9000) + '00' + ('62' * 10) + $CRLF
    Write-Fixture 'bin3.php' $lateNul
    $null = Invoke-Tool @('--quiet', 'bin1.txt', 'bin2.js', 'bin3.php')
    Assert-Bytes 'bin1.txt' "${BOM}42494e004152590d0a" 'binary with BOM: never touched'
    Assert-Bytes 'bin2.js' "42494e004152590d0a" 'binary no BOM + CRLF: never touched'
    Assert-Bytes 'bin3.php' $lateNul 'NUL beyond 8 KiB: whole-file detection'
    Assert-Grep (Get-ToolStderr) 'NUL bytes' 'binary refusal is explained'
    $null = Invoke-Tool @('--quiet', '--force', 'bin2.js')
    Assert-Bytes 'bin2.js' "42494e004152590d0a" '--force cannot override the NUL refusal'
}

Add-Test 'policy: invalid UTF-8 protected; --force cleans byte-level' {
    New-Ws
    Write-Fixture 'bad.php' "${BOM}c32820696e76${CRLF}"
    $null = Invoke-Tool @('--quiet', 'bad.php')
    Assert-Bytes 'bad.php' "${BOM}c32820696e76${CRLF}" 'invalid UTF-8: not touched by default'
    Assert-Grep (Get-ToolStderr) 'not valid UTF-8' 'invalid UTF-8 is explained'
    $null = Invoke-Tool @('--json', '--quiet', 'bad.php')
    $j = Get-ToolStdout | ConvertFrom-Json
    $e = $j.files | Where-Object { $_.status -ceq 'protected' } | Select-Object -First 1
    if ($e -and $e.reason -ceq 'invalid-utf8') { Write-Ok '--json: reason=invalid-utf8' }
    else { Write-Bad '--json: reason=invalid-utf8' "got $($e.reason)" }
    $null = Invoke-Tool @('--quiet', '--force', 'bad.php')
    Assert-Bytes 'bad.php' 'c32820696e760a' '--force: byte-level cleaning of invalid UTF-8'
}

Add-Test 'policy: sensitive txt keeps BOM, CRLF still fixed' {
    New-Ws
    Write-Fixture 's.txt' "${BOM}636166c3a9${CRLF}6c32${CRLF}"
    $null = Invoke-Tool @('s.txt')             # no --quiet: the explanation is INFO
    Assert-Bytes 's.txt' "${BOM}636166c3a90a6c320a" 'sensitive .txt: BOM kept, CRLF fixed'
    Assert-Grep (Get-ToolStderr) 'BOM kept' 'the keep decision is explained'
    $null = Invoke-Tool @('--json', '--quiet', 's.txt')
    $j = Get-ToolStdout | ConvertFrom-Json
    $e = $j.files | Where-Object { $_.status -ceq 'kept' } | Select-Object -First 1
    if ($e -and $e.reason -ceq 'bom-may-be-required' -and $e.bomKept) { Write-Ok '--json: kept + bom-may-be-required' }
    else { Write-Bad '--json: kept + bom-may-be-required' "got status=$($e.status) reason=$($e.reason)" }
}

Add-Test 'policy: --force strips sensitive BOM' {
    New-Ws
    Write-Fixture 's.txt' "${BOM}636166c3a9${CRLF}"
    $null = Invoke-Tool @('--quiet', '--force', 's.txt')
    Assert-Bytes 's.txt' '636166c3a90a' '--force strips a may-be-required BOM'
}

Add-Test 'policy: ASCII-only sensitive txt gets BOM stripped' {
    New-Ws
    Write-Fixture 'a.txt' "${BOM}706c61696e${CRLF}"
    $null = Invoke-Tool @('--quiet', 'a.txt')
    Assert-Bytes 'a.txt' '706c61696e0a' 'pure-ASCII .txt: BOM carries no information, so it goes'
}

Add-Test 'policy: --bom-policy keep/strip' {
    New-Ws
    Write-Fixture 'k.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--bom-policy=keep', 'k.php')   # no --quiet: INFO
    Assert-Bytes 'k.php' "${BOM}780a" '--bom-policy=keep: BOM kept, CRLF still fixed'
    Assert-Grep (Get-ToolStderr) 'BOM kept' 'keep is reported'
    Write-Fixture 's2.txt' "${BOM}636166c3a9${CRLF}"
    $null = Invoke-Tool @('--quiet', '--bom-policy=strip', 's2.txt')
    Assert-Bytes 's2.txt' '636166c3a90a' '--bom-policy=strip: sensitive BOM stripped'
}

Add-Test 'policy: sensitive-ext customization' {
    New-Ws
    Write-Fixture 'x.dat' "${BOM}636166c3a9${CRLF}"
    $null = Invoke-Tool @('--quiet', '--add-ext', 'dat', 'x.dat')
    Assert-Bytes 'x.dat' "${BOM}636166c3a90a" 'unknown extension is treated as sensitive'
    Write-Fixture 'y.dat' "${BOM}636166c3a9${CRLF}"
    $null = Invoke-Tool @('--quiet', '--add-ext', 'dat', '--sensitive-ext', '', 'y.dat')
    Assert-Bytes 'y.dat' '636166c3a90a' "--sensitive-ext '' disables sensitivity"
    Write-Fixture 'z.php' "${BOM}636166c3a9${CRLF}"
    $null = Invoke-Tool @('--quiet', '--sensitive-ext', 'php', 'z.php')
    Assert-Bytes 'z.php' "${BOM}636166c3a90a" '--sensitive-ext can make a code extension sensitive'
}

Add-Test 'policy: --no-bom-clear' {
    New-Ws
    Write-Fixture 'n.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-bom-clear', 'n.php')
    Assert-Bytes 'n.php' "${BOM}780a" '--no-bom-clear: CRLF fixed, BOM left alone'
}

Add-Test 'policy: --no-crlf-normalize and its v2 alias' {
    New-Ws
    Write-Fixture 'c.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-crlf-normalize', 'c.php')
    Assert-Bytes 'c.php' '780d0a' '--no-crlf-normalize: BOM stripped, CRLF really left intact'
    Write-Fixture 'c2.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-rn-normalize', 'c2.php')
    Assert-Bytes 'c2.php' '780d0a' '--no-rn-normalize (v2 name) behaves identically'
}

Add-Test 'policy: both disabled rewrites nothing' {
    New-Ws
    Write-Fixture 'b.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-bom-clear', '--no-crlf-normalize', 'b.php')
    Assert-Bytes 'b.php' "${BOM}78${CRLF}" 'both transforms off: the file is not a candidate at all'
}

#==============================================================================
# 3. Metadata safety
#==============================================================================
Write-Section 'metadata safety'

Add-Test 'meta: mtime preserved by default; --update-mtime refreshes' {
    New-Ws
    Write-Fixture 'm.php' "${BOM}78${CRLF}"
    $f = [System.IO.FileInfo]::new((Get-WorkPath 'm.php'))
    $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-3)
    $old = $f.LastWriteTimeUtc
    $null = Invoke-Tool @('--quiet', 'm.php')
    $now = [System.IO.FileInfo]::new((Get-WorkPath 'm.php')).LastWriteTimeUtc
    if ([Math]::Abs(($now - $old).TotalSeconds) -lt 2) { Write-Ok 'mtime of a modified file is preserved' }
    else { Write-Bad 'mtime of a modified file is preserved' "$old -> $now" }

    Write-Fixture 'm2.php' "${BOM}78${CRLF}"
    $f2 = [System.IO.FileInfo]::new((Get-WorkPath 'm2.php'))
    $f2.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-3)
    $old2 = $f2.LastWriteTimeUtc          # read the baseline BEFORE the run
    $null = Invoke-Tool @('--quiet', '--update-mtime', 'm2.php')
    $now2 = [System.IO.FileInfo]::new((Get-WorkPath 'm2.php')).LastWriteTimeUtc
    if (($now2 - $old2).TotalDays -gt 1) { Write-Ok '--update-mtime refreshes the timestamp' }
    else { Write-Bad '--update-mtime refreshes the timestamp' "$old2 -> $now2" }
}

if ($IS_UNIX) {
    Add-Test 'meta: permissions preserved (POSIX)' {
        New-Ws
        Write-Fixture 'p.php' "${BOM}78${CRLF}"
        $p = Get-WorkPath 'p.php'
        & chmod 640 -- $p
        $null = Invoke-Tool @('--quiet', 'p.php')
        $mode = (& stat -c '%a' -- $p | Out-String).Trim()
        if ($mode -ceq '640') { Write-Ok 'permissions transferred to the replacement file' }
        else { Write-Bad 'permissions transferred to the replacement file' "mode is $mode, want 640" }
    }

    Add-Test 'meta: hard links rewritten in place' {
        New-Ws
        Write-Fixture 'h.php' "${BOM}78${CRLF}"
        $p = Get-WorkPath 'h.php'
        $link = Get-WorkPath 'h_link.php'
        & ln -- $p $link                      # ln TARGET LINK, in that order
        $n0 = (& stat -c '%h' -- $p | Out-String).Trim()
        if ($n0 -cne '2') { Write-Bad 'fixture has two hard links' "got nlink=$n0"; return }
        Write-Ok 'fixture has two hard links'
        $i1 = (& stat -c '%i' -- $p | Out-String).Trim()
        $null = Invoke-Tool @('--quiet', 'h.php')
        Assert-Grep (Get-ToolStderr) 'hard links' 'hard links are detected and reported'
        Assert-Bytes 'h_link.php' '780a' 'the second link sees the fix (rewritten through the inode)'
        $i2 = (& stat -c '%i' -- $p | Out-String).Trim()
        if ($i1 -ceq $i2) { Write-Ok 'the inode is preserved (in-place rewrite)' }
        else { Write-Bad 'the inode is preserved (in-place rewrite)' "$i1 -> $i2" }
        $n = (& stat -c '%h' -- $p | Out-String).Trim()
        if ($n -ceq '2') { Write-Ok 'link count is still 2' } else { Write-Bad 'link count is still 2' "got $n" }
    }
}

Add-Test 'meta: symlink argument resolves to the target' {
    New-Ws
    Write-Fixture 'real.php' "${BOM}78${CRLF}"
    $real = Get-WorkPath 'real.php'
    $link = Get-WorkPath 'link.php'
    try { New-Item -ItemType SymbolicLink -Path $link -Target 'real.php' -ErrorAction Stop | Out-Null }
    catch { Write-Ok 'symlink argument: SKIPPED (no symlink privilege)'; return }
    $null = Invoke-Tool @('link.php')          # no --quiet: the note is INFO
    Assert-Grep (Get-ToolStderr) 'Symlink argument resolved' 'the resolution is logged'
    Assert-Bytes 'real.php' '780a' 'the symlink TARGET is what gets cleaned'
}

Add-Test 'meta: --backup and --backup-dir' {
    New-Ws
    Write-Fixture 'k.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--backup', 'k.php')
    $baks = @(Get-ChildItem -LiteralPath (Join-Path $script:WS 'work') -Filter 'k.php.bak.*' -Force)
    if ($baks.Count -eq 1) { Write-Ok '--backup leaves exactly one <file>.bak.<pid>' }
    else { Write-Bad '--backup leaves exactly one <file>.bak.<pid>' "found $($baks.Count)" }
    if ($baks.Count -eq 1) {
        $bh = [System.IO.File]::ReadAllBytes($baks[0].FullName)
        $sb = [System.Text.StringBuilder]::new()
        foreach ($b in $bh) { $null = $sb.Append($b.ToString('x2')) }
        if ($sb.ToString() -ceq "${BOM}78${CRLF}") { Write-Ok 'the backup holds the ORIGINAL bytes' }
        else { Write-Bad 'the backup holds the ORIGINAL bytes' "got $($sb.ToString())" }
    }

    New-Ws
    Write-Fixture 'sub/d.php' "${BOM}78${CRLF}"
    $bd = Join-Path $script:WS 'bakdir'
    $null = Invoke-Tool @('--quiet', '--backup-dir', $bd, '.')
    $mirrored = Join-Path $bd 'sub/d.php'
    if (Test-Path $mirrored) { Write-Ok '--backup-dir mirrors the relative tree' }
    else { Write-Bad '--backup-dir mirrors the relative tree' "no $mirrored" }
}

Add-Test 'meta: no temp/backup leftovers' {
    New-Ws
    Write-Fixture 'x.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '.')
    $left = @(Get-ChildItem -LiteralPath (Join-Path $script:WS 'work') -Force |
        Where-Object { $_.Name -like '.cleanbom*' -or $_.Name -like '*.bak.*' -or $_.Name -like 'cleanbom*' })
    if ($left.Count -eq 0) { Write-Ok 'no temp or backup files left behind' }
    else { Write-Bad 'no temp or backup files left behind' ($left.Name -join ', ') }
}

Add-Test 'meta: idempotent second run' {
    New-Ws
    Write-Fixture 'i.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '.')
    $first = Get-FixtureHex 'i.php'
    $f = [System.IO.FileInfo]::new((Get-WorkPath 'i.php'))
    $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $mtime = $f.LastWriteTimeUtc
    $rc = Invoke-Tool @('--quiet', '.')
    Assert-Rc $rc 0 'second run: exit 0'
    Assert-Bytes 'i.php' $first 'second run changes nothing'
    $now = [System.IO.FileInfo]::new((Get-WorkPath 'i.php')).LastWriteTimeUtc
    if ($now -eq $mtime) { Write-Ok 'second run does not rewrite the clean file' }
    else { Write-Bad 'second run does not rewrite the clean file' "$mtime -> $now" }
}

#==============================================================================
# 4. Modes
#==============================================================================
Write-Section 'modes'

Add-Test 'mode: dry-run modifies nothing' {
    New-Ws
    Write-Fixture 'd.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('--dry-run', 'd.php')
    Assert-Rc $rc 0 '--dry-run: exit 0'
    Assert-Bytes 'd.php' "${BOM}78${CRLF}" '--dry-run writes nothing'
    Assert-Grep (Get-ToolStderr) 'Would process' '--dry-run reports what it would do'
    Assert-Grep (Get-ToolStderr) 'strip-bom + crlf-to-lf' '--dry-run names the actions'
}

Add-Test 'mode: --check exit codes and terse summary' {
    New-Ws
    Write-Fixture 'c.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('--check', 'c.php')
    Assert-Rc $rc 10 '--check on a dirty file: exit 10'
    Assert-Bytes 'c.php' "${BOM}78${CRLF}" '--check writes nothing'
    Assert-Grep (Get-ToolStderr) 'check: 1 file(s) need cleaning' '--check prints the terse summary'
    $null = Invoke-Tool @('--quiet', 'c.php')
    $rc2 = Invoke-Tool @('--check', 'c.php')
    Assert-Rc $rc2 0 '--check on a clean tree: exit 0'
    $rc3 = Invoke-Tool @('--check', '-v', 'c.php')
    Assert-Rc $rc3 0 '--check -v on a clean tree: exit 0'
    Assert-Grep (Get-ToolStderr) 'PROCESSING SUMMARY' '--check -v prints the full summary'
}

Add-Test 'mode: --json schema and counters' {
    New-Ws
    Write-Fixture 'j1.php' "${BOM}78${CRLF}"          # changed
    Write-Fixture 'j2.txt' "${BOM}636166c3a9${CRLF}"  # kept (sensitive + non-ASCII)
    Write-Fixture 'j3.css' '636c65616e0a'             # clean (not listed)
    Write-Fixture 'j4.js' "42494e00${CRLF}"           # protected binary
    $null = Invoke-Tool @('--json', '--quiet', '.')
    $raw = Get-ToolStdout
    try { $j = $raw | ConvertFrom-Json } catch { Write-Bad '--json emits valid JSON' $_.Exception.Message; return }
    Write-Ok '--json emits valid JSON'
    foreach ($k in 'tool', 'version', 'mode', 'startedAt', 'durationSeconds', 'cwd', 'options', 'summary', 'files') {
        if ($null -ne $j.PSObject.Properties[$k]) { Write-Ok "--json has the `"$k`" key" }
        else { Write-Bad "--json has the `"$k`" key" 'missing' }
    }
    if ($j.tool -ceq 'clean-bom-senior') { Write-Ok '--json tool name' } else { Write-Bad '--json tool name' $j.tool }
    if ($j.version -ceq '3.0.0') { Write-Ok '--json version' } else { Write-Bad '--json version' $j.version }
    if ($j.mode -ceq 'fix') { Write-Ok '--json mode=fix' } else { Write-Bad '--json mode=fix' $j.mode }
    if ($j.summary.changed -eq 2) { Write-Ok 'summary.changed = 2 (j1.php and j2.txt both change)' } else { Write-Bad 'summary.changed = 2 (j1.php and j2.txt both change)' "got $($j.summary.changed)" }
    if ($j.summary.bomKept -eq 1) { Write-Ok 'summary.bomKept = 1' } else { Write-Bad 'summary.bomKept = 1' "got $($j.summary.bomKept)" }
    if ($j.summary.protectedBinary -eq 1) { Write-Ok 'summary.protectedBinary = 1' } else { Write-Bad 'summary.protectedBinary = 1' "got $($j.summary.protectedBinary)" }
    if ($j.summary.clean -eq 1) { Write-Ok 'summary.clean = 1' } else { Write-Bad 'summary.clean = 1' "got $($j.summary.clean)" }
    $listed = @($j.files | ForEach-Object { $_.path })
    if ($listed -notcontains './j3.css') { Write-Ok 'clean files are counted but not listed' }
    else { Write-Bad 'clean files are counted but not listed' 'j3.css appears in files[]' }
    $changed = $j.files | Where-Object { $_.status -ceq 'changed' } | Select-Object -First 1
    if ($changed -and ($changed.actions -join ',') -ceq 'strip-bom,crlf-to-lf') { Write-Ok 'actions array order is strip-bom, crlf-to-lf' }
    else { Write-Bad 'actions array order is strip-bom, crlf-to-lf' "got [$($changed.actions -join ',')]" }
    if ($changed.encoding -ceq 'utf8-bom') { Write-Ok 'encoding is reported' } else { Write-Bad 'encoding is reported' $changed.encoding }
    # stdout must be PURE json: the log belongs on stderr
    if ($raw.TrimStart().StartsWith('{')) { Write-Ok 'stdout is pure JSON' } else { Write-Bad 'stdout is pure JSON' ($raw.Substring(0, [Math]::Min(80, $raw.Length))) }
}

Add-Test 'mode: --json in dry-run and check modes' {
    New-Ws
    Write-Fixture 'd.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--json', '--dry-run', 'd.php')
    $j = Get-ToolStdout | ConvertFrom-Json
    if ($j.mode -ceq 'dry-run') { Write-Ok '--json --dry-run: mode=dry-run' } else { Write-Bad '--json --dry-run: mode=dry-run' $j.mode }
    if ($j.summary.wouldChange -eq 1) { Write-Ok '--json --dry-run: wouldChange=1' } else { Write-Bad '--json --dry-run: wouldChange=1' "got $($j.summary.wouldChange)" }
    if (@($j.files)[0].status -ceq 'would-change') { Write-Ok '--json --dry-run: status=would-change' } else { Write-Bad '--json --dry-run: status=would-change' (@($j.files)[0].status) }
    $null = Invoke-Tool @('--json', '--check', 'd.php')
    $j2 = Get-ToolStdout | ConvertFrom-Json
    if ($j2.mode -ceq 'check') { Write-Ok '--json --check: mode=check' } else { Write-Bad '--json --check: mode=check' $j2.mode }
}

Add-Test 'mode: --strict' {
    New-Ws
    Write-Fixture 's.txt' "${BOM}636166c3a9${CRLF}"    # kept -> strict must fail
    $rc = Invoke-Tool @('--quiet', '--strict', 's.txt')
    Assert-Rc $rc 1 '--strict with a kept BOM: exit 1'
    Assert-Grep (Get-ToolStderr) '--strict' 'the strict verdict is explained'
    New-Ws
    Write-Fixture 'c.php' "${BOM}78${CRLF}"
    $rc2 = Invoke-Tool @('--quiet', '--strict', 'c.php')
    Assert-Rc $rc2 0 '--strict with nothing kept: exit 0'
}

Add-Test 'mode: --quiet / --silent' {
    New-Ws
    Write-Fixture 'q.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', 'q.php')
    $err = Get-ToolStderr
    Assert-NotGrep $err 'PROCESSING SUMMARY' '--quiet suppresses the summary'
    Assert-NotGrep $err 'CRLF Cleaner' '--quiet suppresses the greeting'

    New-Ws
    Write-Fixture 'q2.php' "${BOM}78${CRLF}"
    Write-Fixture 'q3.js' "42494e00${CRLF}"
    $null = Invoke-Tool @('--silent', '.')
    $err2 = Get-ToolStderr
    Assert-NotGrep $err2 'NUL bytes' '--silent suppresses warnings too (ERROR only, per the reference)'
    if ($err2.Trim() -ceq '') { Write-Ok '--silent: stderr completely empty apart from errors' }
    else { Write-Bad '--silent: stderr completely empty apart from errors' $err2.Trim() }
    Assert-NotGrep $err2 'PROCESSING SUMMARY' '--silent suppresses the summary'
}

Add-Test 'mode: --log-file' {
    New-Ws
    Write-Fixture 'l.php' "${BOM}78${CRLF}"
    $log = Join-Path $script:WS 'run.log'
    $null = Invoke-Tool @('--log-file', $log, '-v', 'l.php')   # -v: l.php is clean, so a quiet run would log nothing
    if (Test-Path $log) {
        $txt = [System.IO.File]::ReadAllText($log)
        Assert-Grep $txt 'run at' 'the log file has a run header'
        Assert-Grep $txt 'l.php' 'the log file records the file'
        Assert-NotGrep $txt "`e[" 'the log file is plain text (no ANSI)'
    } else { Write-Bad '--log-file creates the log' "no $log" }
}

#==============================================================================
# 5. Selection
#==============================================================================
Write-Section 'selection'

Add-Test 'select: directory argument, recursive' {
    New-Ws
    Write-Fixture 'src/a.php' "${BOM}78${CRLF}"
    Write-Fixture 'src/deep/b.php' "${BOM}79${CRLF}"
    Write-Fixture 'other/c.php' "${BOM}7a${CRLF}"
    $null = Invoke-Tool @('--quiet', 'src')
    Assert-Bytes 'src/a.php' '780a' 'directory argument: top level cleaned'
    Assert-Bytes 'src/deep/b.php' '790a' 'directory argument: recursion works'
    Assert-Bytes 'other/c.php' "${BOM}7a${CRLF}" 'directory argument: siblings are not touched'
    # A second fixture set, because the run above already cleaned this one and
    # an empty files[] would prove nothing about the display-path contract.
    Write-Fixture 'src2/deep/e.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--json', '--quiet', 'src2')
    $j = Get-ToolStdout | ConvertFrom-Json
    $paths = @($j.files | ForEach-Object { $_.path })
    if ($paths -contains 'src2/deep/e.php') { Write-Ok "display path for a directory argument has no ./ prefix ('src2/deep/e.php')" }
    else { Write-Bad "display path for a directory argument has no ./ prefix ('src2/deep/e.php')" ($paths -join ', ') }
}

Add-Test 'select: default recursive scan uses ./ display paths' {
    New-Ws
    Write-Fixture 'sub/z.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--json', '--quiet')
    $j = Get-ToolStdout | ConvertFrom-Json
    $paths = @($j.files | ForEach-Object { $_.path })
    if ($paths -contains './sub/z.php') { Write-Ok "recursive scan of '.' displays './sub/z.php'" }
    else { Write-Bad "recursive scan of '.' displays './sub/z.php'" ($paths -join ', ') }
}

Add-Test 'select: --ext / --add-ext' {
    New-Ws
    Write-Fixture 'a.md' "${BOM}78${CRLF}"
    Write-Fixture 'b.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--add-ext', 'md', '.')
    Assert-Bytes 'a.md' '780a' '--add-ext extends the default set'
    Assert-Bytes 'b.php' '780a' '--add-ext keeps the defaults'
    New-Ws
    Write-Fixture 'a.md' "${BOM}78${CRLF}"
    Write-Fixture 'b.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--ext', 'md', '.')
    Assert-Bytes 'a.md' '780a' '--ext replaces the set (md cleaned)'
    Assert-Bytes 'b.php' "${BOM}78${CRLF}" '--ext replaces the set (php untouched)'
    $null = Invoke-Tool @('--json', '--quiet', '--ext', 'PHP, .Md ', '.')
    $j = Get-ToolStdout | ConvertFrom-Json
    if ($j.options.extensions -ceq 'php md') { Write-Ok "extension list is normalised ('PHP, .Md ' -> 'php md')" }
    else { Write-Bad "extension list is normalised ('PHP, .Md ' -> 'php md')" "got [$($j.options.extensions)]" }
}

Add-Test 'select: exclusions' {
    New-Ws
    Write-Fixture 'src/a.php' "${BOM}78${CRLF}"
    Write-Fixture 'vendor/x.php' "${BOM}78${CRLF}"
    Write-Fixture 'node_modules/y.php' "${BOM}78${CRLF}"
    Write-Fixture 'dist/z.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '.')
    Assert-Bytes 'node_modules/y.php' "${BOM}78${CRLF}" 'node_modules is excluded by default'
    Assert-Bytes 'vendor/x.php' '780a' 'vendor is NOT excluded by default'
    New-Ws
    Write-Fixture 'src/a.php' "${BOM}78${CRLF}"
    Write-Fixture 'dist/z.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--exclude', 'dist/*', '.')
    Assert-Bytes 'dist/z.php' "${BOM}78${CRLF}" '--exclude glob skips the path'
    Assert-Bytes 'src/a.php' '780a' '--exclude leaves everything else alone'
    New-Ws
    Write-Fixture 'build/a.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--exclude-dir', 'build', '.')
    Assert-Bytes 'build/a.php' "${BOM}78${CRLF}" '--exclude-dir prunes the directory'
    New-Ws
    Write-Fixture 'node_modules/y.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-default-excludes', '.')
    Assert-Bytes 'node_modules/y.php' '780a' '--no-default-excludes lifts the defaults'
    New-Ws
    Write-Fixture 'node_modules/y.php' "${BOM}78${CRLF}"
    Write-Fixture 'keepme/d.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--quiet', '--no-default-excludes', '--exclude-dir', 'keepme', '.')
    Assert-Bytes 'node_modules/y.php' '780a' '--no-default-excludes: node_modules is scanned'
    Assert-Bytes 'keepme/d.php' "${BOM}78${CRLF}" '--no-default-excludes: explicit --exclude-dir survives'
}

Add-Test 'select: --max-size' {
    New-Ws
    Write-Fixture 'small.php' "${BOM}78${CRLF}"
    $big = $BOM + ('61' * 40) + $CRLF
    Write-Fixture 'big.php' $big
    $null = Invoke-Tool @('--max-size', '20', '.')       # no --quiet: INFO
    Assert-Bytes 'small.php' '780a' '--max-size: small file is cleaned'
    Assert-Bytes 'big.php' $big '--max-size: oversize file is skipped'
    Assert-Grep (Get-ToolStderr) 'oversize' 'the skip is reported (INFO)'
    $null = Invoke-Tool @('--json', '--quiet', '--max-size', '20', '.')
    $j = Get-ToolStdout | ConvertFrom-Json
    if ($j.summary.skippedOversize -eq 1) { Write-Ok 'summary.skippedOversize = 1' }
    else { Write-Bad 'summary.skippedOversize = 1' "got $($j.summary.skippedOversize)" }
    $e = $j.files | Where-Object { $_.status -ceq 'skipped-size' } | Select-Object -First 1
    if ($e -and $e.reason.Contains('larger than --max-size')) { Write-Ok 'skipped-size carries its reason' }
    else { Write-Bad 'skipped-size carries its reason' "got [$($e.reason)]" }
    # unit suffixes
    $null = Invoke-Tool @('--json', '--quiet', '--max-size', '1K', '.')
    $j2 = Get-ToolStdout | ConvertFrom-Json
    if ($j2.options.maxSizeBytes -eq 1024) { Write-Ok '--max-size 1K parses to 1024' } else { Write-Bad '--max-size 1K parses to 1024' "got $($j2.options.maxSizeBytes)" }
    $null = Invoke-Tool @('--json', '--quiet', '--max-size=2M', '.')
    $j3 = Get-ToolStdout | ConvertFrom-Json
    if ($j3.options.maxSizeBytes -eq 2097152) { Write-Ok '--max-size=2M parses to 2097152' } else { Write-Bad '--max-size=2M parses to 2097152' "got $($j3.options.maxSizeBytes)" }
}

Add-Test 'select: --git' {
    if (-not $HAVE_GIT) { Write-Ok '--git: SKIPPED (no git)'; return }
    New-Ws
    $work = Join-Path $script:WS 'work'
    $env:GIT_AUTHOR_NAME = 'Test'; $env:GIT_AUTHOR_EMAIL = 't@example.com'
    $env:GIT_COMMITTER_NAME = 'Test'; $env:GIT_COMMITTER_EMAIL = 't@example.com'
    Push-Location $work
    try {
        & git init -q . 2>$null | Out-Null
        Write-Fixture 'tracked.php' "${BOM}78${CRLF}"
        Write-Fixture 'untracked.php' "${BOM}79${CRLF}"
        & git add tracked.php 2>$null | Out-Null
    } finally { Pop-Location }
    $rc = Invoke-Tool @('--quiet', '--git')
    Assert-Rc $rc 0 '--git: exit 0'
    Assert-Bytes 'tracked.php' '780a' '--git cleans tracked files'
    Assert-Bytes 'untracked.php' "${BOM}79${CRLF}" '--git ignores untracked files'
}

#==============================================================================
# 6. CLI contract
#==============================================================================
Write-Section 'CLI contract'

Add-Test 'cli: unknown option' {
    New-Ws
    $rc = Invoke-Tool @('--bogus')
    Assert-Rc $rc 2 'unknown option: exit 2'
    Assert-Grep (Get-ToolStderr) 'Unknown option: --bogus' 'the offending token is named'
    # The reference handles an unknown token inline (log_error + exit 2) and
    # therefore prints NO "Try ... --help" hint here, unlike every other usage
    # error, which goes through die_usage. Pinned so the ports cannot drift.
    Assert-NotGrep (Get-ToolStderr) 'for more information' 'unknown option carries no --help hint (reference parity)'
    $rc2 = Invoke-Tool @('-Z')
    Assert-Rc $rc2 2 'unknown short option: exit 2'
    $rc3 = Invoke-Tool @('-')
    Assert-Rc $rc3 2 'a bare dash is an unknown option: exit 2'
    Assert-Grep (Get-ToolStderr) 'Unknown option: -' 'a bare dash is reported verbatim'
}

Add-Test 'cli: bad values' {
    New-Ws
    $rc = Invoke-Tool @('--bom-policy=nope')
    Assert-Rc $rc 2 'invalid --bom-policy: exit 2'
    Assert-Grep (Get-ToolStderr) 'auto|strip|keep' 'valid values are listed'
    $rc2 = Invoke-Tool @('--max-size=abc')
    Assert-Rc $rc2 2 'invalid --max-size: exit 2'
    $rc3 = Invoke-Tool @('--ext', '')
    Assert-Rc $rc3 2 'empty extension list: exit 2'
    $rc4 = Invoke-Tool @('--color', 'rainbow')
    Assert-Rc $rc4 2 'invalid --color: exit 2'
    $rc5 = Invoke-Tool @('--help', 'nosuchtopic')
    Assert-Rc $rc5 2 'unknown help topic: exit 2'
    Assert-Grep (Get-ToolStderr) 'Unknown help topic' 'the unknown topic is named'
    $rc6 = Invoke-Tool @('--max-size')
    Assert-Rc $rc6 2 '--max-size without a value: exit 2'
}

Add-Test 'cli: -- ends option parsing' {
    New-Ws
    Write-Fixture 'a.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('--quiet', '--', 'a.php')
    Assert-Rc $rc 0 '-- : exit 0'
    Assert-Bytes 'a.php' '780a' '-- : the path after it is processed'
}

Add-Test 'cli: missing file' {
    New-Ws
    $rc = Invoke-Tool @('--quiet', 'nope.php')
    Assert-Rc $rc 1 'missing file: exit 1'
    Assert-Grep (Get-ToolStderr) 'File not found: nope.php' 'the missing path is named'
}

Add-Test 'cli: mixed success and failure' {
    New-Ws
    Write-Fixture 'ok.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('--quiet', 'ok.php', 'nope.php')
    Assert-Rc $rc 1 'one good + one missing: exit 1'
    Assert-Bytes 'ok.php' '780a' 'the good file is still cleaned'
}

Add-Test 'cli: interspersed options' {
    New-Ws
    Write-Fixture 'a.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('a.php', '--quiet')
    Assert-Rc $rc 0 'options may follow positional paths'
    Assert-Bytes 'a.php' '780a' 'interspersed options are honoured'
}

Add-Test 'cli: --help and --version' {
    New-Ws
    $rc = Invoke-Tool @('--version')
    Assert-Rc $rc 0 '--version: exit 0'
    $out = Get-ToolStdout
    Assert-Grep $out 'clean-bom-senior.ps1 version 3.0.0' '--version prints "<name> version <X.Y.Z>"'
    Assert-Grep $out 'Mikhail Deynekin' '--version prints the author'
    Assert-Grep $out 'deynekin.com' '--version prints the website'

    foreach ($topic in '', 'usage', 'options', 'bom-policy', 'safety', 'exit-codes',
        'examples', 'env', 'ci', 'update', 'files', 'json', 'compatibility', 'topics') {
        $rc2 = if ($topic -ceq '') { Invoke-Tool @('--help') } else { Invoke-Tool @('--help', $topic) }
        if ($rc2 -ne 0) { Write-Bad "--help $topic exits 0" "rc=$rc2"; continue }
        $t = Get-ToolStdout
        if ($t.Length -gt 40) { Write-Ok "--help $topic prints on stdout" }
        else { Write-Bad "--help $topic prints on stdout" 'output too short' }
    }
    $full = Invoke-Tool @('--help')
    $txt = Get-ToolStdout
    Assert-Grep $txt 'SMART BOM POLICY' '--help (no topic) includes the policy section'
    Assert-Grep $txt 'SAFETY GUARANTEES' '--help (no topic) includes the safety section'
    Assert-Grep $txt 'EXIT CODES' '--help (no topic) includes the exit codes'
    # stdout is the machine channel, stderr must stay empty for --help
    if ((Get-ToolStderr).Trim() -ceq '') { Write-Ok '--help writes nothing to stderr' }
    else { Write-Bad '--help writes nothing to stderr' (Get-ToolStderr) }
}

Add-Test 'cli: CLEAN_BOM_OPTS is prepended' {
    New-Ws
    Write-Fixture 'e.php' "${BOM}78${CRLF}"
    $env:CLEAN_BOM_OPTS = '--quiet --strict'
    try {
        $rc = Invoke-Tool @('e.php')
        Assert-Bytes 'e.php' '780a' 'CLEAN_BOM_OPTS does not block cleaning'
    } finally { Remove-Item Env:\CLEAN_BOM_OPTS -ErrorAction SilentlyContinue }
    New-Ws
    Write-Fixture 'k.txt' "${BOM}636166c3a9${CRLF}"
    $env:CLEAN_BOM_OPTS = '--strict'
    try {
        $rc2 = Invoke-Tool @('--quiet', 'k.txt')
        Assert-Rc $rc2 1 'CLEAN_BOM_OPTS=--strict makes a kept BOM fail the run'
    } finally { Remove-Item Env:\CLEAN_BOM_OPTS -ErrorAction SilentlyContinue }
}

Add-Test 'cli: colour modes' {
    New-Ws
    Write-Fixture 'c.js' "42494e00${CRLF}"
    $null = Invoke-Tool @('--quiet', '--color', 'never', 'c.js')
    Assert-NotGrep (Get-ToolStderr) "`e[" '--color never emits no ANSI'
    $null = Invoke-Tool @('--quiet', '--color', 'always', 'c.js')
    Assert-Grep (Get-ToolStderr) "`e[" '--color always emits ANSI even when redirected'
    $null = Invoke-Tool @('--quiet', '--no-color', 'c.js')
    Assert-NotGrep (Get-ToolStderr) "`e[" '--no-color emits no ANSI'
    $env:NO_COLOR = '1'
    try {
        $null = Invoke-Tool @('--quiet', '--color', 'auto', 'c.js')
        Assert-NotGrep (Get-ToolStderr) "`e[" 'NO_COLOR disables auto colour'
    } finally { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }
}

Add-Test 'cli: summary counts and file-type distribution' {
    New-Ws
    Write-Fixture 'a.php' "${BOM}78${CRLF}"
    Write-Fixture 'b.php' "${BOM}79${CRLF}"
    Write-Fixture 'c.css' "${BOM}7a${CRLF}"
    Write-Fixture 'd.txt' '636c65616e0a'
    $null = Invoke-Tool @('.')
    $err = Get-ToolStderr
    Assert-Grep $err 'Files scanned: 4' 'summary: scanned count'
    Assert-Grep $err 'Files processed: 3' 'summary: processed count'
    Assert-Grep $err 'Files skipped (clean): 1' 'summary: clean count'
    Assert-Grep $err 'BOM signatures removed: 3' 'summary: BOM count'
    Assert-Grep $err 'CRLF line endings fixed: 3' 'summary: CRLF count'
    Assert-Grep $err '.php files: 2' 'distribution: php'
    Assert-Grep $err '.css files: 1' 'distribution: css'
    # the distribution must be sorted by extension, ordinally
    $iPhp = $err.IndexOf('.php files:')
    $iCss = $err.IndexOf('.css files:')
    if ($iCss -lt $iPhp -and $iCss -ge 0) { Write-Ok 'distribution is sorted ordinally (.css before .php)' }
    else { Write-Bad 'distribution is sorted ordinally (.css before .php)' "css@$iCss php@$iPhp" }
}

Add-Test 'cli: special filenames' {
    New-Ws
    Write-Fixture 'with space.php' "${BOM}78${CRLF}"
    Write-Fixture "quote'file.php" "${BOM}78${CRLF}"
    Write-Fixture 'dash-start.php' "${BOM}78${CRLF}"
    $rc = Invoke-Tool @('--quiet', 'with space.php', "quote'file.php")
    Assert-Rc $rc 0 'special filenames: exit 0'
    Assert-Bytes 'with space.php' '780a' 'filename with a space is processed'
    Assert-Bytes "quote'file.php" '780a' "filename with a quote is processed"
    $rc2 = Invoke-Tool @('--quiet', '--', 'dash-start.php')
    Assert-Rc $rc2 0 'a path after -- is processed'
    Assert-Bytes 'dash-start.php' '780a' 'dash-start.php cleaned'
}

Add-Test 'cli: JSON escapes' {
    New-Ws
    Write-Fixture 'we"ird.php' "${BOM}78${CRLF}"
    Write-Fixture 'back\slash.php' "${BOM}78${CRLF}"
    $null = Invoke-Tool @('--json', '--check', '.')
    $raw = Get-ToolStdout
    try { $null = $raw | ConvertFrom-Json; Write-Ok 'JSON with a quote and a backslash in filenames parses' }
    catch { Write-Bad 'JSON with a quote and a backslash in filenames parses' $_.Exception.Message }
    Assert-Grep $raw '\"' 'the report contains escaped quotes'
}

Add-Test 'cli: --self-test' {
    New-Ws
    $realOut = [Console]::Out
    $sw = [System.IO.StringWriter]::new()
    $rc = 0
    try {
        [Console]::SetOut($sw)
        $toolPath = $TOOL
        $r = Invoke-Command -ScriptBlock { & $toolPath @('--self-test'); $LASTEXITCODE }
        $rc = if ($null -eq $r) { 0 } else { [int]$r }
    } finally { [Console]::SetOut($realOut) }
    $txt = $sw.ToString()
    Assert-Rc $rc 0 '--self-test: passes on this machine'
    Assert-Grep $txt 'self-test: 10 passed, 0 failed' '--self-test: all ten fixtures green'
    Assert-Grep $txt 't1 php: BOM stripped' '--self-test reports its fixtures'
}

Add-Test 'cli: --completion emits a usable PowerShell completer' {
    New-Ws
    $rc = Invoke-Tool @('--completion')
    Assert-Rc $rc 0 '--completion: exit 0'
    $txt = Get-ToolStdout
    Assert-Grep $txt 'Register-ArgumentCompleter' '--completion emits Register-ArgumentCompleter'
    Assert-Grep $txt '--bom-policy' '--completion offers --bom-policy'
    Assert-Grep $txt '--check' '--completion offers --check'
    # it must be valid PowerShell, not just text that looks like it
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) { Write-Ok '--completion output parses as PowerShell' }
    else { Write-Bad '--completion output parses as PowerShell' $errors[0].Message }
}

#==============================================================================
# 7. Auto-update (against a local file:// "repository")
#==============================================================================
Write-Section 'auto-update'

function New-FakeRepo {
    param([string]$Version, [string]$Dir, [string]$ScriptVersion)
    $null = New-Item -ItemType Directory -Path $Dir -Force
    [System.IO.File]::WriteAllText((Join-Path $Dir 'VERSION'), "$Version`n")
    $src = [System.IO.File]::ReadAllText($TOOL)
    if ($ScriptVersion -cne '') {
        $src = $src.Replace("`$script:VERSION = '3.0.0';", "`$script:VERSION = '$ScriptVersion';")
    }
    [System.IO.File]::WriteAllText((Join-Path $Dir 'clean-bom-senior.ps1'), $src,
        [System.Text.UTF8Encoding]::new($true))
}

Add-Test 'update: --check-update exit codes' {
    New-Ws
    $repo = Join-Path $script:WS 'repo'
    New-FakeRepo -Version '9.9.9' -Dir $repo -ScriptVersion ''
    $env:CLEAN_BOM_UPDATE_URL = "file://$repo"
    try {
        $rc = Invoke-Tool @('--check-update')
        Assert-Rc $rc 11 '--check-update: exit 11 when a newer version exists'
        Assert-Grep (Get-ToolStderr) 'Update available: 3.0.0 -> 9.9.9' '--check-update announces both versions'
    } finally { Remove-Item Env:\CLEAN_BOM_UPDATE_URL -ErrorAction SilentlyContinue }

    New-Ws
    $repo2 = Join-Path $script:WS 'repo2'
    New-FakeRepo -Version '3.0.0' -Dir $repo2 -ScriptVersion ''
    $env:CLEAN_BOM_UPDATE_URL = "file://$repo2"
    try {
        $rc2 = Invoke-Tool @('--check-update')
        Assert-Rc $rc2 0 '--check-update: exit 0 when up to date'
        Assert-Grep (Get-ToolStderr) 'Up to date' '--check-update says so'
    } finally { Remove-Item Env:\CLEAN_BOM_UPDATE_URL -ErrorAction SilentlyContinue }

    New-Ws
    $env:CLEAN_BOM_UPDATE_URL = "file://$(Join-Path $script:WS 'does-not-exist')"
    try {
        $rc3 = Invoke-Tool @('--check-update')
        Assert-Rc $rc3 3 '--check-update: exit 3 when the source is unreachable'
    } finally { Remove-Item Env:\CLEAN_BOM_UPDATE_URL -ErrorAction SilentlyContinue }
}

Add-Test 'update: --update replaces the script and preserves the exec bit' {
    New-Ws
    $repo = Join-Path $script:WS 'repo'
    New-FakeRepo -Version '9.9.9' -Dir $repo -ScriptVersion '9.9.9'
    # install a private copy so the repository's own file is never modified
    $install = Join-Path $script:WS 'install'
    $null = New-Item -ItemType Directory -Path $install -Force
    $installed = Join-Path $install 'clean-bom-senior.ps1'
    [System.IO.File]::Copy($TOOL, $installed, $true)
    if ($IS_UNIX) { & chmod 755 -- $installed }

    $realOut = [Console]::Out; $realErr = [Console]::Error
    $swOut = [System.IO.StringWriter]::new(); $swErr = [System.IO.StringWriter]::new()
    $toolPath = $installed
    [string[]]$toolArgs = @('--update')
    $env:CLEAN_BOM_UPDATE_URL = "file://$repo"
    $rc = 0
    try {
        [Console]::SetOut($swOut); [Console]::SetError($swErr)
        $r = Invoke-Command -ScriptBlock { & $toolPath @toolArgs; $LASTEXITCODE }
        $rc = if ($null -eq $r) { 0 } else { [int]$r }
    } finally {
        [Console]::SetOut($realOut); [Console]::SetError($realErr)
        Remove-Item Env:\CLEAN_BOM_UPDATE_URL -ErrorAction SilentlyContinue
    }
    if ($rc -eq 0) { Write-Ok "--update: exit 0" } else { Write-Bad "--update: exit 0" "rc=$rc`n$($swErr.ToString())" }
    $txt = [System.IO.File]::ReadAllText($installed)
    if ($txt.Contains("`$script:VERSION = '9.9.9';")) { Write-Ok '--update installed the newer version' }
    else { Write-Bad '--update installed the newer version' 'stamp still 3.0.0' }
    if ($IS_UNIX) {
        $mode = (& stat -c '%a' -- $installed | Out-String).Trim()
        if ($mode.Contains('7')) { Write-Ok '--update preserved the exec bit' }
        else { Write-Bad '--update preserved the exec bit' "mode $mode" }
    } else { Write-Ok '--update exec bit: SKIPPED (Windows)' }
    Assert-Grep $swErr.ToString() 'Updated' '--update reports what it did'
}

Add-Test 'update: verification rejects tampered content' {
    New-Ws
    $repo = Join-Path $script:WS 'repo'
    $null = New-Item -ItemType Directory -Path $repo -Force
    [System.IO.File]::WriteAllText((Join-Path $repo 'VERSION'), "9.9.9`n")
    # a payload with the right header but the WRONG version stamp must be refused
    $src = [System.IO.File]::ReadAllText($TOOL)
    [System.IO.File]::WriteAllText((Join-Path $repo 'clean-bom-senior.ps1'), $src,
        [System.Text.UTF8Encoding]::new($true))

    $install = Join-Path $script:WS 'install2'
    $null = New-Item -ItemType Directory -Path $install -Force
    $installed = Join-Path $install 'clean-bom-senior.ps1'
    [System.IO.File]::Copy($TOOL, $installed, $true)
    $before = [System.IO.File]::ReadAllBytes($installed)

    $realOut = [Console]::Out; $realErr = [Console]::Error
    $swOut = [System.IO.StringWriter]::new(); $swErr = [System.IO.StringWriter]::new()
    $toolPath = $installed
    [string[]]$toolArgs = @('--update')
    $env:CLEAN_BOM_UPDATE_URL = "file://$repo"
    $rc = 0
    try {
        [Console]::SetOut($swOut); [Console]::SetError($swErr)
        $r = Invoke-Command -ScriptBlock { & $toolPath @toolArgs; $LASTEXITCODE }
        $rc = if ($null -eq $r) { 0 } else { [int]$r }
    } finally {
        [Console]::SetOut($realOut); [Console]::SetError($realErr)
        Remove-Item Env:\CLEAN_BOM_UPDATE_URL -ErrorAction SilentlyContinue
    }
    Assert-Rc $rc 3 '--update: a version-stamp mismatch exits 3'
    Assert-Grep $swErr.ToString() 'refusing to install' '--update explains the refusal'
    $after = [System.IO.File]::ReadAllBytes($installed)
    if (($before.Length -eq $after.Length) -and
        (-not (Compare-Object $before $after -SyncWindow 0))) {
        Write-Ok '--update: a failed update leaves the script byte-identical'
    } else { Write-Bad '--update: a failed update leaves the script byte-identical' 'the file changed' }
}

#==============================================================================
# 8. Repository consistency
#==============================================================================
Write-Section 'repository consistency'

Add-Test 'repo: versions agree across every implementation' {
    New-Ws
    $psSrc = [System.IO.File]::ReadAllText($TOOL)
    # Single-quoted on purpose. In a PowerShell double-quoted string a backtick
    # before a dollar sign yields a LITERAL dollar, and a regex then reads that
    # dollar as "end of line", so the pattern silently matches nothing. Here the
    # regex source carries an escaped literal dollar instead.
    $psVer = [regex]::Match($psSrc, '(?m)^\$script:VERSION = ''([0-9.]+)'';').Groups[1].Value
    if ($psVer -cne '') { Write-Ok "ps1 declares version $psVer" } else { Write-Bad 'ps1 declares a version' 'stamp not found' }

    $verFile = ([System.IO.File]::ReadAllText((Join-Path $REPO_ROOT 'VERSION'))).Trim()
    if ($verFile -ceq $psVer) { Write-Ok "VERSION file matches ($verFile)" } else { Write-Bad 'VERSION file matches' "[$verFile] != [$psVer]" }

    $pkg = [System.IO.File]::ReadAllText((Join-Path $REPO_ROOT 'package.json')) | ConvertFrom-Json
    if ($pkg.version -ceq $psVer) { Write-Ok "package.json matches ($($pkg.version))" } else { Write-Bad 'package.json matches' $pkg.version }

    if ($HAVE_BASH -and (Test-Path $SH_TOOL)) {
        $shSrc = [System.IO.File]::ReadAllText($SH_TOOL)
        $shVer = [regex]::Match($shSrc, '(?m)^VERSION="([0-9.]+)"').Groups[1].Value
        if ($shVer -ceq $psVer) { Write-Ok "the shell reference matches ($shVer)" } else { Write-Bad 'the shell reference matches' "[$shVer] != [$psVer]" }
    } else { Write-Ok 'shell reference: SKIPPED (no bash or no clean-bom-senior.sh)' }

    $bomJs = Join-Path $REPO_ROOT 'bin/bom.js'
    if (Test-Path $bomJs) {
        $jsSrc = [System.IO.File]::ReadAllText($bomJs)
        $jsVer = [regex]::Match($jsSrc, "(?m)^const VERSION = '([0-9.]+)';").Groups[1].Value
        if ($jsVer -ceq $psVer) { Write-Ok "bin/bom.js matches ($jsVer)" } else { Write-Bad 'bin/bom.js matches' "[$jsVer] != [$psVer]" }
    }
}

Add-Test 'repo: the port is pure ASCII and directly invocable' {
    New-Ws
    # Pure ASCII is load bearing, not stylistic. A UTF-8 BOM in front of
    # `#!/usr/bin/env pwsh` breaks direct invocation on Unix: the kernel reads
    # the first two bytes as the magic, finds EF BB, and falls back to /bin/sh,
    # which fails with "\xEF\xBB\xBF#!/usr/bin/env: No such file or directory".
    # The help text still emits the reference's em dashes and arrows - they are
    # stored as placeholders and restored on output (docs/PS-PORT.md section 5).
    $bytes = [System.IO.File]::ReadAllBytes($TOOL)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    if ($nonAscii.Count -eq 0) { Write-Ok 'clean-bom-senior.ps1 contains no byte above 0x7F' }
    else { Write-Bad 'clean-bom-senior.ps1 contains no byte above 0x7F' "$($nonAscii.Count) non-ASCII byte(s), first at offset $([System.Array]::IndexOf($bytes, $nonAscii[0]))" }
    if ($bytes[0] -ne 0xEF) { Write-Ok 'the file carries no UTF-8 BOM (the shebang stays executable)' }
    else { Write-Bad 'the file carries no UTF-8 BOM (the shebang stays executable)' 'BOM present' }

    # ... and the non-ASCII characters the contract requires still reach stdout
    $null = Invoke-Tool @('--help', 'bom-policy')
    $txt = Get-ToolStdout
    $emdash = [string][char]0x2014
    $arrow = [string][char]0x2192
    Assert-Grep $txt $emdash 'the emitted help contains a real em dash (U+2014)'
    Assert-Grep $txt $arrow 'the emitted help contains a real arrow (U+2192)'
    Assert-NotGrep $txt '__EMDASH__' 'no placeholder leaks into the output'

    if ($IS_UNIX) {
        $mode = (& stat -c '%a' -- $TOOL | Out-String).Trim()
        if ($mode.Contains('7') -or $mode.Contains('5')) { Write-Ok 'the port keeps its exec bit for ./clean-bom-senior.ps1' }
        else { Write-Bad 'the port keeps its exec bit for ./clean-bom-senior.ps1' "mode $mode" }
    } else { Write-Ok 'exec bit: SKIPPED (Windows)' }
}

Add-Test 'repo: the generated help is in sync with the reference' {
    New-Ws
    $gen = Join-Path $REPO_ROOT 'scripts/gen-ps-help.py'
    if (-not (Test-Path $gen)) { Write-Ok 'help generator: SKIPPED (not present)'; return }
    if (-not $HAVE_PYTHON) { Write-Ok 'help generator: SKIPPED (no python3)'; return }
    if (-not (Test-Path $SH_TOOL)) { Write-Ok 'help generator: SKIPPED (no shell reference)'; return }
    $r = & python3 $gen --check 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { Write-Ok 'the help topics match the shell reference' }
    else { Write-Bad 'the help topics match the shell reference' $r.Trim() }
}

Add-Test 'repo: differential sh vs ps1 on shared fixtures' {
    New-Ws
    if (-not $HAVE_PYTHON) { Write-Ok 'differential: SKIPPED (no python3)'; return }
    if (-not (Test-Path $DIFF_PY)) { Write-Ok 'differential: SKIPPED (harness missing)'; return }
    if (-not ($HAVE_BASH -and (Test-Path $SH_TOOL))) { Write-Ok 'differential: SKIPPED (no shell reference)'; return }
    $out = & python3 $DIFF_PY 2>&1 | Out-String
    $code = $LASTEXITCODE
    $tail = ($out -split "`n" | Where-Object { $_ -match 'identical' }) -join ' '
    if ($code -eq 0) { Write-Ok "differential: $($tail.Trim())" }
    else {
        Write-Bad 'differential sh vs ps1' ($out -split "`n" | Where-Object { $_ -match '^(DIFF|       )' } |
            Select-Object -First 12) -join "`n"
    }
}

#==============================================================================
# Runner
#==============================================================================
$ran = 0
foreach ($t in $script:TESTS) {
    if ($FILTER -cne '' -and -not $t.Name.Contains($FILTER)) { continue }
    $ran++
    try {
        & $t.Body
    } catch {
        Write-Bad $t.Name "unhandled exception: $($_.Exception.Message)"
    }
}

if ($script:WS -and -not $env:CLEANBOM_PS_KEEPWS) {
    Remove-Item -LiteralPath $script:WS -Recurse -Force -ErrorAction SilentlyContinue
} elseif ($script:WS) {
    [Console]::Out.Write("workspace kept at: $($script:WS)`n")
}

[Console]::Out.Write("`n----------------------------------------`n")
if ($script:FAIL -eq 0) {
    [Console]::Out.Write("$($color.grn)ALL PASSED: $($script:PASS) assertions$($color.rst) ($ran test groups)`n")
    exit 0
}
[Console]::Out.Write("$($color.red)FAILURES: $($script:PASS) passed, $($script:FAIL) failed$($color.rst)`n")
foreach ($f in $script:FAILED) { [Console]::Out.Write("  - $f`n") }
exit 1
