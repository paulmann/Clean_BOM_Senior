#!/usr/bin/env node
'use strict';
/**
 * postinstall.js — make the bundled POSIX scripts executable after install.
 *
 * The npm CLI itself (bin/bom.js) is native Node.js and needs no preparation;
 * npm wires the bin entries. This hook only helps users who want to invoke the
 * bundled shell reference (clean-bom-senior.sh) directly from Git Bash / WSL /
 * POSIX after a global install. Failures are non-fatal by design: on Windows
 * the chmod bit is meaningless, and a read-only install must not break npm.
 *
 * Author: Mikhail Deynekin <mid1977@gmail.com> | https://deynekin.com
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const targets = ['clean-bom-senior.sh'];

let failed = 0;
for (const name of targets) {
  const file = path.join(root, name);
  try {
    if (fs.existsSync(file)) fs.chmodSync(file, 0o755);
  } catch (e) {
    failed += 1;
    if (process.env.npm_config_loglevel !== 'silent') {
      process.stderr.write(`[clean-bom-senior] note: could not chmod +x ${name}: ${e.message}\n`);
    }
  }
}
// Never fail the installation because of a cosmetic chmod.
process.exit(0);
