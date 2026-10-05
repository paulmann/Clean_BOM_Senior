@echo off
rem ===========================================================================
rem  clean-bom-senior.bat - UTF-8 BOM and CRLF cleaner for Windows cmd.exe
rem ===========================================================================
rem  File:       clean-bom-senior.bat
rem  Version:    2.07.0
rem  Author:     Mikhail Deynekin <mid1977@gmail.com>
rem  Website:    https://deynekin.com
rem  Repository: https://github.com/paulmann/Clean_BOM_Senior
rem  License:    MIT
rem
rem  The batch counterpart of clean-bom-senior.sh (POSIX shell, the reference)
rem  and clean-bom-senior.ps1 (PowerShell 7.6 port): same flags, same detection
rem  window, same report, same exit codes.
rem
rem  WHY certutil
rem    cmd.exe has no byte-oriented I/O. `set`, `set /p`, `for /f`, `echo` and
rem    redirection all work on text, and the command interpreter rewrites line
rem    endings on the way through. BOM removal and CRLF normalisation are byte
rem    operations, so this script performs them on a hexadecimal rendering:
rem
rem      certutil -encodehex -f <file> <hex> 4   -> "ef bb bf 3c ...", 16 per line
rem      certutil -decodehex      <hex> <file> 4 <- the same format, no header
rem
rem    Both directions were verified byte for byte, including a short last line.
rem    The filter that works on that hex text is documented in docs/BAT-PORT.md,
rem    together with the measurements it was calibrated against.
rem
rem  DELIBERATE DIVERGENCES from the PowerShell port - full rationale in
rem  docs/BAT-PORT.md:
rem    1. Help text is ASCII only. A batch file cannot emit the reference's UTF-8
rem       bullets reliably, because that depends on the console code page. File
rem       *content* is unaffected: it never travels through the code page.
rem    2. The modification time is restored through PowerShell (pwsh, else
rem       powershell.exe) when either is available. When neither is, the time is
rem       not restored and the greeting says so.
rem    3. A path containing an exclamation mark cannot be handled: command
rem       extensions expand it inside the delayed-expansion blocks this script
rem       needs. The PowerShell port has no such limit.
rem    4. The transformation costs roughly a second per 100 KB, because it is a
rem       batch loop. This script is for ordinary source trees, not multi-MB files.
rem
rem  Exit Codes (identical to the reference and to the PowerShell port):
rem    0 - Success, all files processed without errors
rem    1 - Some files processed with errors (partial success)
rem    2 - Invalid command line arguments
rem    3 - Missing dependencies or insufficient permissions
rem ===========================================================================

setlocal EnableExtensions EnableDelayedExpansion

rem --- configuration (mirrors the reference constants) -----------------------
set "VERSION=2.07.0"
set "SCRIPT_NAME=%~nx0"
set "SUPPORTED_EXTENSIONS=php css js txt xml htm html"
set "MAX_FILE_SIZE=104857600"
set "MAX_FILE_SIZE_MB=100"

rem --- runtime flags ---------------------------------------------------------
set "VERBOSE=0"
set "DRY_RUN=0"
set "NO_BOM_CLEAR=0"
set "NO_RN_NORMALIZE=0"

rem --- counters --------------------------------------------------------------
set "PROCESSED_COUNT=0"
set "ERROR_COUNT=0"
set "BOM_REMOVED_COUNT=0"
set "CRLF_FIXED_COUNT=0"
set "SKIPPED_COUNT=0"
set "ERR_ACCESS=0"
set "ERR_SIZE=0"
set "ERR_PROCESSING=0"
set "ERR_OTHER=0"
set "CNT_PHP=0"
set "CNT_CSS=0"
set "CNT_JS=0"
set "CNT_TXT=0"
set "CNT_XML=0"
set "CNT_HTM=0"
set "CNT_HTML=0"
set "CNT_OTHER=0"
set "EXITCODE=0"
set "START_EPOCH=0"
set "ELAPSED=0"
set "PSEXE="

rem A unique suffix per run, so two concurrent runs never share a work file and a
rem backup never overwrites another run's backup. The reference uses its PID for
rem the backup name; cmd cannot read its own PID without starting a process, so
rem three draws from the 16-bit generator are used instead.
set "RUNID=%RANDOM%%RANDOM%%RANDOM%"

set "WORKDIR=%TEMP%"
if not defined WORKDIR set "WORKDIR=."
set "LISTFILE=%WORKDIR%\clean-bom-senior.%RUNID%.list"
set "APPLIST=%WORKDIR%\clean-bom-senior.%RUNID%.args"
set "TOOLPREFIX=clean-bom-senior.%RUNID%."

rem --------------------------------------------------------------------- setup

rem A working directory that cannot be written to is exit 3, exactly as the
rem reference reports an unusable TMPDIR.
> "%LISTFILE%" echo. 2>nul
if not exist "%LISTFILE%" goto :err_temp
del "%LISTFILE%" >nul 2>&1

rem PowerShell is used for exactly two things cmd cannot do: read and write a
rem locale-independent file timestamp, and measure the elapsed time.
where pwsh.exe >nul 2>&1 && set "PSEXE=pwsh.exe"
if not defined PSEXE where powershell.exe >nul 2>&1 && set "PSEXE=powershell.exe"

where certutil.exe >nul 2>&1
if errorlevel 1 goto :err_tool
where findstr.exe >nul 2>&1
if errorlevel 1 goto :err_tool

if defined PSEXE for /f "usebackq delims=" %%T in (`%PSEXE% -NoProfile -NonInteractive -Command "[int](New-TimeSpan -Start (Get-Date '1970-01-01') -End (Get-Date)).TotalSeconds" 2^>nul`) do set "START_EPOCH=%%T"

rem ------------------------------------------------------------- argument parse

set "HAVEFILES=0"
set "SHOWHELP=0"
set "SHOWVERSION=0"

:parse
if "%~1"=="" goto :parsed
if "%~1"=="-h"         ( set "SHOWHELP=1" & shift & goto :parse )
if "%~1"=="--help"     ( set "SHOWHELP=1" & shift & goto :parse )
if "%~1"=="-V"         ( set "SHOWVERSION=1" & shift & goto :parse )
if "%~1"=="--version"  ( set "SHOWVERSION=1" & shift & goto :parse )
if "%~1"=="-v"         ( set "VERBOSE=1" & shift & goto :parse )
if "%~1"=="--verbose"  ( set "VERBOSE=1" & shift & goto :parse )
if "%~1"=="-n"         ( set "DRY_RUN=1" & set "VERBOSE=1" & shift & goto :parse )
if "%~1"=="--dry-run"  ( set "DRY_RUN=1" & set "VERBOSE=1" & shift & goto :parse )
if "%~1"=="--no-bom-clear"    ( set "NO_BOM_CLEAR=1" & shift & goto :parse )
if "%~1"=="--no-rn-normalize" ( set "NO_RN_NORMALIZE=1" & shift & goto :parse )
if "%~1"=="--" ( shift & goto :collect_all )
rem Any other token starting with '-' is an unknown option, exactly like the
rem reference's case pattern `-*`. A single '-' is included: measured, the
rem reference answers it with "Unknown option: -" and exit 2, and the PowerShell
rem port was fixed to agree.
call :Now
if "%~1"=="-" (
    >&2 echo [%NOW% ERROR] Unknown option: -
    exit /b 2
)
if not "%~1"=="" if "%~1:~0,1%"=="-" (
    >&2 echo [%NOW% ERROR] Unknown option: %~1
    exit /b 2
)
goto :collect_all

rem The reference appends every remaining argument to the file list and stops
rem parsing options at the first positional argument.
:collect_all
if "%~1"=="" goto :parsed
set "HAVEFILES=1"
>> "%APPLIST%" echo "%~1"
shift
goto :collect_all

:parsed
if "%SHOWHELP%"=="1" (
    call :ShowHelp
    exit /b 0
)
if "%SHOWVERSION%"=="1" (
    call :ShowVersion
    exit /b 0
)

call :ShowGreeting

rem --------------------------------------------------------------- file lists

if "%HAVEFILES%"=="1" goto :mode_files

call :Log INFO "Recursive mode: Scanning for files with extensions: %SUPPORTED_EXTENSIONS%"
call :BuildList
goto :run_list

:mode_files
set "ARG_COUNT=0"
if exist "%APPLIST%" for /f "usebackq tokens=* delims=" %%A in ("%APPLIST%") do set /a ARG_COUNT+=1
call :Log INFO "Specific file mode: Processing %ARG_COUNT% file(s)"
copy /b /y "%APPLIST%" "%LISTFILE%" >nul 2>&1

:run_list
set "TOTAL=0"
if exist "%LISTFILE%" for /f "usebackq delims=" %%C in ("%LISTFILE%") do set /a TOTAL+=1
if "%TOTAL%"=="0" goto :no_files
goto :run_files

:no_files
call :Log INFO "No files found with supported extensions for processing"

:run_files
if not exist "%LISTFILE%" goto :summary
for /f "usebackq tokens=* delims=" %%F in ("%LISTFILE%") do (
    set "ITEM=%%F"
    set "ITEM=!ITEM:~1,-1!"
    call :HandleFile "!ITEM!" %HAVEFILES%
)
goto :summary

rem ------------------------------------------------------------------- summary

:summary
call :ShowStatistics
del "%LISTFILE%" >nul 2>&1
del "%APPLIST%" >nul 2>&1
del "%WORKDIR%\%TOOLPREFIX%*" >nul 2>&1
exit /b %EXITCODE%

rem ===========================================================================
rem  Per-file pipeline
rem ===========================================================================

:HandleFile
rem %1 = path, %2 = 1 when the user named it on the command line (then the
rem reference echoes it verbatim instead of in its './name' find form).
set "FILE=%~1"
set "FROMARGS=%~2"
set "DISPLAY=%FILE%"
if not "%FROMARGS%"=="1" call :ToReferenceForm DISPLAY "%FILE%"

if not exist "%FILE%" goto :file_missing

for %%A in ("%FILE%") do set "FATTRS=%%~aA"
rem %%~aA is a fixed 10-character attribute string. Measured on this host:
rem   plain file   --a--------
rem   +r +h +s     -rahs------
rem So ReadOnly is the character at index 1 ('r' or '-'); index 2 is Archive.
rem Testing "index 1 is not empty" would call every ordinary file read-only,
rem which is exactly what an earlier revision of this line did.
if "!FATTRS:~1,1!"=="r" (
    call :Log ERROR "Cannot write to file: %DISPLAY%"
    set /a ERR_ACCESS+=1
    set "EXITCODE=1"
    exit /b 0
)

for %%A in ("%FILE%") do set /a FSIZE=%%~zA
if %FSIZE% GTR %MAX_FILE_SIZE% (
    call :Log WARN "File exceeds the size limit, skipping: %DISPLAY%"
    set /a SKIPPED_COUNT+=1
    exit /b 0
)

call :DetectIssues "%FILE%"
if "%HAS_BOM%"=="0" if "%HAS_CRLF%"=="0" (
    call :Log PROCESSING "No issues detected, skipping: %DISPLAY%"
    set /a SKIPPED_COUNT+=1
    exit /b 0
)

call :IssuesText
call :Categorize "%FILE%"
call :Log PROCESSING "Processing: %DISPLAY% (Issues: %ISSUES%, Type: %CATEGORY%)"

if "%DRY_RUN%"=="1" (
    set /a PROCESSED_COUNT+=1
    call :CountType "%CATEGORY%"
    call :EchoWouldProcess
    exit /b 0
)

call :FindNulOffset "%FILE%"
rem The test and the counter are deliberately NOT inside an if-block. Measured:
rem `if not "%NUL_OFFSET%"=="" ( set /a SKIPPED_COUNT+=1 ... )` kills the run with
rem exit 255 and the message "* was unexpected at this time". cmd expands %NUL_OFFSET%
rem to a number before parsing the block, so `set /a ... +=1` is read as `set /a
rem 5+=1`, where `*` is not a known operator. `call` keeps the arithmetic out of
rem the block; an if-block here is a defect, not a style choice.
call :NulFound
if /i "%IS_BINARY%"=="Y" (
    call :LogBinarySkipped
    exit /b 0
)

call :Transform "%FILE%"
if not "%TRANSFORM_OK%"=="1" (
    call :Log ERROR "Failed to process file content: %DISPLAY%"
    set /a ERR_PROCESSING+=1
    set "EXITCODE=1"
    call :DiscardWork
    exit /b 0
)

rem Backup next to the file, exactly like the reference's <file>.bak.<pid>.
set "BACKUP=%FILE%.bak.%RUNID%"
copy /b /y "%FILE%" "%BACKUP%" >nul 2>&1
if not exist "%BACKUP%" (
    call :Log ERROR "Failed to create backup: %DISPLAY%"
    set /a ERR_PROCESSING+=1
    set "EXITCODE=1"
    call :DiscardWork
    exit /b 0
)

if defined PSEXE for /f "usebackq delims=" %%T in (`%PSEXE% -NoProfile -NonInteractive -Command "(Get-Item -LiteralPath '%~1' -Force).LastWriteTimeUtc.ToString('o')" 2^>nul`) do set "MTIME=%%T"

rem The replacement. `copy /b` onto the original keeps its attributes and its
rem creation time (measured) - that is how this script preserves identity, where
rem the reference uses chown/chmod and the port uses Set-Acl. What copy does NOT
rem preserve is the receiver's modification time, hence the two PowerShell calls.
if exist "%NEWFILE%" (
    copy /b /y "%NEWFILE%" "%FILE%" >nul 2>&1
) else (
    rem Nothing survived cleaning: a BOM-only file becomes an empty file.
    type nul > "%FILE%"
)

if defined PSEXE if defined MTIME %PSEXE% -NoProfile -NonInteractive -Command "(Get-Item -LiteralPath '%~1' -Force).LastWriteTimeUtc = [datetime]::Parse('!MTIME!', [cultureinfo]::InvariantCulture)" >nul 2>&1

del "%BACKUP%" >nul 2>&1
call :DiscardWork

set /a PROCESSED_COUNT+=1
call :CountType "%CATEGORY%"
if not "%HAS_BOM%"=="0" set /a BOM_REMOVED_COUNT+=1
if not "%HAS_CRLF%"=="0" set /a CRLF_FIXED_COUNT+=1
call :Log SUCCESS "Successfully processed: %DISPLAY% (Fixed: %ISSUES%)"
exit /b 0

:file_missing
rem The reference logs this as an error and carries on with exit code 0, and the
rem port reproduces that. Measured on both.
call :Log ERROR "File not found: %DISPLAY%"
set /a ERR_ACCESS+=1
exit /b 0

:EchoWouldProcess
rem Messages that contain parentheses are printed from their own label. Measured:
rem text with '(' or ')' inside an if-block breaks the block parser - first by
rem closing the block early, then, once escaped with ^( ... ^), by killing the run
rem with exit 255 straight after the PROCESSING line. That is why this message and
rem the binary-skip one are not echoed from inside the block that triggers them.
>&2 echo Would process: %DISPLAY% (Issues: %ISSUES%, Type: %CATEGORY%)
goto :eof

:LogBinarySkipped
call :Log WARN "Binary content (NUL byte) detected at hex line %NUL_OFFSET%, skipping: %DISPLAY%"
goto :eof

rem ===========================================================================
rem  Detection
rem ===========================================================================

:DetectIssues
rem %1 = file. Sets HAS_BOM, HAS_CRLF.
set "HAS_BOM=0"
set "HAS_CRLF=0"
set "WINDOW="
call :ReadHexWindow "%~1"
if "%WINDOW%"=="" goto :eof
if "%NO_BOM_CLEAR%"=="0" if "!WINDOW:~0,6!"=="efbbbf" set "HAS_BOM=1"
if "%NO_RN_NORMALIZE%"=="0" (
    echo(!WINDOW! | findstr /c:"0d0a" >nul 2>&1 && set "HAS_CRLF=1"
)
goto :eof

:ReadHexWindow
rem The first 1024 bytes as one despaced hex string. That is the reference's
rem detection window, read through a type-4 dump: 64 lines of 16 values.
set "WINDOW="
set "TMPHEX=%WORKDIR%\%TOOLPREFIX%win.hex"
del "%TMPHEX%" >nul 2>&1
certutil -encodehex -f "%~1" "%TMPHEX%" 4 >nul 2>&1
if not exist "%TMPHEX%" goto :eof
set "LINES=0"
for /f "usebackq delims=" %%L in ("%TMPHEX%") do (
    if !LINES! LSS 64 (
        set "CHUNK=%%L"
        set "CHUNK=!CHUNK: =!"
        set "WINDOW=!WINDOW!!CHUNK!"
        set /a LINES+=1
    )
)
del "%TMPHEX%" >nul 2>&1
goto :eof

:IssuesText
set "ISSUES="
if "%HAS_BOM%"=="1" set "ISSUES=BOM"
if "%HAS_CRLF%"=="1" (
    if "%ISSUES%"=="" ( set "ISSUES=CRLF" ) else ( set "ISSUES=%ISSUES%+CRLF" )
)
goto :eof

:FindNulOffset
rem Scans the WHOLE file for a NUL byte and leaves its decimal offset in
rem NUL_OFFSET. One `findstr` pass over the hex dump answers it - not one pass per
rem line. Measured on a 120 KB file: the previous per-line design would have been
rem about 16 minutes of string slicing.
rem
rem Both patterns are needed: `^00` anchors at the start of a line, ` 00` covers
rem every other position. Measured over every position of every length from 1 to
rem 64 bytes, and on NUL-free files from 1 to 80 bytes: no miss, no false hit.
rem
rem The offset is reported, not the exact column arithmetic: with 16 values per
rem line the line number is enough to find it, and the column loop cost more than
rem it was worth.
set "NUL_OFFSET="
set "TMPHEX=%WORKDIR%\%TOOLPREFIX%nul.hex"
del "%TMPHEX%" >nul 2>&1
certutil -encodehex -f "%~1" "%TMPHEX%" 4 >nul 2>&1
if not exist "%TMPHEX%" goto :eof
set "LN=0"
for /f "usebackq delims=:" %%N in (`findstr /n /r /c:"^00" /c:" 00" "%TMPHEX%"`) do if not defined NUL_OFFSET set "NUL_OFFSET=%%N"
del "%TMPHEX%" >nul 2>&1
goto :eof

:NulFound
rem Sets IS_BINARY from NUL_OFFSET. Kept as its own label so the arithmetic never
rem lands inside an if-block; see the comment at the call site.
set "IS_BINARY=N"
if not "%NUL_OFFSET%"=="" set /a SKIPPED_COUNT+=1
if not "%NUL_OFFSET%"=="" set "IS_BINARY=Y"
goto :eof

rem ===========================================================================
rem  Transformation
rem ===========================================================================

:Transform
rem %1 = source file. Leaves the cleaned bytes in NEWFILE, or clears
rem TRANSFORM_OK on failure. NEWFILE empty means "the cleaned file is empty".
rem
rem This reproduces `sed -e 's/\r$//' -e '1s/^\xef\xbb\xbf//'`:
rem   * values are concatenated across lines first, because a CRLF pair can
rem     straddle the 16-byte boundary of the dump and `0d` and `0a` would then
rem     never be adjacent;
rem   * ONE value is held back as a carry. The carry is not just a buffer: the
rem     space cmd's `for /f` inserts between two lines stands in for the byte the
rem     hex dump does not represent - a line separator - so the next line's first
rem     value is not on the same line as the carry and must not be joined to it;
rem   * `0d0a` -> `0a` is applied to the body BEFORE the carry is split off,
rem     otherwise a pair landing on the boundary is broken;
rem   * the carry is resolved at end of file: a lone `0d` is dropped (sed's `$`
rem     matches the end of the buffer), anything else is emitted.
rem
rem Calibrated against the PowerShell port on 13 fixtures: a CR at every offset
rem relative to the 16-byte boundary, CRLF at end of file, lone CR, a CR before a
rem CRLF, and a BOM-only file that must come out empty. All 13 match byte for
rem byte.
set "TRANSFORM_OK=0"
set "NEWFILE="

set "TMPHEX=%WORKDIR%\%TOOLPREFIX%src.hex"
set "OUTHEX=%WORKDIR%\%TOOLPREFIX%out.hex"
del "%TMPHEX%" >nul 2>&1
del "%OUTHEX%" >nul 2>&1

certutil -encodehex -f "%~1" "%TMPHEX%" 4 >nul 2>&1
if not exist "%TMPHEX%" goto :eof

set "CARRY="
set "FIRST=1"
set "LINEHEX="
rem A one-value file - which is what a BOM-only file becomes once the BOM is
rem dropped - produced no usable dump, because substring expansion is a no-op
rem when the value is empty. Measured in this shell:
rem   set "B=" & set "B=!B:0d0a=0a!"   -> B=[0d0a=0a]   (literal assigned)
rem   set "C=" & set "T=!C:~6!"         -> T=[~6]        (literal assigned)
rem   set "F=abc" & set "F=!F:abc=!"    -> F=[]          (fine on a non-empty value)
rem A file short enough to fit one dump line is therefore written out whole,
rem without any per-line splitting: the result is exact and no arithmetic is
rem needed inside the loop.
call :CountLines "%TMPHEX%"
if %HEXLINE_COUNT% LEQ 1 (
    for /f "usebackq delims=" %%L in ("%TMPHEX%") do set "ONELINE=%%L"
    call :TransformSingle
    goto :transform_finish
)

for /f "usebackq delims=" %%L in ("%TMPHEX%") do (
    set "CUR=%%L"
    set "CUR=!CUR: =!"
    if "!FIRST!"=="1" (
        set "FIRST=0"
        if "%HAS_BOM%"=="1" (
            set "CUR=!CUR:~6!"
        )
    )
    set "BODY=!CARRY!!CUR!"
    set "BODY=!BODY:0d0a=0a!"
    set "TAIL=!BODY:~-2!"
    if "!BODY!"=="!TAIL!" ( set "HEAD=" ) else ( set "HEAD=!BODY:~0,-2!" )
    if not "!HEAD!"=="" (
        set "LINEHEX=!LINEHEX!!HEAD!"
        rem 14 values = 28 characters. A length test costs nothing here; a counter
        rem would need arithmetic in the tightest loop of the script.
        if not "!LINEHEX:~28!"=="" call :FlushLine
    )
    set "CARRY=!TAIL!"
)
if not "%CARRY%"=="" if not "%CARRY%"=="0d" set "LINEHEX=%LINEHEX%%CARRY%"
if not "%LINEHEX%"=="" call :FlushLine

:transform_finish

del "%TMPHEX%" >nul 2>&1

if not exist "%OUTHEX%" ( set "TRANSFORM_OK=1" & goto :eof )
for %%A in ("%OUTHEX%") do set "OSIZE=%%~zA"
if "%OSIZE%"=="0" ( set "TRANSFORM_OK=1" & goto :eof )

set "NEWFILE=%WORKDIR%\%TOOLPREFIX%new"
del "%NEWFILE%" >nul 2>&1
certutil -decodehex "%OUTHEX%" "%NEWFILE%" 4 >nul 2>&1
if not exist "%NEWFILE%" goto :discard
del "%OUTHEX%" >nul 2>&1
set "TRANSFORM_OK=1"
goto :eof

:discard
set "NEWFILE="
goto :eof

:FlushLine
rem Writes the accumulated values as a dump `certutil -decodehex` accepts: a
rem leading space, single spaces between values, a CRLF terminator.
rem
rem The empty-value guards are not decoration. Measured in this shell, with an
rem EMPTY value the substring syntax is not evaluated at all:
rem   set "RUN=" & set "RUN=!RUN:~2!"   -> RUN=[~2]
rem so the loop would copy the literal back onto itself forever. Reading past the
rem end yields nothing, which is also how the loop ends normally.
set "RUN=%LINEHEX%"
set "SPACED="
:flush_loop
if "%RUN%"=="" goto :flush_done
set "TWO=%RUN:~0,2%"
if "%TWO%"=="" goto :flush_done
set "SPACED=%SPACED% %TWO%"
set "RUN=%RUN:~2%"
goto :flush_loop
:flush_done
>> "%OUTHEX%" echo %SPACED%
set "LINEHEX="
goto :eof

:TransformSingle
rem One dump line only: despaced hex, BOM dropped, a trailing CRLF pair turned
rem into a single LF, a trailing lone CR dropped. No line splitting is needed
rem because there is no line boundary to protect.
set "CUR=%ONELINE: =%"
rem The BOM strip is skipped when the BOM is the whole content, because
rem `set "CUR=%CUR:~6%"` on an empty value assigns the literal `:~6%` instead of
rem nothing - measured: `set "C=" & set "T=!C:~6!"` gives T=[~6]. The result is
rem an empty file, which is what the reference produces for a BOM-only file.
if "%HAS_BOM%"=="1" if not "%CUR%"=="efbbbf" set "CUR=%CUR:~6%"
set "CUR=%CUR:0d0a=0a%"
if "%CUR:~-2%"=="0d" set "CUR=%CUR:~0,-2%"
if "%CUR%"=="efbbbf" set "CUR="
if "%CUR%"=="" goto :eof
>> "%OUTHEX%" echo %CUR%
goto :eof

:CountLines
rem %1 = file. Sets HEXLINE_COUNT. 'set /a' lives out here, outside any if-block:
rem measured, `set /a N+=1` inside a block has %N% expanded before parsing and
rem becomes the literal `set /a 5+=1`, where cmd fails with
rem "* was unexpected at this time".
set "HEXLINE_COUNT=0"
for /f "usebackq delims=" %%L in ("%~1") do set /a HEXLINE_COUNT+=1
goto :eof

:DiscardWork
if defined NEWFILE del "%NEWFILE%" >nul 2>&1
del "%WORKDIR%\%TOOLPREFIX%out.hex" >nul 2>&1
del "%WORKDIR%\%TOOLPREFIX%src.hex" >nul 2>&1
del "%WORKDIR%\%TOOLPREFIX%nul.hex" >nul 2>&1
del "%WORKDIR%\%TOOLPREFIX%win.hex" >nul 2>&1
set "NEWFILE="
goto :eof

:BuildList
rem Walks the current directory. This is the reference's
rem   find . -type f -size +0c -size -100Mc \( -iname '*.php' -o ... \)
rem with two additions borrowed from the PowerShell port: third-party and
rem generated trees are pruned, and only the seven supported extensions are
rem walked instead of the whole tree. The reference enters vendor/,
rem node_modules/ and .git/ and rewrites what it finds there.
rem
rem The pattern list carries .htm, NOT .html, and the extension is decided per
rem file by :Categorize instead. Measured: `for /r` matches on 8.3 short names,
rem and `.html` shortens to `.HTM`, so the .htm pattern already yields every
rem .html file. Listing both produced each .html fixture twice - in one run the
rem file was processed and then reported clean a moment later - while dropping
rem .htm entirely skipped real .htm files (two fixtures came back untouched).
rem The .htm pattern plus the per-file extension check is the combination that
rem matches the Unix original exactly.
del "%LISTFILE%" >nul 2>&1
for /r "%CD%" %%F in (*.php *.css *.js *.txt *.xml *.htm) do call :ConsiderFile "%%F"
goto :eof

:ConsiderFile
rem %1 = path from the walk
for %%A in ("%~1") do set /a CSIZE=%%~zA
rem Kept out of blocks on purpose: `set /a CSIZE=%%~zA` inside an if-block is the
rem same trap as `set /a ... +=1` - the expansion happens before parsing and cmd
rem then fails with "* was unexpected at this time".
call :SkipBySize
if /i "%DIFFERENT%"=="Y" goto :eof
call :SkipByTree "%~1"
if /i "%PRUNE%"=="Y" goto :eof
>> "%LISTFILE%" echo "%~1"
goto :eof

:SkipBySize
set "DIFFERENT=N"
if %CSIZE% LSS 1 set "DIFFERENT=Y"
if %CSIZE% GEQ %MAX_FILE_SIZE% set "DIFFERENT=Y"
goto :eof

:SkipByTree
rem %1 = path. Sets PRUNE when the file is either in a pruned tree or of an
rem unsupported extension. The extension round is not optional. Measured: `for /r`
rem with the *.htm pattern also yields .html files, because the walk consults
rem 8.3 short names and .html shortens to `.HTM` - the same trap this project
rem documents for Get-ChildItem -Filter in PowerShell. Without this round the
rem list held mixed.html twice, inflating the count and logging the file a second
rem time as clean.
set "PRUNE=N"
echo("%~dp0"| findstr /i /c:"\vendor\" /c:"\node_modules\" /c:"\.git\" /c:"\bower_components\" /c:"\dist\" /c:"\build\" /c:"\target\" /c:"\coverage\" /c:"\__pycache__\" /c:"\.venv\" /c:"\venv\" /c:"\.idea\" /c:"\.vscode\" /c:"\.svn\" /c:"\.hg\" >nul 2>&1
if not errorlevel 1 set "PRUNE=Y"
call :Categorize "%~1"
if "%CATEGORY%"=="other" set "PRUNE=Y"
goto :eof

rem ===========================================================================
rem  Small helpers
rem ===========================================================================

:Categorize
rem %1 = path. Sets CATEGORY to a supported extension, or 'other'.
set "CATEGORY=other"
for %%E in (%SUPPORTED_EXTENSIONS%) do for %%F in ("%~1") do if /i "%%~xF"==".%%E" set "CATEGORY=%%E"
goto :eof

:CountType
if /i "%~1"=="php"  ( set /a CNT_PHP+=1  & goto :eof )
if /i "%~1"=="css"  ( set /a CNT_CSS+=1  & goto :eof )
if /i "%~1"=="js"   ( set /a CNT_JS+=1   & goto :eof )
if /i "%~1"=="txt"  ( set /a CNT_TXT+=1  & goto :eof )
if /i "%~1"=="xml"  ( set /a CNT_XML+=1  & goto :eof )
if /i "%~1"=="htm"  ( set /a CNT_HTM+=1  & goto :eof )
if /i "%~1"=="html" ( set /a CNT_HTML+=1 & goto :eof )
set /a CNT_OTHER+=1
goto :eof

:ToReferenceForm
rem %1 = target variable, %2 = path. Produces the shape the reference's `find .`
rem prints: './name' with forward slashes. The prefix strip needs `call` because
rem the replacement text is itself a variable and %CD% may contain spaces.
set "ABS=%~2"
set "CDS=%CD%"
call set "REL=%%ABS:%CDS%\=%%"
set "REL=%REL:\=/%"
if "%REL%"=="%ABS%" ( for %%A in ("%~2") do set "%~1=./%%~nxA" & goto :eof )
set "%~1=./%REL%"
goto :eof

:Now
rem Reference-shaped timestamp from the locale's own date string, exactly as the
rem reference prints `date '+%Y-%m-%d %H:%M:%S'` in its locale.
set "T=%TIME: =0%"
set "NOW=%DATE% %T:~0,8%"
goto :eof

:Log
rem %1 = level, %2 = message. INFO and ERROR always print; WARN, SUCCESS and
rem PROCESSING print in verbose mode only - the reference's rule, and the port's.
rem
rem The message is taken from %~2 and NOT from %*. Measured: inside a called
rem label %* also carries the label's own arguments, so the level was printed
rem twice and the message arrived wrapped in its quotes.
set "LEVEL=%~1"
set "MSG=%~2"
if "%LEVEL%"=="WARN" if not "%VERBOSE%"=="1" goto :eof
if "%LEVEL%"=="SUCCESS" if not "%VERBOSE%"=="1" goto :eof
if "%LEVEL%"=="PROCESSING" if not "%VERBOSE%"=="1" goto :eof
call :Now
if "%LEVEL%"=="ERROR" set /a ERROR_COUNT+=1
>&2 echo [%NOW% %LEVEL%] %MSG%
goto :eof

rem ===========================================================================
rem  Reporting
rem ===========================================================================

:ShowHelp
echo UTF-8 BOM and Windows CRLF Cleaner - Professional Source Code Sanitizer
echo USAGE
echo     clean-bom-senior.bat [OPTIONS] [FILE...]
echo DESCRIPTION
echo     Safely detects and removes invisible UTF-8 Byte Order Marks (BOM) and
echo     Windows CRLF line endings from source code and text files. Designed for
echo     PHP developers working in multi-editor, cross-platform environments.
echo OPTIONS
echo     -h, --help              Show this help message and exit
echo     -v, --verbose           Enable detailed output and processing logs
echo     -n, --dry-run           Preview which files would be processed (no modifications)
echo     -V, --version           Display script version information
echo     --no-bom-clear          Disable removal of UTF-8 BOM
echo     --no-rn-normalize       Disable conversion of CRLF to LF
echo SUPPORTED FILE TYPES
echo     Extensions: php, css, js, txt, xml, htm, html
echo     Max file size: 100 MB per file
echo EXAMPLES
echo     clean-bom-senior.bat                             Process all files recursively
echo     clean-bom-senior.bat --no-bom-clear              Skip BOM removal
echo     clean-bom-senior.bat --no-rn-normalize           Skip CRLF normalization
echo     clean-bom-senior.bat --dry-run                   Preview mode (no file changes)
echo     clean-bom-senior.bat file1.php file2.js          Process specific files only
echo FILE PRESERVATION
echo     - Original file ownership (user/group) is preserved
echo     - File permissions (mode) remain unchanged
echo     - Timestamps are maintained for unmodified files
echo     - Atomic operations ensure data integrity
echo EXIT CODES
echo     0  Success - all files processed without errors
echo     1  Partial success - some files had processing errors
echo     2  Invalid command line arguments
echo     3  Missing dependencies or insufficient permissions
echo NOTES
echo     - Files are processed atomically with backup and rollback support
echo     - Only files containing BOM or CRLF are actually modified
echo     - Suitable for CI/CD integration and pre-commit hooks
echo     - Works with any user privileges (preserves original ownership)
echo BATCH PORT NOTES
echo     - This help text is ASCII only. A batch file cannot emit the reference's
echo       UTF-8 bullets reliably, because that depends on the console code page;
echo       file content is unaffected because it never passes through it.
echo     - File bytes are carried through certutil, so non-ASCII content is
echo       preserved exactly.
echo     - The modification time is restored through PowerShell when available.
echo For more information, visit: https://github.com/paulmann/Clean_BOM_Senior
goto :eof

:ShowVersion
echo %SCRIPT_NAME% version %VERSION%
echo Author: Mikhail Deynekin ^<mid1977@gmail.com^>
echo Website: https://deynekin.com
goto :eof

:ShowGreeting
call :Now
>&2 echo.
>&2 echo === UTF-8 BOM ^& CRLF Cleaner v%VERSION% ===
>&2 echo Author: Mikhail Deynekin (mid1977@gmail.com)
>&2 echo Website: https://deynekin.com
>&2 echo Started: %NOW%
>&2 echo.
>&2 echo --- Configuration ---
if "%VERBOSE%"=="1" (>&2 echo Verbose mode: ENABLED) else (>&2 echo Verbose mode: DISABLED)
if "%DRY_RUN%"=="1" (>&2 echo Dry-run mode: ENABLED) else (>&2 echo Dry-run mode: DISABLED)
if "%NO_BOM_CLEAR%"=="1" (>&2 echo BOM removal: DISABLED) else (>&2 echo BOM removal: ENABLED)
if "%NO_RN_NORMALIZE%"=="1" (>&2 echo CRLF normalization: DISABLED) else (>&2 echo CRLF normalization: ENABLED)
>&2 echo Supported extensions: %SUPPORTED_EXTENSIONS%
>&2 echo Maximum file size: %MAX_FILE_SIZE_MB% MB
>&2 echo.
>&2 echo --- Operation Mode ---
if "%DRY_RUN%"=="1" (
    >&2 echo - Scanning files for UTF-8 BOM and CRLF issues
    >&2 echo - Showing which files need cleaning
    >&2 echo - NO FILES WILL BE MODIFIED (preview mode)
) else (
    >&2 echo - Scanning files for UTF-8 BOM and CRLF issues
    if "%NO_BOM_CLEAR%"=="0" >&2 echo - Removing invisible UTF-8 BOM signatures
    if "%NO_RN_NORMALIZE%"=="0" >&2 echo - Converting Windows CRLF to Unix LF
    >&2 echo - Preserving file ownership, permissions, and timestamps
    >&2 echo - Creating backup copies during processing
)
if not defined PSEXE (
    >&2 echo - WARNING: PowerShell was not found, so modification times are not preserved.
)
>&2 echo.
>&2 echo Starting file processing...
goto :eof

:ShowStatistics
call :Now
if not "%START_EPOCH%"=="0" if defined PSEXE for /f "usebackq delims=" %%T in (`%PSEXE% -NoProfile -NonInteractive -Command "$s=[int](New-TimeSpan -Start (Get-Date '1970-01-01') -End (Get-Date)).TotalSeconds; $s-%START_EPOCH%" 2^>nul`) do set "ELAPSED=%%T"
>&2 echo.
>&2 echo === PROCESSING SUMMARY ===
>&2 echo Execution time: %ELAPSED% seconds
>&2 echo Files processed: %PROCESSED_COUNT%
>&2 echo Files skipped (clean): %SKIPPED_COUNT%
>&2 echo Errors encountered: %ERROR_COUNT%
if %PROCESSED_COUNT% GTR 0 (
    >&2 echo.
    >&2 echo --- Issues Fixed ---
    >&2 echo BOM signatures removed: %BOM_REMOVED_COUNT%
    >&2 echo CRLF line endings fixed: %CRLF_FIXED_COUNT%
    >&2 echo.
    >&2 echo --- File Type Distribution ---
    if %CNT_PHP%  GTR 0 >&2 echo .php files: %CNT_PHP%
    if %CNT_CSS%  GTR 0 >&2 echo .css files: %CNT_CSS%
    if %CNT_JS%   GTR 0 >&2 echo .js files: %CNT_JS%
    if %CNT_TXT%  GTR 0 >&2 echo .txt files: %CNT_TXT%
    if %CNT_XML%  GTR 0 >&2 echo .xml files: %CNT_XML%
    if %CNT_HTM%  GTR 0 >&2 echo .htm files: %CNT_HTM%
    if %CNT_HTML% GTR 0 >&2 echo .html files: %CNT_HTML%
    if %CNT_OTHER% GTR 0 >&2 echo Other files: %CNT_OTHER%
)
if %ERROR_COUNT% GTR 0 (
    >&2 echo.
    >&2 echo --- Error Breakdown ---
    >&2 echo Access errors: %ERR_ACCESS%
    >&2 echo File size errors: %ERR_SIZE%
    >&2 echo Processing errors: %ERR_PROCESSING%
    >&2 echo Other errors: %ERR_OTHER%
)
if "%DRY_RUN%"=="1" if %PROCESSED_COUNT% GTR 0 (
    >&2 echo.
    >&2 echo --- Files That Would Be Processed ---
)
>&2 echo.
>&2 echo Processing completed at: %NOW%
goto :eof

rem ===========================================================================
rem  Fatal setup errors
rem ===========================================================================

:err_temp
>&2 echo [ERROR] No write access to temp directory: %WORKDIR%
exit /b 3

:err_tool
>&2 echo [ERROR] Missing required commands: certutil findstr
exit /b 3
