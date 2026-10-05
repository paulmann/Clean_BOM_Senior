#Requires -Version 7.6
#Requires -PSEdition Core

<#
.SYNOPSIS
    UTF-8 BOM and CRLF cleaner - PowerShell 7.6 port of clean-bom-senior.sh.

.DESCRIPTION
    Detects and removes invisible UTF-8 Byte Order Marks (BOM) and normalises
    Windows CRLF line endings in PHP, CSS, JS, TXT, XML, HTM and HTML files.

    This is a behavioural port of clean-bom-senior.sh v2.07.0
    (https://github.com/paulmann/Clean_BOM_Senior). The command-line contract,
    the detection rules, the statistics and the exit codes match the original
    so the script can replace it in a pipeline. Three deliberate divergences are
    documented in the NOTES section of -Help and in docs/AGENTS-context.md:

      * Last modified time is actually preserved (the shell original intends this
        but re-stamps the copy time through `touch -r` on a fresh backup);
      * `--no-rn-normalize` really leaves CRLF intact (MSYS sed strips CR on read,
        so the original silently normalises anyway);
      * file ACLs and ownership are preserved instead of POSIX uid/gid/mode.

.PARAMETER Help
    POSIX-style flags are parsed from the argument list, matching the original:
    -h/--help, -V/--version, -v/--verbose, -n/--dry-run, --no-bom-clear,
    --no-rn-normalize, `--` to end option parsing. PowerShell-style aliases
    (-Help, -Version, -Verbose, -DryRun, -NoBomClear, -NoRnNormalize) are also
    accepted. There is no param() block on purpose: it would swallow the
    POSIX spellings and break drop-in compatibility.

.NOTES
    Project : Clean_BOM_Senior
    Author  : Mikhail Deynekin <mid1977@gmail.com>
    Website : https://deynekin.com
    Version : 2.07.0
    Since   : 2026-10-01
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants

$script:Version = '2.07.0'
$script:ScriptName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
$script:SupportedExtensions = @('php', 'css', 'js', 'txt', 'xml', 'htm', 'html')
$script:MaxFileSizeBytes = [long]100 * 1024 * 1024
$script:TempDirectory = [System.IO.Path]::GetTempPath()

# Runtime flags (mirroring the shell globals).
$script:Verbose = $false
$script:DryRun = $false
$script:ShowHelp = $false
$script:ShowVersion = $false
$script:NoBomClear = $false
$script:NoRnNormalize = $false

# Counters.
$script:ProcessedCount = 0
$script:ErrorCount = 0
$script:BomRemovedCount = 0
$script:CrlfFixedCount = 0
$script:SkippedCount = 0
$script:StartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$script:FileTypeCounts = [ordered]@{}
$script:ErrorTypes = [ordered]@{ access = 0; size = 0; processing = 0; other = 0 }
$script:ProcessedFiles = [System.Collections.Generic.List[string]]::new()

# ANSI colour codes, used only when stderr is a terminal - exactly as the shell
# script gates on `[ -t 2 ]`.
$script:ColorRed = "`e[0;31m"
$script:ColorGreen = "`e[0;32m"
$script:ColorYellow = "`e[1;33m"
$script:ColorBlue = "`e[0;34m"
$script:ColorMagenta = "`e[0;35m"
$script:ColorCyan = "`e[0;36m"
$script:ColorReset = "`e[0m"

# ------------------------------------------------------------------- logging

function Test-ErrorOutputIsConsole {
    <#
    .SYNOPSIS
        True when stderr goes to a terminal, so colour is safe to emit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        return -not [Console]::IsErrorRedirected
    }
    catch {
        return $false
    }
}

function Write-LogLine {
    <#
    .SYNOPSIS
        Writes one line to stderr, which is where the original sends everything
        except help and version output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    [Console]::Error.WriteLine($Text)
}

function Get-Timestamp {
    <#
    .SYNOPSIS
        Timestamp in the original's format: yyyy-MM-dd HH:mm:ss.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

function Write-Log {
    <#
    .SYNOPSIS
        Logs with the original's `[timestamp LEVEL]` prefix.

    .DESCRIPTION
        Levels match the shell script: INFO and ERROR always print, while WARN,
        SUCCESS and PROCESSING print only in verbose mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'PROCESSING')][string] $Level,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message
    )

    if ($Level -in @('WARN', 'SUCCESS', 'PROCESSING') -and -not $script:Verbose) { return }

    $colour = switch ($Level) {
        'INFO' { $script:ColorBlue }
        'WARN' { $script:ColorYellow }
        'ERROR' { $script:ColorRed }
        'SUCCESS' { $script:ColorGreen }
        'PROCESSING' { $script:ColorCyan }
    }

    if (Test-ErrorOutputIsConsole) {
        Write-LogLine ("$colour[$((Get-Timestamp)) $Level]$($script:ColorReset) $Message")
    }
    else {
        Write-LogLine ("[$((Get-Timestamp)) $Level] $Message")
    }

    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
}

# ----------------------------------------------------------- help and version

function Show-Help {
    <#
    .SYNOPSIS
        Prints the help text. Byte-for-byte the original contract, with the
        PowerShell divergences appended so a reader is never misled.
    #>
    [CmdletBinding()]
    param()

    $help = @'
UTF-8 BOM and Windows CRLF Cleaner - Professional Source Code Sanitizer
USAGE
    clean-bom-senior.ps1 [OPTIONS] [FILE...]
DESCRIPTION
    Safely detects and removes invisible UTF-8 Byte Order Marks (BOM) and
    Windows CRLF line endings from source code and text files. Designed for
    PHP developers working in multi-editor, cross-platform environments.
OPTIONS
    -h, --help              Show this help message and exit
    -v, --verbose           Enable detailed output and processing logs
    -n, --dry-run           Preview which files would be processed (no modifications)
    -V, --version           Display script version information
    --no-bom-clear          Disable removal of UTF-8 BOM
    --no-rn-normalize       Disable conversion of CRLF (\r\n) to LF (\n)
SUPPORTED FILE TYPES
    Extensions: php, css, js, txt, xml, htm, html
    Max file size: 100 MB per file
EXAMPLES
    clean-bom-senior.ps1                             Process all files recursively
    clean-bom-senior.ps1 --no-bom-clear              Skip BOM removal
    clean-bom-senior.ps1 --no-rn-normalize           Skip CRLF normalization
    clean-bom-senior.ps1 --dry-run                   Preview mode (no file changes)
    clean-bom-senior.ps1 file1.php file2.js          Process specific files only
FILE PRESERVATION
    • Original file ownership (user/group) is preserved
    • File permissions (mode) remain unchanged
    • Timestamps are maintained for unmodified files
    • Atomic operations ensure data integrity
EXIT CODES
    0  Success - all files processed without errors
    1  Partial success - some files had processing errors
    2  Invalid command line arguments
    3  Missing dependencies or insufficient permissions
NOTES
    • Files are processed atomically with backup and rollback support
    • Only files containing BOM or CRLF are actually modified
    • Suitable for CI/CD integration and pre-commit hooks
    • Works with any user privileges (preserves original ownership)
POWERSHELL PORT NOTES (divergences from the shell original)
    • Last modified time is preserved for real. The shell original re-stamps the
      copy time because `touch -r` references a freshly created backup.
    • --no-rn-normalize really disables normalisation. Inside MSYS/Git Bash the
      bundled sed strips CR on read, so the original normalises anyway.
    • ACLs, owner and file attributes are preserved instead of POSIX uid/gid/mode,
      which do not exist on Windows.
    • On Windows set the ReadOnly attribute (or deny write in the ACL) to make a
      file protected; the port then reports the same access error as the original.
For more information, visit: https://github.com/paulmann/Clean_BOM_Senior
'@

    # Written straight to the console stream on purpose. `Write-Output` inside a
    # function that also returns an exit code merges both into one array, and the
    # caller then discards the text; [Console]::Out keeps stdout clean and the
    # return value numeric.
    $writer = [System.Console]::Out
    $writer.WriteLine($help)
}

function Show-Version {
    <#
    .SYNOPSIS
        Prints version and author information to stdout.
    #>
    [CmdletBinding()]
    param()

    $writer = [System.Console]::Out
    $writer.WriteLine("$($script:ScriptName) version $($script:Version)")
    $writer.WriteLine('Author: Mikhail Deynekin <mid1977@gmail.com>')
    $writer.WriteLine('Website: https://deynekin.com')
}

function Test-Dependencies {
    <#
    .SYNOPSIS
        Mirrors the original's environment check.

    .DESCRIPTION
        The shell version needs find/sed/od/grep/stat/mv/cp/touch/chown/chmod.
        This port needs no external tools, so only the writable temp directory is
        still checked - that is the condition that can actually fail here.

    .OUTPUTS
        System.Int32: 0 when usable, 3 when the temp directory is not writable.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    try {
        if (-not (Test-Path -LiteralPath $script:TempDirectory -PathType Container)) {
            Write-Log -Level ERROR -Message "No write access to temp directory: $($script:TempDirectory)"
            return 3
        }

        $probe = Join-Path $script:TempDirectory ("$($script:ScriptName).$($script:ScriptPid).probe")
        [System.IO.File]::WriteAllBytes($probe, [byte[]]@(0))
        [System.IO.File]::Delete($probe)
    }
    catch {
        Write-Log -Level ERROR -Message "No write access to temp directory: $($script:TempDirectory)"
        return 3
    }

    return 0
}

function Invoke-ArgumentParsing {
    <#
    .SYNOPSIS
        Parses the original's POSIX-style flags, plus PowerShell aliases.

    .DESCRIPTION
        Behaviour copied from the shell parser: flags are consumed one by one;
        `--` ends option parsing; the first non-option argument captures the whole
        remaining list as file arguments; an unknown `-...` option is a hard error
        with exit code 2.

        Two PowerShell traps are handled explicitly, both confirmed by probe:
          * flag matching uses the case-sensitive operators (-cin/-ceq) because
            -eq is case-insensitive and would make `-v` match `-V`;
          * the parser uses if/elseif rather than switch, because `continue` inside
            a switch block continues the switch, not the enclosing loop, so every
            argument would be processed twice.

    .OUTPUTS
        System.Collections.Generic.List[string]: file arguments, empty when the
        script must run in recursive mode.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments)

    $files = [System.Collections.Generic.List[string]]::new()
    $index = 0
    $handled = $false

    while ($index -lt $Arguments.Count) {
        $argument = $Arguments[$index]
        $handled = $false

        if ($argument -cin @('-h', '--help', '-Help')) {
            $script:ShowHelp = $true
            $handled = $true
        }
        elseif ($argument -cin @('-V', '--version', '-Version')) {
            $script:ShowVersion = $true
            $handled = $true
        }
        elseif ($argument -cin @('-v', '--verbose', '-Verbose')) {
            $script:Verbose = $true
            $handled = $true
        }
        elseif ($argument -cin @('-n', '--dry-run', '-DryRun')) {
            $script:DryRun = $true
            # The shell script turns verbose on together with dry-run.
            $script:Verbose = $true
            $handled = $true
        }
        elseif ($argument -cin @('--no-bom-clear', '-NoBomClear')) {
            $script:NoBomClear = $true
            $handled = $true
        }
        elseif ($argument -cin @('--no-rn-normalize', '-NoRnNormalize')) {
            $script:NoRnNormalize = $true
            $handled = $true
        }
        elseif ($argument -ceq '--') {
            $index++
            while ($index -lt $Arguments.Count) {
                $files.Add($Arguments[$index])
                $index++
            }
            # Comma prefix: PowerShell enumerates an IEnumerable on output, so a
            # List with zero or one element would arrive as $null or a string and
            # the caller's .Count would fail under StrictMode.
            return , $files
        }
        elseif ($argument.Length -ge 1 -and $argument[0] -ceq '-') {
            # A bare `-` is NOT a file name here: the shell original matches it
            # with the `-*` pattern and exits 2 with "Unknown option: -".
            # Measured before the fix: `-` and `--dry-run -` were both accepted
            # and reported as "File not found: -" with exit 0, so a script that
            # probes the CLI could not tell the two implementations apart.
            # `-ceq` on the first character keeps the test case-sensitive, so a
            # file argument that merely starts with '-' still parses normally.
            Write-Log -Level ERROR -Message "Unknown option: $argument"
            exit 2
        }
        else {
            # First positional argument: the original appends every remaining
            # argument to the file list and stops parsing options.
            while ($index -lt $Arguments.Count) {
                $files.Add($Arguments[$index])
                $index++
            }
            return , $files
        }

        if ($handled) { $index++ }
    }

    return , $files
}

# ------------------------------------------------------------- file analysis

function Get-FileExtensionLower {
    <#
    .SYNOPSIS
        File extension in lower case, without the dot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    $extension = [System.IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrEmpty($extension)) { return '' }
    return $extension.TrimStart('.').ToLowerInvariant()
}

function Get-FileCategory {
    <#
    .SYNOPSIS
        Maps a file to a supported category, or 'other'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    $extension = Get-FileExtensionLower -Path $Path
    if ($script:SupportedExtensions -contains $extension) { return $extension }
    return 'other'
}

function Format-DisplayPath {
    <#
    .SYNOPSIS
        Path in the form the reference prints it: relative to the current
        directory, prefixed with './' and using forward slashes.

    .DESCRIPTION
        The shell original runs `find .`, so every recursive path it logs is
        './name'. The port collects absolute paths internally and used to log
        them verbatim, which broke the "same output" part of the contract for
        anyone diffing the two logs. Explicit file arguments are deliberately not
        passed through here: the reference echoes those exactly as typed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $relative = [System.IO.Path]::GetRelativePath((Get-Location).Path, $Path)
        if ($relative.StartsWith('..')) { return $Path }
        return './' + ($relative -replace '\\', '/')
    }
    catch {
        return $Path
    }
}

function Get-FileIssues {
    <#
    .SYNOPSIS
        Returns 'BOM', 'CRLF', 'BOM+CRLF' or '' for a file.

    .DESCRIPTION
        Detection matches the original exactly:
          * BOM is bytes EF BB BF at offsets 0..2;
          * CRLF presence is bytes 0D 0A anywhere in the first 1024 bytes;
          * a flag that is disabled excludes its own check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    $issues = ''
    $header = Read-FileHeader -Path $Path -Count 1024
    if ($null -eq $header) { return '' }

    if (-not $script:NoBomClear) {
        if ($header.Length -ge 3 -and $header[0] -eq 0xEF -and $header[1] -eq 0xBB -and $header[2] -eq 0xBF) {
            $issues = 'BOM'
        }
    }

    if (-not $script:NoRnNormalize) {
        $hasCrlf = $false
        for ($i = 0; $i -lt $header.Length - 1; $i++) {
            if ($header[$i] -eq 0x0D -and $header[$i + 1] -eq 0x0A) { $hasCrlf = $true; break }
        }
        if ($hasCrlf) {
            $issues = if ($issues -eq '') { 'CRLF' } else { "$issues+CRLF" }
        }
    }

    return $issues
}

function Read-FileHeader {
    <#
    .SYNOPSIS
        Reads at most the first N bytes of a file, or $null when unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $Count = 1024
    )

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        return $null
    }

    try {
        $length = [int][Math]::Min([long]$Count, $stream.Length)
        if ($length -le 0) { return , [byte[]]@() }
        $buffer = [byte[]]::new($length)
        $read = $stream.Read($buffer, 0, $length)
        if ($read -eq $length) { return , $buffer }
        $slice = [byte[]]::new($read)
        [Array]::Copy($buffer, $slice, $read)
        return , $slice
    }
    finally {
        $stream.Dispose()
    }
}

function Test-UnsupportedForContents {
    <#
    .SYNOPSIS
        True when the file holds NUL bytes, meaning it is not text.

    .DESCRIPTION
        Not present in the shell original, which happily rewrites binaries that
        happen to carry a supported extension. Rewriting one silently corrupts
        it, so this port refuses and reports instead. The file is counted as
        skipped, never as an error, to keep exit codes compatible.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    # One traversal answers "is this binary?" and "where is the first NUL?";
    # Find-NulByteOffset owns the scan, this keeps the boolean contract.
    return $null -ne (Find-NulByteOffset -Path $Path)
}

function Find-NulByteOffset {
    <#
    .SYNOPSIS
        Offset of the first NUL byte, or $null when the file holds none.

    .DESCRIPTION
        Scans the entire file - not just its first block. A NUL byte past the
        first 8192 bytes used to be missed and the file was then rewritten as if it
        were text, which is exactly the corruption this exists to prevent.
        Measured before the fix: BOM + 9000 text bytes + NUL + CRLF lost 4 bytes
        (the BOM and both CRLF pairs) and came back as valid-looking text.

        The file size limit is checked before this runs, so the buffer is the only
        cost; 64 KB blocks keep it flat regardless of file size.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        return $null
    }

    try {
        $buffer = [byte[]]::new(65536)
        $offset = [long]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($i = 0; $i -lt $read; $i++) {
                if ($buffer[$i] -eq 0x00) { return $offset + $i }
            }
            $offset += $read
        }
        return $null
    }
    finally {
        $stream.Dispose()
    }
}

function Get-FileSecurityState {
    <#
    .SYNOPSIS
        Captures ACL and attributes so they can be restored after a rewrite.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $state = [ordered]@{ Acl = $null; AclFailed = $false; Attributes = $null; CreationTimeUtc = $null; CreationTime = $null }

    try {
        $state['Acl'] = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        $state['AclFailed'] = $true
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $state['Attributes'] = $item.Attributes
        # Creation time only: LastWriteTime is deliberately set to the original
        # value after a rewrite, so it must not be overwritten here.
        $state['CreationTimeUtc'] = $item.CreationTimeUtc
        $state['CreationTime'] = $item.CreationTime
    }
    catch {
        return $null
    }

    return [pscustomobject]$state
}

function Restore-FileSecurityState {
    <#
    .SYNOPSIS
        Restores ACL, attributes and creation time after a rewrite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $State
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($null -ne $State.Attributes) {
            $item.Attributes = $State.Attributes
        }
        if ($null -ne $State.CreationTimeUtc) {
            $item.CreationTimeUtc = $State.CreationTimeUtc
        }
    }
    catch {
        Write-Log -Level WARN -Message "Could not restore attributes for: $Path"
    }

    if (-not $State.AclFailed -and $null -ne $State.Acl) {
        try {
            Set-Acl -LiteralPath $Path -AclObject $State.Acl -ErrorAction Stop
        }
        catch {
            Write-Log -Level WARN -Message "Could not restore permissions for: $Path"
        }
    }
}

function Test-FileWritable {
    <#
    .SYNOPSIS
        True when the file can be replaced, matching the original's `[ -w ]`.

    .DESCRIPTION
        The shell test asks about the file itself, not its directory. On Windows
        the closest equivalent is the ReadOnly attribute plus a real open for
        write, which is what this does.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { return $false }
    }
    catch {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Convert-FileBytes {
    <#
    .SYNOPSIS
        Applies BOM removal and CRLF normalisation to a byte array.

    .DESCRIPTION
        This replaces the original's `sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//'`
        and was calibrated against GNU sed 4.9 rather than assumed:

          * `s/\r$//` drops a CR when it is the last byte of a line, which means
            before an LF or at end of file. A lone CR followed by any other byte
            survives, exactly as in the original;
          * `1s/^\xef\xbb\xbf//` removes the BOM only at offset 0, and only in the
            first line;
          * sed does not terminate the last line: a file without a trailing
            newline keeps it that way.

        Measured cases this reproduces: 'a\rb\r' -> 'a\rb'; 'a\rb\n' -> 'a\rb\n';
        BOM only -> empty file; 'BOM a\r' -> 'a'.

    .PARAMETER Bytes
        Raw file content.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)

    # Every return uses the comma prefix. PowerShell enumerates an array on output,
    # so an empty result would arrive as $null and the caller's WriteAllBytes would
    # throw - which is exactly how a BOM-only file used to be left uncleaned.
    if ($Bytes.Length -eq 0) { return , [byte[]]@() }

    $start = 0
    if (-not $script:NoBomClear -and $Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $start = 3
    }

    if ($start -ge $Bytes.Length) { return , [byte[]]@() }

    $result = [System.Collections.Generic.List[byte]]::new($Bytes.Length - $start)

    for ($i = $start; $i -lt $Bytes.Length; $i++) {
        $current = $Bytes[$i]

        if (-not $script:NoRnNormalize -and $current -eq 0x0D) {
            $atEndOfFile = ($i -eq $Bytes.Length - 1)
            $beforeLf = (-not $atEndOfFile) -and ($Bytes[$i + 1] -eq 0x0A)
            # $ in sed matches before a newline and at end of buffer, so both a
            # CRLF pair and a trailing CR disappear; any other CR stays.
            if ($atEndOfFile -or $beforeLf) { continue }
        }

        $result.Add($current)
    }

    return , $result.ToArray()
}

# ------------------------------------------------------------ file operation

function Invoke-CleanFile {
    <#
    .SYNOPSIS
        Cleans one file in place, preserving identity.

    .DESCRIPTION
        Mirrors `clean_file()` from the original: accessibility checks, the
        skip-if-clean short circuit, attribute capture, a temporary rewrite and
        an atomic replace with rollback.

    .OUTPUTS
        System.Int32: 0 on success or skip; non-zero when the caller must set the
        final exit code to 1.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string] $Path,
        # False for a file named on the command line: the reference echoes those
        # verbatim, while everything found by its `find .` comes back as './name'.
        [bool] $DisplayRelative = $true
    )

    # One display form for every log line about this file, built from the same
    # rule the reference's `find .` output follows.
    $displayPath = if ($DisplayRelative) { Format-DisplayPath -Path $Path } else { $Path }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log -Level ERROR -Message "Cannot read file: $displayPath"
        $script:ErrorTypes['access']++
        return 3
    }

    try {
        $null = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite).Dispose()
    }
    catch {
        Write-Log -Level ERROR -Message "Cannot read file: $displayPath"
        $script:ErrorTypes['access']++
        return 3
    }

    if (-not (Test-FileWritable -Path $Path)) {
        Write-Log -Level ERROR -Message "Cannot write to file: $displayPath"
        $script:ErrorTypes['access']++
        return 3
    }

    $length = (Get-Item -LiteralPath $Path -Force).Length

    if ($length -gt $script:MaxFileSizeBytes) {
        Write-Log -Level WARN -Message "File exceeds the size limit, skipping: $displayPath"
        $script:SkippedCount++
        return 0
    }

    $issues = Get-FileIssues -Path $Path
    if ($issues -eq '') {
        Write-Log -Level PROCESSING -Message "No issues detected, skipping: $displayPath"
        $script:SkippedCount++
        return 0
    }

    if (Test-UnsupportedForContents -Path $Path) {
        # The line is followed by the byte offset of the offending NUL, because a
        # file can be text for its first megabytes and binary far past the point
        # where a reader would look. Without the offset the report is not
        # actionable on a large file.
        $nulOffset = Find-NulByteOffset -Path $Path
        $where = if ($null -eq $nulOffset) { '' } else { " at byte offset $nulOffset" }
        Write-Log -Level WARN -Message "Binary content (NUL byte) detected$where, skipping: $displayPath"
        $script:SkippedCount++
        return 0
    }

    $category = Get-FileCategory -Path $Path
    Write-Log -Level PROCESSING -Message "Processing: $displayPath (Issues: $issues, Type: $category)"

    $securityState = Get-FileSecurityState -Path $Path
    if ($null -eq $securityState) {
        Write-Log -Level ERROR -Message "Cannot get file attributes: $displayPath"
        $script:ErrorTypes['processing']++
        return 4
    }

    $lastWriteTimeUtc = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc
    # .NET resolves a relative path against the *process* working directory, while
    # Get-Item and Test-Path resolve it against the PowerShell provider location.
    # With a relative file argument those two can disagree, so the path is
    # anchored once, here, before any [System.IO] call uses it.
    $fullPath = [System.IO.Path]::GetFullPath($Path)

    $backupPath = "$fullPath.bak.$($script:ScriptPid)"
    $tempPath = Join-Path $script:TempDirectory "$($script:ScriptName).$($script:ScriptPid).$([Guid]::NewGuid().ToString('N'))"

    try {
        [System.IO.File]::Copy($fullPath, $backupPath, $true)
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to create backup: $displayPath"
        $script:ErrorTypes['processing']++
        return 4
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($backupPath)
        $cleaned = Convert-FileBytes -Bytes $bytes
        [System.IO.File]::WriteAllBytes($tempPath, $cleaned)
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to process file content: $displayPath"
        $script:ErrorTypes['processing']++
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        return 5
    }

    try {
        # Atomic replacement: the destination keeps the temp file's data but the
        # original's identity is restored immediately afterwards.
        [System.IO.File]::Move($tempPath, $fullPath, $true)
    }
    catch {
        try {
            if (Test-Path -LiteralPath $backupPath) { [System.IO.File]::Copy($backupPath, $fullPath, $true) }
        }
        catch {
            Write-Log -Level WARN -Message "Rollback failed for: $displayPath"
        }
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Write-Log -Level ERROR -Message "Failed to replace original file: $displayPath"
        $script:ErrorTypes['processing']++
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        return 1
    }

    Restore-FileSecurityState -Path $Path -State $securityState

    try {
        (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = $lastWriteTimeUtc
    }
    catch {
        Write-Log -Level WARN -Message "Could not restore the modification time for: $displayPath"
    }

    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue

    $script:ProcessedCount++
    if (-not $script:FileTypeCounts.Contains($category)) { $script:FileTypeCounts[$category] = 0 }
    $script:FileTypeCounts[$category]++
    $script:ProcessedFiles.Add($displayPath)

    if ($issues -like '*BOM*') { $script:BomRemovedCount++ }
    if ($issues -like '*CRLF*') { $script:CrlfFixedCount++ }

    Write-Log -Level SUCCESS -Message "Successfully processed: $displayPath (Fixed: $issues)"
    return 0
}

function Invoke-DryRunFile {
    <#
    .SYNOPSIS
        Reports what would happen to a file without touching it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string] $Path,
        # False for a file named on the command line; see Invoke-CleanFile.
        [bool] $DisplayRelative = $true
    )

    $displayPath = if ($DisplayRelative) { Format-DisplayPath -Path $Path } else { $Path }

    $issues = Get-FileIssues -Path $Path
    if ($issues -ne '') {
        $category = Get-FileCategory -Path $Path
        $script:ProcessedCount++
        if (-not $script:FileTypeCounts.Contains($category)) { $script:FileTypeCounts[$category] = 0 }
        $script:FileTypeCounts[$category]++
        $script:ProcessedFiles.Add($displayPath)
        Write-LogLine "Would process: $displayPath (Issues: $issues, Type: $category)"
        return 0
    }

    $script:SkippedCount++
    Write-Log -Level PROCESSING -Message "Would skip (clean): $displayPath"
    return 0
}

function Get-TargetFileList {
    <#
    .SYNOPSIS
        Recursively lists candidate files, matching the original's find call.

    .DESCRIPTION
        The shell version runs
          find . -type f -size +0c -size -100Mc \( -iname '*.php' -o ... \) -print0
        from the current directory, so it is case-insensitive, skips empty files
        and skips anything at or above 100 MB.

        Directories that can only hold third-party or generated content are
        pruned. The shell original walks into them (and into .git), which on a
        real repository means rewriting vendor sources; that is a defect, not a
        feature, and it is the only place where this port deliberately narrows
        the file set.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $prunedNames = @('.git', '.svn', '.hg', 'node_modules', 'vendor', 'bower_components',
        '__pycache__', '.venv', 'venv', '.idea', '.vscode', '.cache', 'obj',
        'bin', 'dist', 'build', 'publish', 'coverage', 'target', '.next')

    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push((Get-Location).Path)
    $files = [System.Collections.Generic.List[string]]::new()

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()

        $children = $null
        try {
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            if ($child.PSIsContainer) {
                if ($prunedNames -contains $child.Name) { continue }
                $pending.Push($child.FullName)
                continue
            }

            if ($child.Length -le 0) { continue }
            if ($child.Length -ge $script:MaxFileSizeBytes) { continue }

            $extension = Get-FileExtensionLower -Path $child.Name
            if ($script:SupportedExtensions -notcontains $extension) { continue }

            $files.Add($child.FullName)
        }
    }

    # Comma-prefixed output and an explicit size check keep this a collection even
    # with zero or one element: without it PowerShell unwraps a single-element
    # array to a string and the caller's .Count fails under StrictMode.
    $sorted = @($files | Sort-Object)
    return , $sorted
}

# ------------------------------------------------------------------- reports

function Format-DisplaySize {
    <#
    .SYNOPSIS
        Human-readable size for one message in the summary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][long] $Bytes)

    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Show-Greeting {
    <#
    .SYNOPSIS
        Banner and configuration block, printed to stderr like the original.
    #>
    [CmdletBinding()]
    param()

    $colour = Test-ErrorOutputIsConsole

    if ($colour) {
        Write-LogLine "`n$($script:ColorMagenta)=== UTF-8 BOM & CRLF Cleaner v$($script:Version) ===$($script:ColorReset)"
        Write-LogLine "$($script:ColorBlue)Author:$($script:ColorReset) Mikhail Deynekin (mid1977@gmail.com)"
        Write-LogLine "$($script:ColorBlue)Website:$($script:ColorReset) https://deynekin.com"
        Write-LogLine "$($script:ColorBlue)Started:$($script:ColorReset) $(Get-Timestamp)"
        Write-LogLine "`n$($script:ColorCyan)--- Configuration ---$($script:ColorReset)"
    }
    else {
        Write-LogLine "`n=== UTF-8 BOM & CRLF Cleaner v$($script:Version) ==="
        Write-LogLine 'Author: Mikhail Deynekin (mid1977@gmail.com)'
        Write-LogLine 'Website: https://deynekin.com'
        Write-LogLine "Started: $(Get-Timestamp)"
        Write-LogLine "`n--- Configuration ---"
    }

    Write-LogLine "Verbose mode: $(if ($script:Verbose) { 'ENABLED' } else { 'DISABLED' })"
    Write-LogLine "Dry-run mode: $(if ($script:DryRun) { 'ENABLED' } else { 'DISABLED' })"
    Write-LogLine "BOM removal: $(if ($script:NoBomClear) { 'DISABLED' } else { 'ENABLED' })"
    Write-LogLine "CRLF normalization: $(if ($script:NoRnNormalize) { 'DISABLED' } else { 'ENABLED' })"
    Write-LogLine "Supported extensions: $($script:SupportedExtensions -join ' ')"
    Write-LogLine "Maximum file size: $([int]($script:MaxFileSizeBytes / 1024 / 1024)) MB"

    if ($colour) {
        Write-LogLine "`n$($script:ColorCyan)--- Operation Mode ---$($script:ColorReset)"
    }
    else {
        Write-LogLine "`n--- Operation Mode ---"
    }

    if ($script:DryRun) {
        Write-LogLine '• Scanning files for UTF-8 BOM and CRLF issues'
        Write-LogLine '• Showing which files need cleaning'
        if ($colour) {
            Write-LogLine "• $($script:ColorYellow)NO FILES WILL BE MODIFIED$($script:ColorReset) (preview mode)"
        }
        else {
            Write-LogLine '• NO FILES WILL BE MODIFIED (preview mode)'
        }
    }
    else {
        Write-LogLine '• Scanning files for UTF-8 BOM and CRLF issues'
        if (-not $script:NoBomClear) { Write-LogLine '• Removing invisible UTF-8 BOM signatures' }
        if (-not $script:NoRnNormalize) { Write-LogLine '• Converting Windows CRLF to Unix LF' }
        Write-LogLine '• Preserving file ownership, permissions, and timestamps'
        Write-LogLine '• Creating backup copies during processing'
    }

    if ($colour) {
        Write-LogLine "`n$($script:ColorGreen)Starting file processing...$($script:ColorReset)"
    }
    else {
        Write-LogLine "`nStarting file processing..."
    }
}

function Show-Statistics {
    <#
    .SYNOPSIS
        The processing summary, formatted like the original.
    #>
    [CmdletBinding()]
    param()

    $colour = Test-ErrorOutputIsConsole
    $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:StartTime

    if ($colour) {
        Write-LogLine "`n$($script:ColorMagenta)=== PROCESSING SUMMARY ===$($script:ColorReset)"
    }
    else {
        Write-LogLine "`n=== PROCESSING SUMMARY ==="
    }

    Write-LogLine "Execution time: $elapsed seconds"
    Write-LogLine "Files processed: $($script:ProcessedCount)"
    Write-LogLine "Files skipped (clean): $($script:SkippedCount)"
    Write-LogLine "Errors encountered: $($script:ErrorCount)"

    if ($script:ProcessedCount -gt 0) {
        if ($colour) { Write-LogLine "`n$($script:ColorCyan)--- Issues Fixed ---$($script:ColorReset)" }
        else { Write-LogLine "`n--- Issues Fixed ---" }

        Write-LogLine "BOM signatures removed: $($script:BomRemovedCount)"
        Write-LogLine "CRLF line endings fixed: $($script:CrlfFixedCount)"

        if ($colour) { Write-LogLine "`n$($script:ColorCyan)--- File Type Distribution ---$($script:ColorReset)" }
        else { Write-LogLine "`n--- File Type Distribution ---" }

        foreach ($extension in $script:SupportedExtensions) {
            if ($script:FileTypeCounts.Contains($extension) -and $script:FileTypeCounts[$extension] -gt 0) {
                Write-LogLine ".${extension} files: $($script:FileTypeCounts[$extension])"
            }
        }
        if ($script:FileTypeCounts.Contains('other') -and $script:FileTypeCounts['other'] -gt 0) {
            Write-LogLine "Other files: $($script:FileTypeCounts['other'])"
        }
    }

    if ($script:ErrorCount -gt 0) {
        if ($colour) { Write-LogLine "`n$($script:ColorRed)--- Error Breakdown ---$($script:ColorReset)" }
        else { Write-LogLine "`n--- Error Breakdown ---" }

        Write-LogLine "Access errors: $($script:ErrorTypes['access'])"
        Write-LogLine "File size errors: $($script:ErrorTypes['size'])"
        # The size counter is treated differently from the reference on purpose.
        # There it is initialised, printed and never incremented: `size` is allowed
        # to the associative array only at line 104 and read at line 538 of
        # clean-bom-senior.sh, and no code path raises it - an over-sized file is
        # skipped by `find -size -100Mc` and counted as skipped, not as an error.
        # The port keeps the line for output parity; the counter still reads 0.
        Write-LogLine "Processing errors: $($script:ErrorTypes['processing'])"
        Write-LogLine "Other errors: $($script:ErrorTypes['other'])"
    }

    if ($script:DryRun -and $script:ProcessedCount -gt 0) {
        if ($colour) { Write-LogLine "`n$($script:ColorYellow)--- Files That Would Be Processed ---$($script:ColorReset)" }
        else { Write-LogLine "`n--- Files That Would Be Processed ---" }

        foreach ($file in $script:ProcessedFiles) { Write-LogLine $file }
    }

    if ($colour) {
        Write-LogLine "`n$($script:ColorGreen)Processing completed at: $(Get-Timestamp)$($script:ColorReset)"
    }
    else {
        Write-LogLine "`nProcessing completed at: $(Get-Timestamp)"
    }
}

# ---------------------------------------------------------------------- main

function Invoke-Main {
    <#
    .SYNOPSIS
        Entry point, mirroring `main()` from the original.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments)

    $exitCode = 0
    $script:StartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $dependencyCode = Test-Dependencies
    if ($dependencyCode -ne 0) { return $dependencyCode }

    $fileArguments = Invoke-ArgumentParsing -Arguments $Arguments

    if ($script:ShowHelp) {
        Show-Help
        return 0
    }
    if ($script:ShowVersion) {
        Show-Version
        return 0
    }

    Show-Greeting

    if ($fileArguments.Count -gt 0) {
        Write-Log -Level INFO -Message "Specific file mode: Processing $($fileArguments.Count) file(s)"

        foreach ($file in $fileArguments) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                Write-Log -Level ERROR -Message "File not found: $file"
                $script:ErrorTypes['access']++
                continue
            }

            if ($script:DryRun) {
                $null = Invoke-DryRunFile -Path $file -DisplayRelative $false
            }
            elseif ((Invoke-CleanFile -Path $file -DisplayRelative $false) -ne 0) {
                $exitCode = 1
            }
        }
    }
    else {
        Write-Log -Level INFO -Message "Recursive mode: Scanning for files with extensions: $($script:SupportedExtensions -join ' ')"
        $targets = Get-TargetFileList

        if ($targets.Count -eq 0) {
            Write-Log -Level INFO -Message 'No files found with supported extensions for processing'
        }

        foreach ($file in $targets) {
            if ($script:DryRun) {
                $null = Invoke-DryRunFile -Path $file
            }
            elseif ((Invoke-CleanFile -Path $file) -ne 0) {
                $exitCode = 1
            }
        }
    }

    Show-Statistics
    return $exitCode
}

# System.IO and the process working directory

# The argument list is resolved against the *process* working directory, not the
# PowerShell provider location. `Set-Location` alone is not enough: [System.IO] would
# resolve a relative file argument against the directory the host started in and
# report "Cannot read file" for a file that exists. Measured: with the location set
# to a sandbox and the process directory left at the caller's, an explicit relative
# argument failed while `Get-Item -LiteralPath` succeeded. Aligning the process
# directory with the location removes the mixed state; when the host sits elsewhere
# on purpose, the location is left alone.
try {
    $providerLocation = (Get-Location -ErrorAction Stop).Path
    if ($providerLocation -and [System.IO.Directory]::Exists($providerLocation) -and
        ([System.IO.Path]::GetFullPath($providerLocation) -ne [System.IO.Path]::GetFullPath([System.IO.Directory]::GetCurrentDirectory()))) {
        [System.IO.Directory]::SetCurrentDirectory($providerLocation)
    }
}
catch {
    # A non-filesystem provider location is not an error worth failing over.
}

# `exit (Invoke-Main ...)` would lose the help and version text: a function that
# writes to stdout AND returns a number yields an object array, and casting that
# to an exit code discards the strings. Capture first, exit second.
$script:FinalExitCode = Invoke-Main -Arguments $args
exit $script:FinalExitCode
