#Requires -Version 7.6
#Requires -PSEdition Core

<#
.SYNOPSIS
    Differential test for the batch port: clean-bom-senior.bat vs the PowerShell
    port vs the shell reference, byte for byte.

.DESCRIPTION
    tests/differential.ps1 compares the PowerShell port with the shell original.
    This test adds the third implementation and makes the comparison explicit:

        .bat  vs  .ps1     always
        .bat  vs  .sh      when Git Bash is available

    Each implementation runs on its own copy of one fixture set, built from raw
    bytes, and every resulting file is compared byte for byte. A divergence is a
    defect in the batch port: cmd has no byte-oriented I/O, so the whole
    transformation is reconstructed on a hexadecimal rendering, and the failure
    mode of a wrong reconstruction is a plausible-looking file rather than an
    error.

    Known, documented divergences are asserted rather than compared - see
    docs/BAT-PORT.md. The help text and the timestamp format differ deliberately;
    file content does not.

    Isolation: fixture trees live in the system temp directory and every run gets
    its working directory set inside its own tree. Called without arguments the
    tools clean the current directory recursively, so an inherited working
    directory would rewrite the repository.

.PARAMETER KeepFixtures
    Keep the working directory for inspection.

.PARAMETER BashPath
    Path to Git Bash. Detected automatically when omitted.

.EXAMPLE
    pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\bat-differential.ps1

.OUTPUTS
    System.Int32: 0 when every compared file matches, 1 on a divergence, 2 when the
    batch script or the PowerShell port is missing.

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
$batScript  = Join-Path $repoRoot 'clean-bom-senior.bat'
$portScript = Join-Path $repoRoot 'clean-bom-senior.ps1'
$reference  = Join-Path $repoRoot 'clean-bom-senior.sh'

foreach ($required in @($batScript, $portScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "ERROR: not found: $required" -ForegroundColor Red
        exit 2
    }
}

if (-not $BashPath) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Git\bin\bash.exe')) }
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) { $candidates.Add((Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe')) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $BashPath = $candidate; break }
    }
}
$haveBash = ($BashPath -and (Test-Path -LiteralPath $BashPath -PathType Leaf))

$work      = Join-Path ([System.IO.Path]::GetTempPath()) ('clean-bom-batdiff-' + [guid]::NewGuid().ToString('N'))
$sourceDir = Join-Path $work 'fixtures'
$batDir    = Join-Path $work 'bat'
$portDir   = Join-Path $work 'port'
$shellDir  = Join-Path $work 'shell'

$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
function ConvertTo-AsciiBytes([string] $Text) { return , [System.Text.Encoding]::ASCII.GetBytes($Text) }

function Write-Fixture {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[][]] $Chunks
    )
    $path = Join-Path $sourceDir $RelativePath
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $list = [System.Collections.Generic.List[byte]]::new()
    foreach ($chunk in $Chunks) { $list.AddRange([byte[]]$chunk) }
    [System.IO.File]::WriteAllBytes($path, $list.ToArray())
}

function ConvertTo-MsysPath([string] $Path) {
    $full = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $full
}

function Test-SameFile {
    param([string] $Left, [string] $Right)
    if (-not (Test-Path -LiteralPath $Left -PathType Leaf)) { return "missing on the left" }
    if (-not (Test-Path -LiteralPath $Right -PathType Leaf)) { return "missing on the right" }
    $a = [System.IO.File]::ReadAllBytes($Left)
    $b = [System.IO.File]::ReadAllBytes($Right)
    if ($a.Length -ne $b.Length) { return "length $($a.Length) vs $($b.Length)" }
    for ($i = 0; $i -lt $a.Length; $i++) {
        if ($a[$i] -ne $b[$i]) {
            return ("byte $i differs: {0:x2} vs {1:x2}" -f $a[$i], $b[$i])
        }
    }
    return $null
}

$exitCode = 0

try {
    # ------------------------------------------------------------ fixture set
    $null = New-Item -ItemType Directory -Path (Join-Path $sourceDir 'nested\sub') -Force

    Write-Fixture 'bom_crlf.php'     -Chunks @($bom, (ConvertTo-AsciiBytes "<?php`r`necho 1;`r`n"))
    Write-Fixture 'crlf_only.css'    -Chunks @((ConvertTo-AsciiBytes "body {`r`n color: red;`r`n}"))
    Write-Fixture 'lf_clean.js'      -Chunks @((ConvertTo-AsciiBytes "var a = 1;`n"))
    Write-Fixture 'lone_cr.txt'      -Chunks @((ConvertTo-AsciiBytes "a`rb`r"))
    Write-Fixture 'bom_only.php'     -Chunks @($bom)
    Write-Fixture 'mixed.html'       -Chunks @($bom, (ConvertTo-AsciiBytes "a`r`nb`nc`rd`n"))
    Write-Fixture 'no_newline.txt'   -Chunks @((ConvertTo-AsciiBytes "first`r`nsecond"))
    Write-Fixture 'trailing_cr.htm'  -Chunks @($bom, (ConvertTo-AsciiBytes "q`r`nr`r"))
    Write-Fixture 'UPPER.PHP'        -Chunks @($bom, (ConvertTo-AsciiBytes "u`r`n"))
    Write-Fixture 'nested\sub\deep.php' -Chunks @($bom, (ConvertTo-AsciiBytes "z`r`n"))
    # CRLF beyond the 1024-byte detection window: detection looks at the window,
    # normalisation must still cover the whole file. Filler is text, not NULs.
    Write-Fixture 'beyond_window.js' -Chunks @(
        (ConvertTo-AsciiBytes "a`r`n"),
        (ConvertTo-AsciiBytes ('x' * 1100)),
        (ConvertTo-AsciiBytes "b`r`nc`r`n")
    )
    # BOM not at offset 0: neither implementation may remove it, both normalise CRLF.
    Write-Fixture 'bom_midfile.htm'  -Chunks @((ConvertTo-AsciiBytes 'x'), $bom, (ConvertTo-AsciiBytes "a`r`nb`r`n"))
    # A CR pair across the 16-byte line boundary of the hex dump: the case that a
    # naive per-line filter breaks.
    Write-Fixture 'boundary_cr.txt'  -Chunks @((ConvertTo-AsciiBytes ('m' * 14)), (ConvertTo-AsciiBytes "`r`n"), (ConvertTo-AsciiBytes 'tail'))
    # Non-ASCII bytes: the transformation must be exact for all 256 values, so a
    # UTF-8 sequence and a Latin-1 byte are both carried through untouched.
    Write-Fixture 'utf8.php'         -Chunks @($bom, [Text.Encoding]::UTF8.GetBytes("<?php `r`n// "), [byte[]]@(0xE2, 0x9C, 0x93), (ConvertTo-AsciiBytes " ok`r`n"))
    # NUL byte far past any practical probe window: must be skipped, not rewritten.
    Write-Fixture 'nul_far.js'       -Chunks @($bom, (ConvertTo-AsciiBytes ('x' * 9000)), [byte[]]@(0x00), (ConvertTo-AsciiBytes "`r`n"))

    $fixtureNames = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File | ForEach-Object {
            [System.IO.Path]::GetRelativePath($sourceDir, $_.FullName) -replace '\\', '/'
        } | Sort-Object)

    Write-Host "fixtures prepared: $($fixtureNames.Count)"
    foreach ($name in $fixtureNames) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $sourceDir $name))
        Write-Host ("  {0,-26} {1,6} B" -f $name, $bytes.Length)
    }
    Write-Host ''

    foreach ($destination in @($batDir, $portDir, $shellDir)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
        Copy-Item -Path (Join-Path $sourceDir '*') -Destination $destination -Recurse -Force
    }
    $shellScriptCopy = Join-Path $work 'reference.sh'
    Copy-Item -LiteralPath $reference -Destination $shellScriptCopy -Force

    # ------------------------------------------------------------------- run

    $batOutput = & cmd.exe /c "cd /d `"$batDir`" & `"$batScript`" --verbose" 2>&1 | Out-String
    $batExit = $LASTEXITCODE

    $portOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command "Set-Location -LiteralPath '$portDir'; & '$portScript'" 2>&1 | Out-String
    $portExit = $LASTEXITCODE

    $shellExit = $null
    if ($haveBash) {
        $bashWork = ConvertTo-MsysPath -Path $work
        $null = & $BashPath -c "cd '$bashWork/shell' && bash '$bashWork/reference.sh' 2>&1"
        $shellExit = $LASTEXITCODE
    }

    Write-Host 'bat vs ps1 vs sh: one fixture set, three copies'
    Write-Host ''
    Write-Host ("exit codes - bat: {0}   port: {1}   shell: {2}" -f $batExit, $portExit, $(if ($null -eq $shellExit) { 'n/a' } else { $shellExit }))
    Write-Host ''

    # --------------------------------------------------------------- compare

    $padding = 0
    foreach ($name in $fixtureNames) { if ($name.Length -gt $padding) { $padding = $name.Length } }

    $compared = 0
    $identical = 0
    $divergences = [System.Collections.Generic.List[string]]::new()

    # Documented divergence, asserted instead of compared. The reference rewrites a
    # file holding a NUL byte and corrupts it; both the PowerShell port and the
    # batch port refuse and leave it untouched. The comparison against .ps1 still
    # has to pass for this fixture - that is what proves the batch port's own
    # binary detection, since the two must agree down to the byte.
    $expectedAgainstShell = @('nul_far.js')

    foreach ($name in $fixtureNames) {
        $batPath = Join-Path $batDir $name
        $portPath = Join-Path $portDir $name
        $shellPath = Join-Path $shellDir $name

        $vsPort = Test-SameFile -Left $batPath -Right $portPath
        $vsShell = if ($haveBash -and -not ($expectedAgainstShell -contains $name)) {
            Test-SameFile -Left $batPath -Right $shellPath
        }
        else { $null }

        $compared++
        if ($null -eq $vsPort -and ($null -eq $vsShell)) {
            $identical++
            $label = if ($expectedAgainstShell -contains $name) { 'vs ps1 (shell divergence expected)' } else { 'vs ps1 and vs sh' }
            Write-Host ("[SAME] {0}  {1}" -f $name.PadRight($padding), $label) -ForegroundColor Green
            continue
        }

        $details = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $vsPort) { $details.Add("vs ps1: $vsPort") }
        if ($haveBash -and $null -ne $vsShell) { $details.Add("vs sh: $vsShell") }
        $divergences.Add("$($name.PadRight($padding))  " + ($details -join '; '))
        Write-Host ("[DIFF] {0}  {1}" -f $name.PadRight($padding), ($details -join '; ')) -ForegroundColor Red
    }

    # ------------------------------------------------- leftover work files

    $leftovers = @(Get-ChildItem -LiteralPath $batDir -Recurse -File | Where-Object { $_.Name -match '\.bak\.\d+$' })
    # One run claims three work files; the threshold is loose on purpose so a
    # concurrent run on the same host does not produce a false alarm, while
    # leaving the set behind is still caught.
    $tempLeftovers = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^clean-bom-senior\.\d+\.' })

    Write-Host ''
    Write-Host ("identical: $identical / $compared compared")
    Write-Host ("leftover backups in the batch tree: $($leftovers.Count)")
    Write-Host ("leftover work files in temp: $($tempLeftovers.Count)")

    if ($divergences.Count -gt 0) {
        Write-Host ''
        Write-Host 'divergences:' -ForegroundColor Red
        foreach ($item in $divergences) { Write-Host "  $item" -ForegroundColor Red }
        $exitCode = 1
    }

    if ($batExit -ne $portExit) {
        Write-Host ''
        Write-Host ("exit codes differ - bat: {0}, port: {1}" -f $batExit, $portExit) -ForegroundColor Red
        $exitCode = 1
    }
    if ($leftovers.Count -gt 0 -or $tempLeftovers.Count -gt 3) {
        Write-Host ''
        Write-Host ('work files were left behind - backups: {0}, temp files: {1}' -f $leftovers.Count, $tempLeftovers.Count) -ForegroundColor Red
        $exitCode = 1
    }

    if (-not $haveBash) {
        Write-Host ''
        Write-Host 'NOTE: Git Bash was not found - the shell-reference comparison was skipped.' -ForegroundColor Yellow
    }

    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host '--- batch output ---'
        $batOutput | Select-Object -First 25 | Write-Host
    }
    else {
        Write-Host ''
        Write-Host 'batch parity verified: identical bytes against the PowerShell port' -ForegroundColor Green
    }

    if ($KeepFixtures) {
        Write-Host ''
        Write-Host "fixtures kept at: $work"
    }
}
finally {
    if (-not $KeepFixtures -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
