# Security Policy

## Scope

Clean BOM Senior modifies files **in place**. Its security surface is
therefore unusual for a CLI: the worst possible bug is not a crash but a
silent, wrong write. This policy treats the following as security issues:

1. **Data corruption** — any code path that writes bytes a user did not ask
   for: touching UTF-16/32 or NUL-binary files, adding/removing trailing
   newlines, breaking hard links or symlinks, half-written files after a
   crash or a full disk.
2. **Arbitrary-write / path traversal** — writing outside the selected
   scope (e.g. following directory symlinks during the walk, temp-file races
   in shared directories, backup paths escaping `--backup-dir`).
3. **Update channel** — anything that weakens `--update` verification
   (shebang + embedded version stamp), allows a redirect to an attacker-controlled
   host, or lets a downloaded script run before verification.
4. **Injection** — the reference is a shell script: any construct that lets a
   *filename* execute as code (`eval`, unquoted expansions) is a
   vulnerability. (v3 removed the `eval`-based find expression of v2.)

## Design mitigations (what we already guarantee)

- Atomic same-directory temp + verified `rename(2)`; rollback copies for
  in-place rewrites; temps are `mktemp`-created (0600) and registered for
  cleanup on signals.
- Hard refusals that no flag can override (UTF-16/32, NUL-binary) —
  `docs/SMART-BOM.md` §3.
- The walk never follows symlinks; symlink *arguments* are resolved and
  logged; the tool never deletes user files.
- No telemetry; network access only on explicit `--check-update`/`--update`.
- Both suites assert the corruption guarantees with raw-byte fixtures
  (`docs/TESTING.md`), including "clean file ⇒ inode & mtime stable".

## Reporting a vulnerability

Please **do not** open a public issue for anything in the scope above.

- Email: **mid1977@gmail.com** (repository owner)
- Include: version (`--version`), platform, a minimal reproduction with raw
  bytes (`od -An -tx1`), and the impact (which guarantee is broken).
- We aim to acknowledge within 72 hours and to ship a fix (and, when the
  issue is exploitable via the update channel, a release note) before public
  disclosure. Coordinate disclosure timing with us — npm and GitHub release
  artifacts are involved.

## Supported versions

| Version | Support |
|---|---|
| 3.x (`clean-bom-senior.sh`, `bin/bom.js`, `clean-bom-senior.ps1`) | Full support; security fixes released as patches |
| 2.07 (`clean-bom-senior.bat` legacy port) | Frozen; security fixes only if exploitable *as shipped*, backported as 2.07.x |
| 2.07 (`.ps1` legacy port) | **Superseded** — the file at that path is now a v3 implementation; the v2.07 port exists only in git history (`git show v3.0.0:clean-bom-senior.ps1`) and is unsupported |
| < 2.07 | Unsupported — upgrade |
