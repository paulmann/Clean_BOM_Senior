#!/usr/bin/env python3
"""Differential harness: clean-bom-senior.sh (reference) vs clean-bom-senior.ps1.

Builds two identical fixture trees, runs both implementations with identical
arguments, and compares four things: the resulting bytes of every file, the
file set (backups and such), the normalised stderr, the normalised stdout, and
the exit code.

  Usage:  python3 tests/ps/differential.py [CASE ...]
  Exit:   0 = identical, 1 = differences, 2 = prerequisite missing.

  DIFF_VERBOSE=1  print both streams in full instead of a unified diff
  DIFF_KEEP=1     keep the fixture trees under .difftmp/ for inspection
  DIFF_SH=..., DIFF_PS=...   run against copies elsewhere

Requires bash and pwsh (PowerShell 7.6+). When either is missing the run is
reported as skipped, never as passed.
"""

import difflib
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SH = os.environ.get('DIFF_SH', os.path.join(ROOT, 'clean-bom-senior.sh'))
PS = os.environ.get('DIFF_PS', os.path.join(ROOT, 'clean-bom-senior.ps1'))
WORK = os.environ.get('DIFF_ROOT', os.path.join(ROOT, '.difftmp'))

# Fixtures chosen to exercise every row of the Smart BOM Policy decision table
# plus the walking, exclusion and reporting rules.
FIXTURES = [
    ('src/a.php',              b'\xef\xbb\xbf<?php\r\necho 1;\r\n'),      # BOM + CRLF, code ext
    ('src/b.css',              b'clean\r\nfile\r\n'),                     # CRLF only
    ('src/nested/c.js',        b'\xef\xbb\xbfbody{}\r\n'),                # BOM + CRLF, nested
    ('src/nested/d.txt',       b'\xef\xbb\xbfcaf\xc3\xa9\r\nline2\r\n'),  # sensitive + non-ASCII
    ('src/e.txt',              b'\xef\xbb\xbfplain ascii\r\n'),           # sensitive but ASCII
    ('src/f.txt',              b'\xff\xfeh\x00i\x00\r\x00\n\x00'),        # UTF-16LE
    ('src/g.xml',              b'\xfe\xff\x00h\x00i\x00\x00\r\x00\n'),    # UTF-16BE, no 0D0A pair
    ('src/h.txt',              b'\xff\xfe\x00\x00\x00h\x00\x00\x00i\r\x00\x00\x00\n'),  # UTF-32LE
    ('src/i.txt',              b'\x00\x00\xfe\xff\x00\x00\x00h\x00\x00\x00i'),          # UTF-32BE
    ('src/u16mix.txt',         b'\xff\xfeh\x00\r\nZZ'),                   # UTF-16LE WITH 0D0A
    ('src/j.js',               b'BIN\x00ARY\r\n'),                        # NUL -> binary
    ('src/k.php',              b'\xef\xbb\xbf\xc3\x28 invalid\r\n'),      # invalid UTF-8
    ('src/l.js',               b'x\r'),                                   # lone CR at EOF
    ('src/m.js',               b'a\rb\r\n'),                              # lone CR mid-line
    ('src/n.php',              b'\r\n'),                                  # CRLF only, no text
    ('src/o.php',              b'\xef\xbb\xbf'),                          # BOM only -> empty
    ('src/p.php',              b'\xef\xbb\xbf\r\n'),                      # BOM + one CRLF
    ('src/q.php',              b'\xef\xbb\xbf<?php\n'),                   # BOM only, LF endings
    ('src/r.csv',              b'\xef\xbb\xbfa,b,c\r\n'),                 # sensitive ext
    ('src/s.ps1',              b'\xef\xbb\xbf#ps1 \xc3\xa9\r\n'),         # sensitive ext
    ('src/noext',              b'no ext\r\n'),                            # no extension
    ('src/t.weird',            b'\xef\xbb\xbfunknown \xc3\xa9\r\n'),      # unknown ext
    ('src/empty.php',          b''),                                      # skipped by the walk
    ('odd dir/u.php',          b'\xef\xbb\xbfsp\r\n'),                    # space in the path
    ('.git/v.php',             b'\xef\xbb\xbfgit\r\n'),                   # default-excluded
    ('node_modules/pkg/w.php', b'\xef\xbb\xbfdep\r\n'),                   # default-excluded
    ('dist/x.php',             b'\xef\xbb\xbfdis\r\n'),                   # --exclude target
    ('build/y.php',            b'\xef\xbb\xbfbig\r\n'),                   # --exclude-dir target
]
SYMLINKS = [('src/link.php', 'a.php')]   # relative: stays inside its own tree

CASES = [
    ('basic',          ['--quiet']),
    ('verbose',        ['-v']),
    ('dryrun',         ['--dry-run']),
    ('check',          ['--check']),
    ('check_verbose',  ['--check', '-v']),
    ('json',           ['--json', '--quiet']),
    ('json_dry',       ['--json', '--dry-run']),
    ('json_check',     ['--json', '--check']),
    ('force',          ['--quiet', '--force']),
    ('policy_strip',   ['--quiet', '--bom-policy=strip']),
    ('policy_keep',    ['--quiet', '--bom-policy=keep']),
    ('no_bom_clear',   ['--quiet', '--no-bom-clear']),
    ('no_crlf',        ['--quiet', '--no-crlf-normalize']),
    ('no_rn_v2name',   ['--quiet', '--no-rn-normalize']),
    ('both_disabled',  ['--quiet', '--no-bom-clear', '--no-crlf-normalize']),
    ('sensitive_off',  ['--quiet', '--sensitive-ext', '']),
    ('sensitive_set',  ['--quiet', '--sensitive-ext', 'php,js']),
    ('ext_replace',    ['--quiet', '--ext', 'php,js']),
    ('ext_replace_eq', ['--quiet', '--ext=php,js']),
    ('ext_add',        ['--quiet', '--add-ext', 'csv,ps1,weird']),
    ('ext_upper',      ['--quiet', '--add-ext', '.CSV, Ps1 ']),
    ('maxsize',        ['--quiet', '--max-size', '12']),
    ('maxsize_units',  ['--quiet', '--max-size', '1K']),
    ('exclude_glob',   ['--quiet', '--exclude', 'dist/*', '--exclude', '*/nested/*']),
    ('exclude_dir',    ['--quiet', '--exclude-dir', 'dist', '--exclude-dir', 'build']),
    ('exclude_dir_eq', ['--quiet', '--exclude-dir=dist']),
    ('no_def_excl',    ['--quiet', '--no-default-excludes']),
    ('no_def_excl_kept', ['--quiet', '--no-default-excludes', '--exclude-dir', 'dist']),
    ('dir_arg',        ['--quiet', 'src']),
    ('dir_and_file',   ['--quiet', 'src', 'dist/x.php']),
    ('file_arg',       ['--quiet', 'src/a.php', 'src/e.txt']),
    ('missing_file',   ['--quiet', 'nope.php']),
    ('mixed_ok_fail',  ['--quiet', 'src/a.php', 'nope.php']),
    ('strict',         ['--quiet', '--strict']),
    ('strict_clean',   ['--quiet', '--strict', 'src/nested/q.php']),
    ('backup',         ['--quiet', '--backup']),
    ('backup_dir',     ['--quiet', '--backup-dir', '../bakdir']),
    ('update_mtime',   ['--quiet', '--update-mtime']),
    ('no_keep_mtime',  ['--quiet', '--no-keep-mtime']),
    ('dashdash',       ['--quiet', '--', 'src/a.php']),
    ('unknown_opt',    ['--quiet', '--bogus']),
    ('unknown_short',  ['--quiet', '-Z']),
    ('bare_dash',      ['--quiet', '-']),
    ('bad_policy',     ['--quiet', '--bom-policy=nope']),
    ('bad_maxsize',    ['--quiet', '--max-size=abc']),
    ('bad_color',      ['--quiet', '--color', 'rainbow']),
    ('empty_ext',      ['--quiet', '--ext', '']),
    ('fix_flag',       ['--quiet', '-f']),
    ('log_file',       ['--quiet', '--log-file', '../run.log', 'src']),
    ('help_usage',     ['--help', 'usage']),
    ('help_options',   ['--help', 'options']),
    ('help_bom',       ['--help', 'bom-policy']),
    ('help_bom_alias', ['--help', 'bom']),
    ('help_safety',    ['--help', 'safety']),
    ('help_exit',      ['--help', 'exit-codes']),
    ('help_examples',  ['--help', 'examples']),
    ('help_env',       ['--help', 'env']),
    ('help_ci',        ['--help', 'ci']),
    ('help_files',     ['--help', 'files']),
    ('help_json',      ['--help', 'json']),
    ('help_compat',    ['--help', 'compatibility']),
    ('help_full',      ['--help']),
    ('help_topics',    ['--help', 'topics']),
    ('help_bad_topic', ['--help', 'nosuchtopic']),
    ('short_help',     ['-h']),
    ('version',        ['--version']),
    ('short_version',  ['-V']),
    ('quietmode',      ['-q']),
    ('silent',         ['--silent']),
    ('color_never',    ['--quiet', '--color', 'never']),
    ('color_always',   ['--quiet', '--color', 'always']),
    ('color_eq',       ['--quiet', '--color=always']),
    ('no_color_flag',  ['--quiet', '--no-color']),
    ('odd_dir',        ['--quiet', 'odd dir']),
    ('symlink_arg',    ['--quiet', 'src/link.php']),
    ('interspersed',   ['src', '--quiet', '--ext', 'php']),
    ('git_mode',       ['--quiet', '--git']),
    # --self-test and --completion are implementation-specific by contract
    # (each port verifies itself and completes for its own shell); they are
    # asserted in tests/ps/run-tests.ps1 rather than compared here.
]

# ---------------------------------------------------------------- normalisers
# Volatile fields (timestamps, durations, PIDs, absolute workspace paths) and
# the invocation name are folded away. Everything else must match byte for
# byte, or the case fails.
NORMALISERS = [
    (re.compile(r'\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ([A-Z]+)\]'), r'[TS \1]'),
    (re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ'), 'ISO'),
    (re.compile(r'"durationSeconds": \d+'), '"durationSeconds": N'),
    (re.compile(r'"cwd": "[^"]*"'), '"cwd": CWD'),
    (re.compile(r'^Processing completed at: .*$', re.M), 'Processing completed at: TS'),
    (re.compile(r'Started:.*$', re.M), 'Started: TS'),
    (re.compile(r'run at .*=====$', re.M), 'run at TS ====='),
    (re.compile(r'Execution time: \d+ seconds'), 'Execution time: N seconds'),
    (re.compile(r'\.bak\.\d+'), '.bak.PID'),
    (re.compile(r'cleanbom[.-][0-9A-Za-z.\-]+'), 'cleanbom.TMP'),
    # `<name> version <X.Y.Z>` and the USAGE block legitimately carry the
    # implementation's own file name (contract section 2).
    (re.compile(r'clean-bom-senior\.(?:sh|ps1|bat|js)'), 'TOOL'),
    (re.compile(r'\bbin/bom\.js\b'), 'TOOL'),
    # `--completion` emits a script for the host shell, so the one line that
    # advertises it names that shell. The emitted script itself is compared
    # structurally (PORT_SPECIFIC) rather than literally.
    (re.compile(r'Print a (?:bash|PowerShell|cmd\.exe) completion script'),
     'Print a SHELL completion script'),
]

# Output that is *supposed* to differ between implementations, keyed by case
# name -> exempt streams. Every exempt stream is still asserted structurally by
# port_specific_ok() below and by tests/ps/run-tests.ps1, so nothing is ignored.
#
# Precedent: bin/bom.js already ships its own `--help update` text describing
# its own download-and-verify mechanics (bin/bom.js, shebang, npm refusal)
# instead of the shell reference's. The self-update topic and the completion
# script describe the implementation you are holding; they are compared
# structurally, not literally. See docs/PS-PORT.md section 4.
PORT_SPECIFIC = {
    'help_update': ('stdout',),
    'completion': ('stdout',),
}


def port_specific_ok(case, stream, text):
    """Structural assertions for the exempt streams: they must still be right,
    just not literally identical to the reference."""
    if stream != 'stdout':
        return True, ''
    if case == 'help_update':
        needed = ['AUTO-UPDATE', '--check-update', '--update',
                  'CLEAN_BOM_UPDATE_URL', 'major.minor.patch',
                  'npm install -g clean-bom-senior@latest']
        missing = [n for n in needed if n not in text]
        return (not missing), 'update topic missing: %s' % ', '.join(missing)
    if case == 'completion':
        needed = ['Register-ArgumentCompleter', '--bom-policy', '--check',
                  'clean-bom-senior']
        missing = [n for n in needed if n not in text]
        return (not missing), 'completion script missing: %s' % ', '.join(missing)
    return True, ''


def normalise(text):
    for pat, rep in NORMALISERS:
        text = pat.sub(rep, text)
    return text.replace('\r\n', '\n')


def make_tree(d):
    if os.path.exists(d):
        shutil.rmtree(d)
    for rel, data in FIXTURES:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as fh:
            fh.write(data)
    for rel, target in SYMLINKS:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            os.symlink(target, p)
        except (OSError, NotImplementedError):
            pass


def walk_files(d):
    """Map relative path -> (kind, payload). Backup suffixes are normalised so
    that the writer's PID does not show up as a difference."""
    out = {}
    for base, dirs, files in os.walk(d):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(base, name)
            rel = os.path.relpath(full, d).replace(os.sep, '/')
            rel = re.sub(r'\.bak\.\d+$', '.bak.PID', rel)
            try:
                if os.path.islink(full):
                    out[rel] = ('link', os.readlink(full))
                else:
                    with open(full, 'rb') as fh:
                        out[rel] = ('file', fh.read())
            except OSError as exc:
                out[rel] = ('error', str(exc))
    return out


def run_tool(cmd, cwd, env=None):
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env)
    return (proc.returncode,
            proc.stdout.decode('utf-8', 'replace'),
            proc.stderr.decode('utf-8', 'replace'))


def posix_args_env():
    """Environment for the bash child that keeps our arguments literal.

    The MSYS2 runtime GLOBS the arguments of a program it launches when the
    parent is not an MSYS program. Launched from Python, a quoted `--exclude
    '*/nested/*'` therefore reaches the reference pre-expanded against the
    fixture tree - traced: `EXCLUDE_PATTERNS=$'src/nested/c.js\\n'`, so the run
    compared two implementations that had been asked for different things and
    the sh side lost the exclusion. `MSYS=noglob` turns that off; the tool is
    unaffected because a pattern typed in a shell is quoted by the shell itself.
    """
    if os.name != 'nt':
        return None
    env = dict(os.environ)
    env['MSYS'] = 'noglob'
    return env


def find_bash():
    """The shell that will run the reference.

    On POSIX the reference is executable and runs as-is. On Windows it is a
    shell script, so it has to be handed to bash - running it directly fails
    with `OSError: [WinError 193] %1 is not a valid Win32 application`, which is
    how this harness used to abort on the very platform the CI matrix runs it
    on (the run ended as an unhandled exception, not as a skip and not as a
    result). Git for Windows ships bash at the locations below; when none of
    them exists the run is reported as a skip, never as a pass.
    """
    if os.name != 'nt':
        return ['bash']
    for cand in (r'C:\Program Files\Git\bin\bash.exe',
                 r'C:\Program Files\Git\usr\bin\bash.exe',
                 r'C:\Program Files (x86)\Git\bin\bash.exe'):
        if os.path.exists(cand):
            return [cand]
    found = shutil.which('bash.exe') or shutil.which('bash')
    return [found] if found else None


def command_line(sh_cmd, sh_path, ps_path, args):
    """cmd that runs the reference with the given arguments."""
    return sh_cmd + [sh_path] + list(args)

def unified(a, b, context=2, limit=24):
    out = []
    for line in list(difflib.unified_diff(a.split('\n'), b.split('\n'),
                                          'sh', 'ps', lineterm='', n=context))[:limit]:
        out.append('    ' + line)
    return out


def run_case(name, args, sh_cmd, ps_cmd, keep=False):
    ws = os.path.join(WORK, name)
    sh_dir, ps_dir = os.path.join(ws, 'sh'), os.path.join(ws, 'ps')
    make_tree(sh_dir)
    make_tree(ps_dir)

    sh_rc, sh_out, sh_err = run_tool(sh_cmd + args, sh_dir, posix_args_env())
    if os.environ.get('DIFF_TRACE'):
        sys.stderr.write('TRACE cwd=%s\nTRACE cmd=%r\n' % (sh_dir, sh_cmd + args))
        sys.stderr.write('TRACE rc=%s err=%r\n' % (sh_rc, sh_err[-400:]))
    ps_rc, ps_out, ps_err = run_tool(ps_cmd + args, ps_dir)

    problems = []
    if sh_rc != ps_rc:
        problems.append('exit code: sh=%s ps=%s' % (sh_rc, ps_rc))

    a, b = walk_files(sh_dir), walk_files(ps_dir)
    if set(a) != set(b):
        only_sh = sorted(set(a) - set(b))
        only_ps = sorted(set(b) - set(a))
        if only_sh:
            problems.append('only in the sh tree: %s' % ', '.join(only_sh[:6]))
        if only_ps:
            problems.append('only in the ps tree: %s' % ', '.join(only_ps[:6]))
    for rel in sorted(set(a) & set(b)):
        if a[rel] != b[rel]:
            ka, va = a[rel]
            kb, vb = b[rel]
            if ka == 'file' and kb == 'file':
                problems.append('%s: sh=%s ps=%s' % (rel, va.hex()[:72], vb.hex()[:72]))
            else:
                problems.append('%s: sh=%r ps=%r' % (rel, a[rel], b[rel]))

    for label, sa, sb in (('stderr', sh_err, ps_err), ('stdout', sh_out, ps_out)):
        na = normalise(sa).replace(sh_dir.replace(os.sep, '/'), 'WS')
        nb = normalise(sb).replace(ps_dir.replace(os.sep, '/'), 'WS')
        if label in PORT_SPECIFIC.get(name, ()):
            fine, why = port_specific_ok(name, label, nb)
            if not fine:
                problems.append('%s: %s' % (label, why))
            continue
        if na != nb:
            problems.append('%s differs' % label)
            if os.environ.get('DIFF_VERBOSE'):
                problems.append('  --- sh %s ---\n%s' % (label, na[:2000]))
                problems.append('  --- ps %s ---\n%s' % (label, nb[:2000]))
            else:
                problems.extend(unified(na, nb))

    if keep:
        # persist the streams so a failing case can be inspected by hand
        for suffix, text in (('sh.err', sh_err), ('sh.out', sh_out),
                             ('ps.err', ps_err), ('ps.out', ps_out)):
            with open(os.path.join(ws, suffix), 'w', encoding='utf-8') as fh:
                fh.write(text)
        with open(os.path.join(ws, 'rc.txt'), 'w', encoding='utf-8') as fh:
            fh.write('sh=%s ps=%s\n' % (sh_rc, ps_rc))
    else:
        shutil.rmtree(ws, ignore_errors=True)
    return problems


def main():
    only = sys.argv[1:]
    for path, what in ((SH, 'shell reference'), (PS, 'PowerShell port')):
        if not os.path.exists(path):
            sys.stderr.write('FATAL: %s not found: %s\n' % (what, path))
            return 2
    if shutil.which('pwsh') is None:
        sys.stderr.write('SKIP: pwsh (PowerShell 7.6+) is not installed\n')
        return 0

    # The reference is a POSIX shell script: run it if the host can execute it
    # directly, otherwise hand it to bash (Windows). Without this the harness
    # died with WinError 193 on Windows instead of reporting anything.
    # The check is on the platform, not on os.access: on Windows X_OK only means
    # "the path exists", so asking for it would hand a .sh file straight to
    # CreateProcess (measured: os.access(..., os.X_OK) is True on Windows and
    # the run then aborts with WinError 193).
    if os.name != 'nt' and os.access(SH, os.X_OK):
        sh_cmd = [SH]
    else:
        bash = find_bash()
        if bash is None:
            sys.stderr.write('SKIP: the shell reference is not executable and '
                             'bash was not found (Git Bash on Windows)\n')
            return 0
        sh_cmd = bash + [SH]

    ps_cmd = ['pwsh', '-NoLogo', '-NoProfile', '-File', PS]

    os.makedirs(WORK, exist_ok=True)
    passed, failed, failures = 0, 0, []
    for name, args in CASES:
        if only and name not in only:
            continue
        problems = run_case(name, args, sh_cmd, ps_cmd,
                            keep=bool(os.environ.get('DIFF_KEEP')))
        if problems:
            failed += 1
            failures.append(name)
            print('DIFF %-18s %s' % (name, ' '.join(args)))
            for p in problems[:8]:
                print('       %s' % p)
        else:
            passed += 1
            print('ok   %-18s %s' % (name, ' '.join(args)))

    if not os.environ.get('DIFF_KEEP'):
        shutil.rmtree(WORK, ignore_errors=True)
    print('\n' + '-' * 40)
    print('differential sh vs ps1: %d identical, %d differing' % (passed, failed))
    if failures:
        print('differing: %s' % ' '.join(failures))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
