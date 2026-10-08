# Auto-update — `--check-update` / `--update`

## What it does

```bash
clean-bom-senior.sh --check-update    # exit 11 = a newer version exists
clean-bom-senior.sh --update          # verified self-replace
bom --check-update                    # the same, Node CLI
```

1. The tool fetches the single-line `VERSION` file from the repository
   (`https://raw.githubusercontent.com/paulmann/Clean_BOM_Senior/refs/heads/main/VERSION`
   by default) and compares `major.minor.patch` numerically with the running
   version.
2. `--check-update` stops there: exit **11** when an update exists, **0**
   when up to date, **3** when the check could not be performed (no
   curl/wget/network in the bash implementation; no network in the Node one).
3. `--update` downloads the release script — `refs/tags/v<X.Y.Z>` first,
   default branch as fallback — **verifies** it, and replaces the running
   file atomically (`rename(2)` in the same directory, exec bit preserved).

## Verification (all three implementations)

A downloaded script is installed only when:

- its first line is the expected header — `#!/usr/bin/env bash` (sh),
  `#!/usr/bin/env node` (npm CLI), `#Requires -Version` (PowerShell) — **and**
- it contains the version stamp matching the announced release:
  `VERSION="9.9.9"` / `const VERSION = '9.9.9';` /
  `$script:VERSION = '9.9.9';`.

Each implementation downloads **its own** file (`clean-bom-senior.sh`,
`bin/bom.js`, `clean-bom-senior.ps1`) from the release tag, falling back to the
default branch or the `CLEAN_BOM_UPDATE_URL` mirror.

On any mismatch the update is refused (exit 3) and the current file stays
**byte-identical** — pinned by tests in all three suites (`--update: tampered
download is refused`). Self-replacement while running is safe: `rename(2)`
swaps the directory entry and the executing process keeps the old inode. The
PowerShell port additionally carries the previous file's Unix permission bits
onto the replacement, so a directly-invoked (0755) install stays executable.

## npm-managed installations

If the Node CLI detects it is running from a `node_modules` tree, `--update`
refuses (exit 3) and prints the correct command:

```bash
npm install -g clean-bom-senior@latest
```

This keeps npm's integrity metadata (`package-lock`, `_resolved`, checksums)
consistent — a self-modified package under npm is a broken package.

## Mirrors and air-gapped networks

| Variable | Purpose |
|---|---|
| `CLEAN_BOM_UPDATE_URL` | Base URL serving `VERSION` and the script (`file://…` works in the bash implementation; the Node implementation needs `http(s)://`). Used by the test suites. |
| `CLEAN_BOM_GITHUB_REPO` | Alternative `owner/repo` slug (forks). |

Mirror layout must be:

```
<base>/VERSION                    -> "3.1.0\n"
<base>/clean-bom-senior.sh        (bash consumers)
<base>/bin/bom.js                 (node consumers)
```

## No telemetry

Nothing is ever fetched during normal runs. The network is touched **only**
by explicit `--check-update` / `--update`.

## CI guidance

- **Do not** run `--update` in CI: builds must be reproducible. Pin the
  version (npm: `clean-bom-senior@3.0.0`; shell: download a release tag and
  checksum it).
- A weekly "is there a new release?" job is the right pattern:

```yaml
- name: Update check (informational)
  run: |
    ./clean-bom-senior.sh --check-update || \
      echo "::notice::A new clean-bom-senior release is available"
```

## Release checklist (maintainers)

1. Bump `VERSION`, `clean-bom-senior.sh` (`VERSION=`), `bin/bom.js`
   (`const VERSION`), `package.json`, `CHANGELOG.md`.
2. `bash scripts/check-version-consistency.sh` must pass (CI enforces).
3. Tag `v<X.Y.Z>` and push — `--update` fetches tag assets first, so the tag
   must contain the final files.
4. `npm publish` (the package ships `VERSION`, both v3 implementations, the
   legacy ports, README, CHANGELOG, LICENSE).
