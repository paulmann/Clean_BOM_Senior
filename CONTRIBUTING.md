# Contributing

Thank you for considering a contribution to Clean BOM Senior!

## Ground rules

1. **One contract, several implementations.** Any behavioural change starts in
   `docs/CLI-CONTRACT.md`, then lands in the reference
   (`clean-bom-senior.sh`) and the Node CLI (`bin/bom.js`) *together*, with
   tests in both suites. The differential test must stay green.
2. **Never corrupt a file.** The Smart BOM Policy (`docs/SMART-BOM.md`) is
   the product's core promise: when in doubt, protect and explain — do not
   write. New "convenience" transformations that rewrite bytes need a
   byte-level safety argument and a test that fails without it.
3. **Clean files are never rewritten.** Not "rewritten with identical bytes" —
   *never touched* (inode and mtime stability are asserted in tests).
4. **Legacy ports are frozen.** `clean-bom-senior.ps1` / `.bat` stay at the
   v2.07 contract unless there is an explicit decision (and a Windows CI
   story) to move them.
5. **shellcheck-clean and `node --check`-clean**, no new dependencies
   (the tool must run on a bare server and a bare `npm i -g`).

## Development setup

```bash
git clone https://github.com/paulmann/Clean_BOM_Senior.git
cd Clean_BOM_Senior
bash tests/sh/run-tests.sh -v      # reference suite
node tests/node/run-tests.mjs      # Node suite (+ differential)
shellcheck clean-bom-senior.sh tests/sh/run-tests.sh
bash scripts/check-version-consistency.sh
```

Requirements: bash ≥ 3.2 mindset (macOS system bash must keep working — no
associative arrays, no `${var,,}`, no `mapfile`), Node ≥ 18, GNU **and** BSD
userland awareness (`stat`, `sed`, `touch` differences — use the shims).

## Pull request checklist

- [ ] Contract change? → `docs/CLI-CONTRACT.md` + `--help` topics + README updated.
- [ ] Policy change? → `docs/SMART-BOM.md` decision table updated.
- [ ] Tests added to **both** suites; each fails without the change.
- [ ] `CHANGELOG.md` entry under *Unreleased* (Keep a Changelog style).
- [ ] shellcheck 0 findings; `node --check` passes.
- [ ] Version bump only in release PRs, via
      `scripts/check-version-consistency.sh` (VERSION, sh, bom.js,
      package.json, CHANGELOG top entry).

## Reporting bugs

Include: OS + shell/Node versions, the tool version (`--version`), the exact
command line, and — whenever possible — the output of `--dry-run --json` and
a minimal hex fixture (`od -An -tx1 file | head`) reproducing it. Raw bytes
matter more than file names in this project.

## Security

See [SECURITY.md](SECURITY.md). This tool rewrites files in place; anything
that could make it write where it shouldn't is a security bug, not a feature
request.
