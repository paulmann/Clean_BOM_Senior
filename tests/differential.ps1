#Requires -Version 7.6
#Requires -PSEdition Core

<#
.SYNOPSIS
    Differential test: PowerShell port vs the shell original, byte for byte.

.DESCRIPTION
    Builds one fixture set from raw bytes, copies it twice, runs each
    implementation on its own copy, and compares the resulting bytes file by
    file. A divergence is a defect in the port: clean-bom-senior.sh is the
    reference for everything except the divergences documented in README.md and
    docs/AGENTS-context.md.

    Fixtures are written with [System.IO.File]::WriteAllBytes, never as text. A
    fixture that claims to hold a bare LF must not silently arrive as CRLF on any
    layer between the test and the file system, and a fixture that claims to be
    empty must really be zero bytes long.

    Isolation: the fixture trees live in the system temp directory, and each
    implementation runs with its working directory set explicitly inside its own
    tree. Called without arguments the tool cleans the current directory
    recursively, so a run that inherited the repository as its working directory
    would rewrite the repository.

.PARAMETER KeepFixtures
    Keep the working directory for inspection instead of deleting it.

.PARAMETER BashPath
    Path to Git Bash. Detected automatically when omitted.

.EXAMPLE
    pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\differential.ps1

.OUTPUTS
    System.Int32: 0 when every compared file matches and both implementations
    agree on the exit code, 1 when a file or an exit code diverged, 2 when a
    prerequisite (port, reference or Git Bash) is missing.

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

$repoRoot        = Split-Path -Parent $PSScriptRoot
$portScript      = Join-Path $repoRoot 'clean-bom-senior.ps1'
$referenceScript = Join-Path $repoRoot 'clean-bom-senior.sh'

if (-not (Test-Path -LiteralPath $portScript -PathType Leaf)) {
    Write-Host "ERROR: port not found: $portScript" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path -LiteralPath $referenceScript -PathType Leaf)) {
    Write-Host "ERROR: shell reference not found: $referenceScript" -ForegroundColor Red
    exit 2
}

# ------------------------------------------------------------------ prerequisites

if (-not $BashPath) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Git\bin\bash.exe')) }
    }
    # git.exe sits in <git-root>\cmd; bash.exe is in <git-root>\bin.
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $BashPath = $candidate; break }
    }
}

if (-not $BashPath -or -not (Test-Path -LiteralPath $BashPath -PathType Leaf)) {
    Write-Host 'ERROR: Git Bash not found. Pass -BashPath <path to bash.exe>.' -ForegroundColor Red
    exit 2
}

# ------------------------------------------------------------------- fixture set

$work      = Join-Path ([System.IO.Path]::GetTempPath()) ('clean-bom-senior-difftest-' + [guid]::NewGuid().ToString('N'))
$sourceDir = Join-Path $work 'fixtures'
$shellDir  = Join-Path $work 'shell'
$portDir   = Join-Path $work 'port'

$bom = [byte[]]@(0xEF, 0xBB, 0xBF)

function ConvertTo-AsciiBytes {
    <#
    .SYNOPSIS
        ASCII bytes for a literal, so nothing re-encodes it on the way to disk.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    return [System.Text.Encoding]::ASCII.GetBytes($Text)
}

function Write-Fixture {
    <#
    .SYNOPSIS
        Writes one fixture from explicit byte chunks.
    #>
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[][]] $Chunks
    )

    $path = Join-Path $sourceDir $RelativePath
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }

    $list = [System.Collections.Generic.List[byte]]::new()
    foreach ($chunk in $Chunks) { $list.AddRange([byte[]]$chunk) }
    [System.IO.File]::WriteAllBytes($path, $list.ToArray())
}

function ConvertTo-MsysPath {
    <#
    .SYNOPSIS
        Windows path as Git Bash sees it (C:\a\b -> /c/a/b).
    #>
    param([Parameter(Mandatory)][string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $full
}

function Test-ByteArrayEqual {
    <#
    .SYNOPSIS
        Byte-for-byte comparison of two arrays; length is part of the answer.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

$exitCode = 0

try {
    $null = New-Item -ItemType Directory -Path (Join-Path $sourceDir 'nested\sub\dir') -Force

    # Detection rules under test, one fixture per rule.
    Write-Fixture -RelativePath 'bom_only.php'        -Chunks @($bom, (ConvertTo-AsciiBytes '<?php echo 1;'))
    Write-Fixture -RelativePath 'bom_crlf.php'        -Chunks @($bom, (ConvertTo-AsciiBytes "<?php`r`necho 1;`r`n"))
    Write-Fixture -RelativePath 'crlf_only.css'       -Chunks @((ConvertTo-AsciiBytes "body {`r`n  color: red;`r`n}"))
    Write-Fixture -RelativePath 'lf_clean.js'         -Chunks @((ConvertTo-AsciiBytes "var a = 1;`n"))
    Write-Fixture -RelativePath 'lone_cr.txt'         -Chunks @((ConvertTo-AsciiBytes "a`rb`r"))
    Write-Fixture -RelativePath 'empty.xml'           -Chunks @([byte[]]@())
    Write-Fixture -RelativePath 'bom_only_empty.htm'  -Chunks @($bom)
    Write-Fixture -RelativePath 'mixed.html'          -Chunks @($bom, (ConvertTo-AsciiBytes "a`r`nb`nc`rd`n"))
    Write-Fixture -RelativePath 'unsupported.md'      -Chunks @($bom, (ConvertTo-AsciiBytes "x`r`ny`r`n"))
    Write-Fixture -RelativePath 'nested\sub\dir\deep.js' -Chunks @($bom, (ConvertTo-AsciiBytes "z`r`n"))
    Write-Fixture -RelativePath 'no_newline.txt'      -Chunks @((ConvertTo-AsciiBytes "first`r`nsecond"))
    Write-Fixture -RelativePath 'trailing_cr.php'     -Chunks @($bom, (ConvertTo-AsciiBytes "q`r`nr`r"))
    Write-Fixture -RelativePath 'UPPER.PHP'           -Chunks @($bom, (ConvertTo-AsciiBytes "u`r`n"))

    # CRLF beyond the 1024-byte detection window: detection looks at the window,
    # normalisation must still cover the whole file in both implementations. The
    # filler is plain text, not a zero-filled array: NUL bytes would turn the
    # fixture into a binary file and test the binary skip instead.
    Write-Fixture -RelativePath 'crlf_beyond_window.js' -Chunks @(
        (ConvertTo-AsciiBytes "a`r`n"),
        (ConvertTo-AsciiBytes ('x' * 1100)),
        (ConvertTo-AsciiBytes "b`r`nc`r`n")
    )
    # BOM not at offset 0: neither implementation may remove it, while both still
    # normalise the CRLF the file contains.
    Write-Fixture -RelativePath 'bom_midfile.htm'     -Chunks @(
        (ConvertTo-AsciiBytes 'x'),
        $bom,
        (ConvertTo-AsciiBytes "a`r`nb`r`n")
    )

    # --no-rn-normalize is a documented divergence: the reference runs sed from
    # Git Bash, where the MSYS text mode strips CR on read and normalises anyway.
    # The flag is applied to the two implementations on separate copies of one
    # binary fixture: the port must leave CRLF intact, the reference is expected
    # to remove it, so only the port is asserted here.
    Write-Fixture -RelativePath 'keep_crlf.php'   -Chunks @($bom, (ConvertTo-AsciiBytes "a`r`nb`r`n"))

    # A file holding a NUL byte is binary. The reference rewrites it and corrupts
    # it; the port must skip it and leave the bytes untouched.
    Write-Fixture -RelativePath 'binary_nul.js'   -Chunks @($bom, (ConvertTo-AsciiBytes 'x'), [byte[]]@(0x00), (ConvertTo-AsciiBytes "`r`n"))

    $fixtureNames = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File | ForEach-Object {
            [System.IO.Path]::GetRelativePath($sourceDir, $_.FullName) -replace '\\', '/'
        } | Sort-Object)

    Write-Host "fixtures prepared: $($fixtureNames.Count)"
    foreach ($name in $fixtureNames) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $sourceDir $name))
        Write-Host ("  {0,-26} {1,5} B" -f $name, $bytes.Length)
    }
    Write-Host ''

    # ------------------------------------------------------------- run both copies

    foreach ($destination in @($shellDir, $portDir)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
        Copy-Item -Path (Join-Path $sourceDir '*') -Destination $destination -Recurse -Force
    }

    $shellScriptCopy = Join-Path $work 'reference.sh'
    Copy-Item -LiteralPath $referenceScript -Destination $shellScriptCopy -Force

    $bashWork = ConvertTo-MsysPath -Path $work
    $shellOutput = & $BashPath -c "cd '$bashWork/shell' && bash '$bashWork/reference.sh' 2>&1"
    $shellExit = $LASTEXITCODE

    # Working directory is set explicitly: without it the port would treat the
    # caller's directory as the target tree and clean it. The whole tree is
    # cleaned in one recursive pass, exactly as the reference does, so the two
    # outputs are comparable file by file.
    $portOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command "Set-Location -LiteralPath '$portDir'; & '$portScript'" 2>&1
    $portExit = $LASTEXITCODE

    # --- --no-rn-normalize divergence, port only ---------------------------

    $flagChecks = [System.Collections.Generic.List[string]]::new()
    $flagDir = Join-Path $work 'flagonly'
    $null = New-Item -ItemType Directory -Path $flagDir -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'keep_crlf.php') -Destination (Join-Path $flagDir 'keep_crlf.php') -Force

    # Explicit relative file argument: this is what regression-tests the process
    # working directory fix, because Test-Path and [System.IO] resolve a relative
    # path differently.
    $flagOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command "Set-Location -LiteralPath '$flagDir'; & '$portScript' --no-rn-normalize keep_crlf.php" 2>&1
    $flagExit = $LASTEXITCODE
    $flagBytes = [System.IO.File]::ReadAllBytes((Join-Path $flagDir 'keep_crlf.php'))
    $flagHex = ($flagBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($flagExit -ne 0) {
        $flagChecks.Add("--no-rn-normalize: exit code $flagExit, expected 0 (relative file argument was not resolved)")
    }
    if ($flagHex -ne '610d0a620d0a') {
        $flagChecks.Add("--no-rn-normalize: file became [$flagHex], expected [610d0a620d0a] (CRLF must survive)")
    }

    # --- other documented divergences, port behaviour asserted -------------

    # Divergence 5: third-party and generated trees are pruned by the port and
    # walked by the reference. Measured: the reference rewrites vendor/,
    # node_modules/ and .git/; the port must leave their bytes untouched.
    $probeSource = Join-Path $work 'probesrc'
    foreach ($p in @('probe\vendor\v.php', 'probe\node_modules\n.js', 'probe\.git\g.js')) {
        $full = Join-Path $probeSource $p
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
        [System.IO.File]::WriteAllBytes($full, [byte[]]($bom + (ConvertTo-AsciiBytes "x`r`n")))
    }
    # Divergence 1: a dirty file whose modification time must survive the port's
    # rewrite (the reference re-stamps it through `touch -r` on a fresh backup).
    $mtimeProbe = Join-Path $probeSource 'probe\dirty.css'
    [System.IO.File]::WriteAllBytes($mtimeProbe, [byte[]]($bom + (ConvertTo-AsciiBytes "body {`r`n}`r`n")))
    $mtimeBefore = (Get-Item -LiteralPath $mtimeProbe).LastWriteTimeUtc

    $probeShellDir = Join-Path $work 'probe-shell'
    $probePortDir = Join-Path $work 'probe-port'
    foreach ($destination in @($probeShellDir, $probePortDir)) {
        $null = New-Item -ItemType Directory -Path $destination -Force
        Copy-Item -Path (Join-Path $probeSource '*') -Destination $destination -Recurse -Force
    }
    # Copy-Item keeps mtime, but the comparison below must be able to see a
    # one-second change, so give the run something to move.
    Start-Sleep -Milliseconds 1100

    & $BashPath -c "cd '$bashWork/probe-shell' && bash '$bashWork/reference.sh' > /dev/null 2>&1" | Out-Null
    $null = & pwsh -NoLogo -NoProfile -NonInteractive -Command "Set-Location -LiteralPath '$probePortDir'; & '$portScript'" 2>&1

    foreach ($relative in @('probe\vendor\v.php', 'probe\node_modules\n.js', 'probe\.git\g.js')) {
        $sourceBytes = [System.IO.File]::ReadAllBytes((Join-Path $probeSource $relative))
        $portBytes = [System.IO.File]::ReadAllBytes((Join-Path $probePortDir $relative))
        if (-not (Test-ByteArrayEqual -Left $portBytes -Right $sourceBytes)) {
            $flagChecks.Add("pruned tree was modified by the port: $relative")
        }
    }

    $mtimeAfter = (Get-Item -LiteralPath (Join-Path $probePortDir 'probe\dirty.css')).LastWriteTimeUtc
    if ($mtimeAfter -ne $mtimeBefore) {
        $flagChecks.Add("modification time not preserved by the port: $mtimeBefore -> $mtimeAfter")
    }

    # Divergence 7: the usage line names the file the user actually ran.
    $helpText = (& pwsh -NoLogo -NoProfile -NonInteractive -File $portScript --help 2>&1 | Out-String)
    if ($helpText -notmatch 'clean-bom-senior\.ps1') {
        $flagChecks.Add('help text does not name clean-bom-senior.ps1')
    }

    # --------------------------------------------------------------------- compare

    Write-Host 'differential test: PowerShell port vs shell original'
    Write-Host ''
    Write-Host ("shell exit: {0}   port exit: {1}" -f $shellExit, $portExit)
    Write-Host ''

    $identical = 0
    $checked = 0
    $diverged = [System.Collections.Generic.List[string]]::new()

    $padding = 0
    foreach ($name in $fixtureNames) { if ($name.Length -gt $padding) { $padding = $name.Length } }

    # Known divergence, asserted instead of compared: the reference rewrites a
    # binary file that carries a supported extension, the port refuses to touch
    # it. See AGENTS.md section 6.
    $expectedDivergent = @('binary_nul.js')

    foreach ($name in $fixtureNames) {
        $shellPath = Join-Path $shellDir $name
        $portPath = Join-Path $portDir $name
        $sourcePath = Join-Path $sourceDir $name

        # A zero-byte result is legitimate (a BOM-only file becomes empty), so
        # presence is tested explicitly instead of inferred from content.
        $shellBytes = if (Test-Path -LiteralPath $shellPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($shellPath) } else { $null }
        $portBytes = if (Test-Path -LiteralPath $portPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($portPath) } else { $null }

        if ($expectedDivergent -contains $name) {
            $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
            $untouched = ($null -ne $portBytes) -and (Test-ByteArrayEqual -Left $portBytes -Right $sourceBytes)
            $referenceRewrote = ($null -ne $shellBytes) -and (-not (Test-ByteArrayEqual -Left $shellBytes -Right $sourceBytes))
            if ($untouched -and $referenceRewrote) {
                Write-Host ("[EXPECTED] {0}  port skipped the binary; the reference rewrote it" -f $name.PadRight($padding)) -ForegroundColor Cyan
            }
            else {
                $flagChecks.Add("$name : expected divergence not reproduced (port untouched=$untouched, reference rewrote=$referenceRewrote)")
                Write-Host ("[EXPECTED-FAIL] {0}  port untouched=$untouched, reference rewrote=$referenceRewrote" -f $name.PadRight($padding)) -ForegroundColor Red
            }
            continue
        }

        if ($null -eq $shellBytes) {
            Write-Host ("[SKIP] {0}  not produced by the reference run" -f $name.PadRight($padding)) -ForegroundColor Yellow
            continue
        }

        $same = ($null -ne $portBytes) -and (Test-ByteArrayEqual -Left $shellBytes -Right $portBytes)

        $checked++
        if ($same) {
            $identical++
            Write-Host ("[SAME] {0}  {1} bytes" -f $name.PadRight($padding), $shellBytes.Length) -ForegroundColor Green
            continue
        }

        $portLength = if ($null -eq $portBytes) { 'missing' } else { [string]$portBytes.Length }
        $details = "shell=$($shellBytes.Length)B port=${portLength}B"
        if ($null -ne $portBytes -and $portBytes.Length -le 64 -and $shellBytes.Length -le 64) {
            $shellHex = ($shellBytes | ForEach-Object { $_.ToString('x2') }) -join ''
            $portHex = ($portBytes | ForEach-Object { $_.ToString('x2') }) -join ''
            $details += "  shell=[$shellHex] port=[$portHex]"
        }
        $diverged.Add("$($name.PadRight($padding))  $details")
        Write-Host ("[DIFF] {0}  {1}" -f $name.PadRight($padding), $details) -ForegroundColor Red
    }

    # ---------------------------------------------------- leftover backup files

    $shellBackups = @(Get-ChildItem -LiteralPath $shellDir -Recurse -File | Where-Object { $_.Name -match '\.bak\.\d+$' })
    $portBackups = @(Get-ChildItem -LiteralPath $portDir -Recurse -File | Where-Object { $_.Name -match '\.bak\.\d+$' })

    # ------------------------------------------------------------------- verdict

    Write-Host ''
    Write-Host ("identical: $identical / $checked compared")
    Write-Host ("leftover backups - shell: $($shellBackups.Count)  port: $($portBackups.Count)")

    if ($flagChecks.Count -gt 0) {
        Write-Host ''
        Write-Host 'documented behaviour not reproduced:' -ForegroundColor Red
        foreach ($item in $flagChecks) { Write-Host "  $item" -ForegroundColor Red }
        $exitCode = 1
    }

    if ($diverged.Count -gt 0) {
        Write-Host ''
        Write-Host 'divergences:'
        foreach ($item in $diverged) { Write-Host "  $item" }
        $exitCode = 1
    }

    if ($shellExit -ne $portExit) {
        Write-Host ''
        Write-Host ("exit codes differ - reference: {0}, port: {1}" -f $shellExit, $portExit) -ForegroundColor Red
        $exitCode = 1
    }

    if ($checked -eq 0) {
        Write-Host ''
        Write-Host 'no file was compared - the fixture set did not survive the run' -ForegroundColor Red
        $exitCode = 1
    }

    if ($shellBackups.Count -gt 0 -or $portBackups.Count -gt 0) {
        Write-Host ''
        Write-Host 'backup files were left behind by a run' -ForegroundColor Red
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host '--- reference output ---'
        $shellOutput | Select-Object -Last 20 | Write-Host
        Write-Host '--- port output ---'
        $portOutput | Select-Object -Last 20 | Write-Host
    }
    else {
        Write-Host ''
        Write-Host 'parity verified: identical bytes and identical exit codes' -ForegroundColor Green
    }

    if ($KeepFixtures) {
        Write-Host ''
        Write-Host "fixtures kept at: $work"
        Write-Host 'two fixtures are expected to be absent from the comparison:'
        Write-Host '  empty.xml           - the reference find uses -size +0c and never selects it'
        Write-Host '  bom_only_empty.htm  - it disappears from the listing once it becomes empty'
    }
}
finally {
    if ($KeepFixtures) {
        Write-Host "working directory kept: $work"
    }
    elseif (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
