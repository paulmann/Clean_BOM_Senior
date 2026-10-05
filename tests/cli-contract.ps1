#Requires -Version 7.6
#Requires -PSEdition Core

<#
.SYNOPSIS
    CLI contract test for the PowerShell port, and for the shell reference where
    the two must agree.

.DESCRIPTION
    tests/differential.ps1 proves byte parity on the *content* of files. It does
    not cover three things this test pins down, each of them a defect found during
    the audit of 2026-10-05:

      1. Argument parsing of a bare `-`. The reference matches it with its `-*`
         pattern and exits 2; the port used to accept it as a file name, report
         "File not found: -" and exit 0.

      2. Binary detection beyond the first 8192 bytes. The port probed one 8 KB
         block, so a NUL byte further in was missed and the file was rewritten:
         BOM + 9000 text bytes + NUL + CRLF lost 4 bytes. assert-nul-far checks that
         the file comes back byte-identical, from the end of the file as well as
         from the middle.

      3. The shape of paths in the log. The reference walks with `find .`, so it
         prints './name'; the port collected absolute paths and printed those.

    Every assertion runs in a fresh temporary directory. The tool cleans its
    working directory recursively, so a case that inherited the repository as its
    working directory would rewrite the repository.

.PARAMETER KeepFixtures
    Keep the temporary trees for inspection.

.PARAMETER BashPath
    Path to Git Bash. Detected automatically when omitted. When Git Bash cannot be
    found the reference-side assertions are skipped and reported, never silently
    passed.

.EXAMPLE
    pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\cli-contract.ps1

.OUTPUTS
    System.Int32: 0 when every assertion holds, 1 when one fails, 2 when the port
    itself is missing.

.NOTES
    Project : Clean_BOM_Senior
    Author  : Mikhail Deynekin <mid1977@gmail.com>
    Website : https://deynekin.com
#>

[CmdletBinding()]
param(
    [switch] $KeepFixtures,
    [string] $BashPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$portScript = Join-Path $repoRoot 'clean-bom-senior.ps1'
$reference  = Join-Path $repoRoot 'clean-bom-senior.sh'

if (-not (Test-Path -LiteralPath $portScript -PathType Leaf)) {
    Write-Host "ERROR: port not found: $portScript" -ForegroundColor Red
    exit 2
}

if (-not $BashPath) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Git\bin\bash.exe')) }
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $candidates.Add((Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $BashPath = $candidate; break }
    }
}
$haveBash = ($BashPath -and (Test-Path -LiteralPath $BashPath -PathType Leaf))

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('clean-bom-cli-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force

$failures = [System.Collections.Generic.List[string]]::new()
$checked = 0

function Add-Failure([string] $message) {
    $failures.Add($message)
    Write-Host "  [FAIL] $message" -ForegroundColor Red
}

function Add-Pass([string] $message) {
    Write-Host "  [ok]   $message" -ForegroundColor Green
}

function Get-Bom { return , [byte[]]@(0xEF, 0xBB, 0xBF) }
function ConvertTo-AsciiBytes([string] $text) { return , [System.Text.Encoding]::ASCII.GetBytes($text) }

function Test-BytesEqual {
    param([byte[]] $Left, [byte[]] $Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}

function Quote-Bash([string] $value) { return "'" + $value.Replace("'", "'\''") + "'" }

function ConvertTo-MsysPath([string] $path) {
    $full = [System.IO.Path]::GetFullPath($path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $full
}

<#
    Runs the port in a fresh directory through the documented invocation,
    `pwsh -File <script> <args>`.

    The child process is started directly rather than through a nested
    `pwsh -Command` string, because that spelling is measurably wrong for this
    contract: PowerShell rewrites the argument list on the way in (measured:
    `-` arrives as an empty argument) and the child's exit code is replaced
    (measured: exit 2 became 1). Both were observed while writing this test. The
    ProcessStartInfo argument list is passed verbatim - no shell, no quoting
    layer - so what is asserted here is what a CI script would actually get.

    The working directory is set to the sandbox on purpose: called without file
    arguments the tool cleans the current directory, so the target is explicit and
    never inherited.
#>
function Invoke-Port {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $startInfo.WorkingDirectory = $Directory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    foreach ($token in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $portScript)) {
        $startInfo.ArgumentList.Add($token)
    }
    foreach ($token in $Arguments) { $startInfo.ArgumentList.Add($token) }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr) }
}

function Invoke-Reference {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments
    )

    $quoted = ($Arguments | ForEach-Object { Quote-Bash $_ }) -join ' '
    $msys = ConvertTo-MsysPath -path $Directory
    $script = ConvertTo-MsysPath -path $reference
    $output = & $BashPath -c "cd '$msys' && bash '$script' $quoted 2>&1; echo __EXIT__=`$?" | Out-String
    $exit = [int]([regex]::Match($output, '__EXIT__=(\d+)').Groups[1].Value)
    return [pscustomobject]@{ ExitCode = $exit; Output = ($output -replace '__EXIT__=\d+', '') }
}

function Reset-Tree {
    param([Parameter(Mandatory)][string] $Directory)

    if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $Directory -Force
}

# ---------------------------------------------------------------- 1. bare dash

Write-Host 'cli contract: bare dash is an unknown option' -ForegroundColor Cyan

foreach ($case in @(@('-'), @('--dry-run', '-'))) {
    $dir = Join-Path $work 'dash'
    Reset-Tree -Directory $dir
    [System.IO.File]::WriteAllBytes((Join-Path $dir 'dirty.php'), [byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "<?php`r`n")))

    $label = ($case -join ' ')
    $port = Invoke-Port -Directory $dir -Arguments $case
    $checked++
    if ($port.ExitCode -ne 2) {
        Add-Failure "port: '$label' exited $($port.ExitCode), expected 2 (unknown option)"
    }
    elseif ($port.Output -notmatch 'Unknown option: -') {
        Add-Failure "port: '$label' exited 2 but did not report 'Unknown option: -'"
    }
    else {
        Add-Pass "port: '$label' -> exit 2, Unknown option: -"
    }

    if ($haveBash) {
        $shell = Invoke-Reference -Directory $dir -Arguments $case
        $checked++
        if ($shell.ExitCode -ne 2) {
            Add-Failure "reference: '$label' exited $($shell.ExitCode), expected 2"
        }
        else {
            Add-Pass "reference: '$label' -> exit 2 (agrees with the port)"
        }
    }

    # The argument must not be taken as a file, and nothing may be modified.
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir 'dirty.php'))
    $checked++
    if (-not (Test-BytesEqual -Left $bytes -Right ([byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "<?php`r`n"))))) {
        Add-Failure "port: '$label' rewrote dirty.php although it never got to file arguments"
    }
    else {
        Add-Pass "port: '$label' left the tree untouched"
    }
}

# A file whose name starts with a dash still parses after `--`: the fix for `-`
# must not swallow every argument that begins with a hyphen.
$dir = Join-Path $work 'dashname'
Reset-Tree -Directory $dir
[System.IO.File]::WriteAllBytes((Join-Path $dir '-dash.php'), [byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "<?php`r`n")))
$port = Invoke-Port -Directory $dir -Arguments @('--', '-dash.php')
$checked++
if ($port.ExitCode -ne 0) {
    Add-Failure "port: '-- -dash.php' exited $($port.ExitCode), expected 0"
}
else {
    Add-Pass "port: '-- -dash.php' -> exit 0 (dash-prefixed file name still works)"
}

# ------------------------------------------------- 2. NUL byte past the probe

Write-Host ''
Write-Host 'cli contract: NUL byte outside the first 8 KB block' -ForegroundColor Cyan

$text = 'x' * 9000
foreach ($placement in @('middle', 'end')) {
    $dir = Join-Path $work "nul-$placement"
    Reset-Tree -Directory $dir

    $content = [System.Collections.Generic.List[byte]]::new()
    $content.AddRange([byte[]](Get-Bom))
    if ($placement -eq 'middle') {
        $content.AddRange([byte[]](ConvertTo-AsciiBytes $text))
        $content.Add(0x00)
        $content.AddRange([byte[]](ConvertTo-AsciiBytes "`r`n"))
    }
    else {
        $content.AddRange([byte[]](ConvertTo-AsciiBytes 'short'))
        $content.AddRange([byte[]](ConvertTo-AsciiBytes $text))
        $content.Add(0x00)
    }

    $path = Join-Path $dir 'binary.html'
    [System.IO.File]::WriteAllBytes($path, $content.ToArray())
    $before = [System.IO.File]::ReadAllBytes($path)
    # Offset of the NUL byte, computed rather than guessed: BOM 3 bytes, then the
    # filler, which is 'short' plus the 9000 bytes for the end placement.
    $expectedOffset = if ($placement -eq 'middle') { 3 + 9000 } else { 3 + 5 + 9000 }

    # --verbose is required: the binary skip is a WARN, and WARN lines print only
    # in verbose mode - in both implementations.
    $port = Invoke-Port -Directory $dir -Arguments @('--verbose', 'binary.html')
    $after = [System.IO.File]::ReadAllBytes($path)

    $checked++
    if (-not (Test-BytesEqual -Left $before -Right $after)) {
        Add-Failure "port: NUL at $placement was missed - file rewritten from $($before.Length) to $($after.Length) bytes"
    }
    elseif ($port.Output -notmatch "Binary content \(NUL byte\) detected at byte offset $expectedOffset, skipping") {
        Add-Failure "port: NUL at $placement not reported at byte offset $expectedOffset"
    }
    elseif ($port.ExitCode -ne 0) {
        Add-Failure "port: NUL at $placement exited $($port.ExitCode), expected 0 (skip, not error)"
    }
    else {
        Add-Pass "port: NUL at $placement -> skipped, reported with offset, file untouched"
    }

    # The skip must not be booked as an error: exit code 0 above, and the size
    # counter - printed only when errors were counted - must stay at 0.
    $checked++
    if ($port.Output -match 'File size errors: ([1-9]\d*)') {
        Add-Failure "port: NUL at $placement raised the 'File size errors' counter to $($Matches[1])"
    }
    else {
        Add-Pass "port: NUL at $placement did not raise the 'File size errors' counter"
    }
}

# ----------------------------------------------- 3. path shape in the log

Write-Host ''
Write-Host 'cli contract: recursive log paths match the reference shape' -ForegroundColor Cyan

# Two identical trees on purpose: each implementation runs on its own copy, and
# neither sees the other's result. Sharing one tree made this assertion lie once
# already - the port cleaned the fixture and the reference then had nothing to
# report.
$dir = Join-Path $work 'paths'
$dirReference = Join-Path $work 'paths-reference'
foreach ($tree in @($dir, $dirReference)) {
    Reset-Tree -Directory $tree
    $null = New-Item -ItemType Directory -Path (Join-Path $tree 'nested') -Force
    [System.IO.File]::WriteAllBytes((Join-Path $tree 'top.php'), [byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "a`r`n")))
    [System.IO.File]::WriteAllBytes((Join-Path $tree 'nested\deep.php'), [byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "b`r`n")))
}

$port = Invoke-Port -Directory $dir -Arguments @('--verbose')
$checked++
if ($port.Output -match "[A-Za-z]:\\\\") {
    Add-Failure 'port: the recursive log contains an absolute Windows path; the reference prints ./name'
}
elseif ($port.Output -notmatch 'Processing: \./top\.php' -or $port.Output -notmatch 'Processing: \./nested/deep\.php') {
    Add-Failure 'port: the recursive log does not use the reference ./name form'
}
else {
    Add-Pass 'port: recursive log uses ./name for both the top level and a subdirectory'
}

if ($haveBash) {
    $shell = Invoke-Reference -Directory $dirReference -Arguments @('--dry-run')
    $checked++
    if ($shell.Output -notmatch 'Would process: \./top\.php') {
        Add-Failure 'reference: unexpected log shape; the comparison baseline is not what the port matches'
    }
    else {
        Add-Pass 'reference: confirms the ./name form the port reproduces'
    }
}

# ------------------------------------------------------- 4. no leftovers

Write-Host ''
Write-Host 'cli contract: no backup or temp leftovers' -ForegroundColor Cyan

$dir = Join-Path $work 'leftovers'
Reset-Tree -Directory $dir
[System.IO.File]::WriteAllBytes((Join-Path $dir 'a.php'), [byte[]]((Get-Bom) + (ConvertTo-AsciiBytes "a`r`n")))
[System.IO.File]::WriteAllBytes((Join-Path $dir 'b.js'), (ConvertTo-AsciiBytes "b`r`nc`r`n"))
$port = Invoke-Port -Directory $dir -Arguments @()

$checked++
$backups = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Name -match '\.bak\.\d+$' })
if ($backups.Count -gt 0) {
    Add-Failure "port: $($backups.Count) backup file(s) left behind"
}
else {
    Add-Pass 'port: no .bak.<pid> left in the tree'
}

$checked++
$tempLeftovers = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^clean-bom-senior\.ps1\.\d+\.' })
if ($tempLeftovers.Count -gt 0) {
    Add-Failure "port: $($tempLeftovers.Count) temp file(s) left in $([System.IO.Path]::GetTempPath())"
}
else {
    Add-Pass 'port: no temp file left in the system temp directory'
}

# ------------------------------------------------------------------- verdict

Write-Host ''
if (-not $haveBash) {
    Write-Host 'NOTE: Git Bash was not found - the reference-side assertions were skipped.' -ForegroundColor Yellow
}

Write-Host "assertions checked: $checked   failures: $($failures.Count)"

$exitCode = 0
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'CLI contract violations:' -ForegroundColor Red
    foreach ($item in $failures) { Write-Host "  - $item" -ForegroundColor Red }
    $exitCode = 1
}
else {
    Write-Host 'CLI contract holds: argument parsing, binary detection and log paths verified' -ForegroundColor Green
}

if ($KeepFixtures) {
    Write-Host "fixtures kept at: $work"
}
elseif (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
