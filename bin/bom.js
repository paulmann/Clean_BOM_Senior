#!/usr/bin/env node
/**
 * clean-bom-senior — npm CLI entry point
 * Author: Mikhail Deynekin <mid1977@gmail.com> | https://deynekin.com
 * GitHub: https://github.com/paulmann/Clean_BOM_Senior
 */
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const scriptPath = path.resolve(__dirname, '..', 'clean-bom-senior.sh');

if (!fs.existsSync(scriptPath)) {
  console.error('[clean-bom-senior] ERROR: shell script not found at:', scriptPath);
  process.exit(1);
}

const args = process.argv.slice(2);

const result = spawnSync('bash', [scriptPath, ...args], {
  stdio: 'inherit',
  shell: false
});

if (result.error) {
  console.error('[clean-bom-senior] Failed to launch bash:', result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 0);
