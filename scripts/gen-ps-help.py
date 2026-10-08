#!/usr/bin/env python3
"""Generate the PowerShell help functions from the shell reference.

The help topics are part of the CLI contract (docs/CLI-CONTRACT.md section 2),
so they must be byte-identical across implementations. Hand-copying them is how
they drift; this generator derives the PowerShell here-strings from the
authoritative text in clean-bom-senior.sh instead.

Two kinds of placeholder are handled:

  * `$SCRIPT_NAME` / `$VERSION` / `$REPO_SLUG_DEFAULT` in the shell source
    become PowerShell variables, expanded at run time.
  * `$(...)` command substitutions that merely echo a CONSTANT of the reference
    (`$(fmt_size "$MAX_SIZE_DEFAULT")`, `$EXTENSIONS_DEFAULT`, `$STRIP_ALWAYS`,
    `$SENSITIVE_DEFAULT`, `$(help_topics_list)`) are folded to their literal
    value, because the constants are identical in every implementation.

The only intentional textual difference is the self-update file name in the
`update` topic: each implementation replaces itself, so it names itself. That
substitution is applied to the shell text here, which keeps one source of truth.

Usage:  python3 scripts/gen-ps-help.py            # rewrite clean-bom-senior.ps1
        python3 scripts/gen-ps-help.py --check    # exit 1 if it would change
"""

import io
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SH = os.path.join(ROOT, 'clean-bom-senior.sh')
PS = os.path.join(ROOT, 'clean-bom-senior.ps1')

# Functions in the reference whose body is a single `cat <<EOF` / `cat <<'EOF'`.
TOPICS = [
    ('help_usage', 'Write-HelpUsage', True),
    ('help_options', 'Write-HelpOptions', False),
    ('help_bom_policy', 'Write-HelpBomPolicy', False),
    ('help_safety', 'Write-HelpSafety', False),
    ('help_exit_codes', 'Write-HelpExitCodes', False),
    ('help_examples', 'Write-HelpExamples', True),
    ('help_env', 'Write-HelpEnv', False),
    ('help_ci', 'Write-HelpCi', False),
    ('help_update', 'Write-HelpUpdate', True),
    ('help_files', 'Write-HelpFiles', False),
    ('help_json', 'Write-HelpJson', False),
    ('help_compatibility', 'Write-HelpCompatibility', False),
]

# Constants of the reference, used to fold `$(...)` echoes.
CONSTANTS = {
    'EXTENSIONS_DEFAULT': 'php css js txt xml htm html',
    'SENSITIVE_DEFAULT': 'txt csv tsv ps1 psm1 psd1',
    'STRIP_ALWAYS': (
        'php phtml phps inc php3 php4 php5 php7 php8 '
        'js mjs cjs jsx ts tsx vue json jsonc json5 '
        'css scss sass less htm html xhtml xml svg xsl xslt '
        'mustache hbs twig blade sh bash zsh fish py rb pl lua sql yaml yml toml'
    ),
    'MAX_SIZE_DEFAULT_HUMAN': '100M',
    'HELP_TOPICS': ('usage options bom-policy safety exit-codes examples env ci '
                    'update files json compatibility'),
}


def read(path):
    with io.open(path, encoding='utf-8') as fh:
        return fh.read()


def sh_function_body(src, name):
    """Return the literal text a `help_*` function cats, with $VARS resolved."""
    m = re.search(r'^%s\(\) \{\n(.*?)^\}\n' % re.escape(name), src, re.S | re.M)
    if not m:
        raise SystemExit('FATAL: %s() not found in the reference' % name)
    body = m.group(1)

    hm = re.search(r"cat <<-?\s*'?([A-Za-z_]+)'?\n(.*?)^\1\n", body, re.S | re.M)
    if not hm:
        raise SystemExit('FATAL: %s() has no single here-doc body' % name)
    text = hm.group(2)

    # Trailing command substitutions that echo a constant -> literal value.
    text = text.replace('$(fmt_size "$MAX_SIZE_DEFAULT")', CONSTANTS['MAX_SIZE_DEFAULT_HUMAN'])
    text = text.replace('$EXTENSIONS_DEFAULT', CONSTANTS['EXTENSIONS_DEFAULT'])
    text = text.replace('$SENSITIVE_DEFAULT', CONSTANTS['SENSITIVE_DEFAULT'])
    text = text.replace('$STRIP_ALWAYS', CONSTANTS['STRIP_ALWAYS'])
    text = text.replace('$(help_topics_list)', CONSTANTS['HELP_TOPICS'])

    # Run-time variables.
    text = text.replace('$SCRIPT_NAME', '$S')
    text = text.replace('$VERSION', '$V')
    text = text.replace('$REPO_SLUG_DEFAULT', '$REPO')

    # The `update` and `options` topics describe the implementation itself, so
    # three sentences are port-specific. Everything else must stay identical.
    if name == 'help_update':
        text = text.replace('clean-bom-senior.sh', 'clean-bom-senior.ps1')
        text = text.replace('clean-bom-senior.ps1 of that release', 'clean-bom-senior.ps1 of that release')
        text = text.replace(
            '    3. --update downloads clean-bom-senior.ps1 of that release, verifies it\n'
            '       (shebang + embedded version stamp), then replaces the running file\n'
            '       atomically via rename(2) \u2014 safe while this process keeps the old inode.',
            '    3. --update downloads clean-bom-senior.ps1 of that release, verifies it\n'
            '       (#Requires header + embedded version stamp), then replaces the\n'
            '       running file atomically \u2014 safe while this process keeps running.')
        text = text.replace(
            '    \u2022 Requires curl or wget. There is no telemetry: nothing is fetched unless\n'
            '      you explicitly pass --check-update / --update.',
            '    \u2022 Requires curl (Invoke-WebRequest is the fallback). There is no telemetry:\n'
            '      nothing is fetched unless you pass --check-update / --update.')
    if name == 'help_options':
        text = text.replace('--completion         Print a bash completion script',
                            '--completion         Print a PowerShell completion script')
    if name == 'help_env':
        text = text.replace('Must serve VERSION and clean-bom-senior.sh;',
                            'Must serve VERSION and clean-bom-senior.ps1;')

    return text


# Non-ASCII characters used by the reference's help text, mapped to ASCII
# placeholders. The file stays pure ASCII; Show-Help substitutes them back, so
# the emitted bytes are identical to the reference's.
NON_ASCII = [
    ('\u2014', '__EMDASH__'),
    ('\u2192', '__ARROW__'),
    ('\u2022', '__BULLET__'),
    ('\u2026', '__ELLIPSIS__'),
    ('\u2208', '__ELEMENTOF__'),
    ('\u2260', '__NOTEQUAL__'),
]


def to_ascii_placeholders(text):
    for ch, token in NON_ASCII:
        text = text.replace(ch, token)
    left = sorted({c for c in text if ord(c) > 127})
    if left:
        raise SystemExit('FATAL: unhandled non-ASCII characters: %s '
                         '(add them to NON_ASCII in scripts/gen-ps-help.py)'
                         % ' '.join('U+%04X' % ord(c) for c in left))
    return text


def ps_function(fname, text, needs_vars):
    """Render one Write-Help* function as a single-quoted here-string."""
    # A single-quoted here-string is 100% literal: no `$`, no backtick, no quote
    # escaping. Its only forbidden sequence is a line that is exactly `'@`.
    for line in text.split('\n'):
        if line.strip() == "'@":
            raise SystemExit('FATAL: %s contains a here-string terminator' % fname)
    text = to_ascii_placeholders(text)
    header = ''
    if needs_vars:
        header = ("    $S = $script:SCRIPT_NAME\n"
                  "    $V = $script:VERSION\n"
                  "    $REPO = $script:REPO_SLUG_DEFAULT\n")
        # Interpolation is needed, so this one uses a DOUBLE-quoted here-string;
        # `$` that is not one of our three variables must be escaped.
        esc = []
        for line in text.split('\n'):
            out = []
            i = 0
            while i < len(line):
                c = line[i]
                if c == '$':
                    nxt = line[i + 1:i + 3]
                    if nxt.startswith('S') and (i + 2 >= len(line) or not (line[i + 2].isalnum() or line[i + 2] == '_')):
                        out.append('$S'); i += 2; continue
                    if nxt.startswith('V') and (i + 2 >= len(line) or not (line[i + 2].isalnum() or line[i + 2] == '_')):
                        out.append('$V'); i += 2; continue
                    if line[i + 1:i + 6] == 'REPO}':
                        out.append('$REPO'); i += 6; continue
                    if line[i + 1:i + 5] == 'REPO':
                        out.append('$REPO'); i += 5; continue
                    out.append('`$'); i += 1; continue
                if c == '`':
                    out.append('``'); i += 1; continue
                out.append(c); i += 1
            esc.append(''.join(out))
        text = '\n'.join(esc)
        return ('function %s {\n%s    Write-StdOut @"\n%s\n"@\n}\n'
                % (fname, header, text))
    return "function %s {\n    Write-StdOut @'\n%s\n'@\n}\n" % (fname, text)


def build_help_block(src):
    out = ['# BEGIN GENERATED HELP (scripts/gen-ps-help.py)',
           '# The help topics are part of the CLI contract (docs/CLI-CONTRACT.md) and',
           '# must stay byte-identical across implementations, so they are derived from',
           '# the shell reference rather than hand-copied. Edit clean-bom-senior.sh,',
           '# then re-run:  python3 scripts/gen-ps-help.py',
           '# `scripts/check-version-consistency.sh` and CI fail on drift.']
    for sh_name, ps_name, needs_vars in TOPICS:
        text = sh_function_body(src, sh_name)
        out.append(ps_function(ps_name, text.rstrip('\n') + '\n', needs_vars))
    return '\n'.join(out)


def splice(ps_src, block):
    # The generated block sits between the (hand-written) help header and
    # Show-Help, delimited by an explicit banner so re-running is idempotent.
    start_marker = '# BEGIN GENERATED HELP (scripts/gen-ps-help.py)\n'
    end_marker = '# END GENERATED HELP\n\nfunction Show-Help {'
    i = ps_src.index(start_marker)
    j = ps_src.index(end_marker)
    return ps_src[:i] + block + '\n' + ps_src[j:]


def main():
    src = read(SH)
    block = build_help_block(src)
    ps = read(PS)
    new = splice(ps, block)
    if '--check' in sys.argv:
        if new != ps:
            sys.stderr.write('clean-bom-senior.ps1: help text is out of sync '
                             'with the reference (run scripts/gen-ps-help.py)\n')
            return 1
        print('help text in sync with the reference')
        return 0
    with io.open(PS, 'w', encoding='utf-8', newline='') as fh:
        fh.write(new)
    print('generated %d help functions into %s' % (len(TOPICS), os.path.basename(PS)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
