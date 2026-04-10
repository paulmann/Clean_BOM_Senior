/**
 * postinstall.js — ensure clean-bom-senior.sh is executable after npm install
 * Author: Mikhail Deynekin <mid1977@gmail.com> | https://deynekin.com
 */
'use strict';

const fs = require('fs');
const path = require('path');

const script = path.resolve(__dirname, '..', 'clean-bom-senior.sh');

try {
  fs.chmodSync(script, 0o755);
} catch (e) {
  // Non-fatal: warn only
  process.stderr.write('[clean-bom-senior] Warning: could not chmod +x the shell script: ' + e.message + '\n');
}
