#!/usr/bin/env node
'use strict';
/*=============================================================================
 * Clean BOM Senior — UTF-8 BOM & CRLF Cleaner with Smart BOM Policy
 * Native Node.js implementation (npm CLI: `bom` / `clean-bom-senior`)
 *=============================================================================
 *
 * Version:      3.0.0
 * Author:       Mikhail Deynekin <mid1977@gmail.com>
 * Website:      https://deynekin.com
 * Repository:   https://github.com/paulmann/Clean_BOM_Senior
 * License:      MIT
 *
 * This is a FULL native implementation of the v3 CLI contract — not a shell
 * wrapper. It runs everywhere Node runs (Linux, macOS, Windows, WSL) with no
 * bash/sed/od dependency, and it is byte-for-byte behaviour-compatible with
 * the reference implementation (clean-bom-senior.sh v3):
 *
 *   • Smart BOM Policy: UTF-16/32 files and NUL-binary files are NEVER
 *     touched; invalid UTF-8 is protected unless --force; a UTF-8 BOM in
 *     sensitive text (txt/csv/ps1…, non-ASCII content) is kept by default
 *     because Excel/legacy Notepad/Windows PowerShell 5.1 may require it;
 *     BOMs in code files (php/js/css/html/xml…) are stripped.
 *   • Byte-exact whole-file detection (no sampling windows).
 *   • Atomic same-directory replace with verification; hard links are
 *     rewritten in place; timestamps/permissions preserved by default.
 *   • Same flags, same exit codes (0/1/2/3/4/10/11), same log format,
 *     same --json schema. See docs/CLI-CONTRACT.md.
 *
 * Node >= 18 (global fetch for --update/--check-update).
 *===========================================================================*/

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

//-----------------------------------------------------------------------------
// Constants
//-----------------------------------------------------------------------------
const VERSION = '3.0.0';
const REPO_SLUG_DEFAULT = 'paulmann/Clean_BOM_Senior';
const SCRIPT_NAME = path.basename(process.argv[1] || 'bom');

const EXTENSIONS_DEFAULT = ['php', 'css', 'js', 'txt', 'xml', 'htm', 'html'];

// Extensions whose UTF-8 BOM may be REQUIRED by mainstream Windows consumers
// (Excel / legacy Notepad / csv readers; Windows PowerShell 5.1).
const SENSITIVE_DEFAULT = ['txt', 'csv', 'tsv', 'ps1', 'psm1', 'psd1'];

// Extensions where a UTF-8 BOM is known-harmful or useless.
const STRIP_ALWAYS = new Set(('php phtml phps inc php3 php4 php5 php7 php8 ' +
  'js mjs cjs jsx ts tsx vue json jsonc json5 ' +
  'css scss sass less htm html xhtml xml svg xsl xslt ' +
  'mustache hbs twig blade sh bash zsh fish py rb pl lua sql yaml yml toml').split(' '));

const EXCLUDE_DIRS_DEFAULT = ['.git', '.svn', '.hg', 'node_modules'];
const MAX_SIZE_DEFAULT = 100 * 1024 * 1024;

const EXIT_OK = 0;
const EXIT_FILE_ERRORS = 1;
const EXIT_USAGE = 2;
const EXIT_ENV = 3;
const EXIT_INTERNAL = 4;
const EXIT_CHECK_FOUND = 10;
const EXIT_UPDATE_AVAILABLE = 11;

//-----------------------------------------------------------------------------
// Runtime state
//-----------------------------------------------------------------------------
const O = {
  verbose: false,
  quiet: false,
  silent: false,
  dryRun: false,
  check: false,
  json: false,
  force: false,
  strict: false,
  help: false,
  helpTopic: '',
  version: false,
  completion: false,
  selfTest: false,
  checkUpdate: false,
  update: false,
  bomPolicy: 'auto',            // auto | strip | keep
  noBomClear: false,
  noCrlfNormalize: false,
  extensions: [...EXTENSIONS_DEFAULT],
  sensitiveExts: [...SENSITIVE_DEFAULT],
  excludePatterns: [],          // glob-ish patterns (see matchGlob)
  excludeDirs: [...EXCLUDE_DIRS_DEFAULT],
  userExcludeDirs: [],
  useDefaultExcludes: true,
  maxSize: MAX_SIZE_DEFAULT,
  gitMode: false,
  colorMode: 'auto',
  logFile: '',
  backup: false,
  backupDir: '',
  keepMtime: true,
  positional: [],
};

const C = {
  scanned: 0, changed: 0, wouldChange: 0, clean: 0,
  keptBom: 0, protectedUtf16: 0, protectedBinary: 0, protectedInvalid: 0,
  skippedSize: 0, bomRemoved: 0, crlfFixed: 0,
  errors: 0, errAccess: 0, errProcessing: 0, errOther: 0,
  fileErrors: false,
  startTime: Date.now(),
  startIso: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
  changedExts: [],
  affectedFiles: [],
  jsonEntries: [],
  tempFiles: [],
};

//-----------------------------------------------------------------------------
// Colors / logging (line format is the contract: [YYYY-MM-DD HH:MM:SS LEVEL])
//-----------------------------------------------------------------------------
let COL = { red: '', green: '', yellow: '', blue: '', magenta: '', cyan: '', reset: '' };

function colorInit() {
  let use = false;
  if (O.colorMode === 'always') use = true;
  else if (O.colorMode === 'never') use = false;
  else {
    if (process.env.NO_COLOR !== undefined && process.env.NO_COLOR !== '') use = false;
    else if (process.env.CLICOLOR_FORCE && process.env.CLICOLOR_FORCE !== '0') use = true;
    else use = Boolean(process.stderr.isTTY);
  }
  if (use) {
    COL = {
      red: '\x1b[0;31m', green: '\x1b[0;32m', yellow: '\x1b[1;33m',
      blue: '\x1b[0;34m', magenta: '\x1b[0;35m', cyan: '\x1b[0;36m',
      reset: '\x1b[0m',
    };
  }
}

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
         `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function logRaw(color, level, msg) {
  if (O.silent && level !== 'ERROR') return;
  process.stderr.write(`${color}[${timestamp()} ${level}]${COL.reset} ${msg}\n`);
  if (O.logFile) {
    try {
      fs.appendFileSync(O.logFile, `[${timestamp()} ${level}] ${msg}\n`);
    } catch { /* the log file must never break a run */ }
  }
}

const logInfo = (m) => { if (!O.quiet) logRaw(COL.blue, 'INFO', m); };
const logWarn = (m) => logRaw(COL.yellow, 'WARN', m);
function logError(m) { logRaw(COL.red, 'ERROR', m); C.errors += 1; }
const logSuccess = (m) => { if (O.verbose) logRaw(COL.green, 'SUCCESS', m); };
const logProcessing = (m) => { if (O.verbose) logRaw(COL.cyan, 'PROCESSING', m); };

function cleanup(code) {
  for (const t of C.tempFiles) {
    try { fs.rmSync(t, { force: true }); } catch { /* best effort */ }
  }
  process.exit(code);
}

function dieUsage(msg) {
  logError(msg);
  process.stderr.write(`Try "${SCRIPT_NAME} --help" for more information.\n`);
  cleanup(EXIT_USAGE);
}

function dieEnv(msg) { logError(msg); cleanup(EXIT_ENV); }
function dieInternal(msg) { logError(msg); cleanup(EXIT_INTERNAL); }

process.on('SIGINT', () => cleanup(130));
process.on('SIGTERM', () => cleanup(143));

//-----------------------------------------------------------------------------
// Byte-level encoding utilities
//-----------------------------------------------------------------------------

/** Classify the BOM from the first 4 bytes. UTF-32LE is tested before
 *  UTF-16LE because FF FE 00 00 extends FF FE. */
function classifyBom(buf) {
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) return 'utf8-bom';
  if (buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xfe && buf[2] === 0x00 && buf[3] === 0x00) return 'utf32le';
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) return 'utf16le';
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) return 'utf16be';
  if (buf.length >= 4 && buf[0] === 0x00 && buf[1] === 0x00 && buf[2] === 0xfe && buf[3] === 0xff) return 'utf32be';
  return 'none';
}

/** Strict UTF-8 validator (rejects overlongs, surrogates, > U+10FFFF).
 *  Mirrors `iconv -f UTF-8 -t UTF-8` used by the shell reference. */
function isValidUtf8(buf) {
  const n = buf.length;
  let i = 0;
  while (i < n) {
    const b = buf[i];
    let extra;
    if (b <= 0x7f) extra = 0;
    else if (b >= 0xc2 && b <= 0xdf) extra = 1;
    else if (b >= 0xe0 && b <= 0xef) extra = 2;
    else if (b >= 0xf0 && b <= 0xf4) extra = 3;
    else return false;
    if (i + extra >= n) return false; // truncated multi-byte sequence
    if (extra >= 1) {
      const lo = b === 0xe0 ? 0xa0 : b === 0xf0 ? 0x90 : 0x80;
      const hi = b === 0xed ? 0x9f : b === 0xf4 ? 0x8f : 0xbf;
      if (buf[i + 1] < lo || buf[i + 1] > hi) return false;
      for (let k = 2; k <= extra; k++) {
        if (buf[i + k] < 0x80 || buf[i + k] > 0xbf) return false;
      }
    }
    i += extra + 1;
  }
  return true;
}

/** True when the buffer contains at least one REAL CRLF pair (0x0D 0x0A).
 *  A CR as the very last byte (EOF, no LF after it) is NOT a CRLF and never
 *  flags the file — CR-only "old Mac" files stay untouched. */
function hasCrlf(buf) {
  let idx = buf.indexOf(0x0d);
  while (idx !== -1) {
    if (idx + 1 < buf.length && buf[idx + 1] === 0x0a) return true;
    idx = buf.indexOf(0x0d, idx + 1);
  }
  return false;
}

function hasNul(buf) { return buf.indexOf(0x00) !== -1; }

/** Non-ASCII bytes present AFTER a leading UTF-8 BOM (if any). */
function hasNonAscii(buf, enc) {
  const start = enc === 'utf8-bom' ? 3 : 0;
  for (let i = start; i < buf.length; i++) if (buf[i] > 0x7f) return true;
  return false;
}

/** Build the cleaned content: byte-exact BOM strip + CRLF→LF.
 *  When a file IS rewritten for CRLF, a trailing CR at EOF is removed too
 *  (sed `s/\r$//` semantics — the documented v2 contract, AGENTS inv. 7). */
function buildCleanContent(buf, stripBom, fixCrlf) {
  let out = stripBom ? buf.subarray(3) : buf;
  if (!fixCrlf) return Buffer.from(out);
  const parts = [];
  let start = 0;
  for (let i = 0; i < out.length; i++) {
    if (out[i] !== 0x0d) continue;
    const beforeLf = i + 1 < out.length && out[i + 1] === 0x0a;
    const atEof = i === out.length - 1;
    if (beforeLf || atEof) {
      parts.push(out.subarray(start, i));
      start = i + 1;
    }
  }
  if (parts.length === 0) return Buffer.from(out);
  parts.push(out.subarray(start));
  return Buffer.concat(parts);
}

function getExtension(p) {
  const base = path.basename(p);
  const dot = base.lastIndexOf('.');
  if (dot <= 0 || dot === base.length - 1) return '';
  return base.slice(dot + 1).toLowerCase();
}

function extClass(ext) {
  if (O.sensitiveExts.length > 0 && O.sensitiveExts.includes(ext)) return 'sensitive';
  if (STRIP_ALWAYS.has(ext)) return 'strip';
  return 'unknown';
}

// Unknown extensions behave as sensitive WHILE a sensitive list exists;
// --sensitive-ext '' disables sensitivity entirely.
function classIsSensitive(cls) {
  if (cls === 'sensitive') return true;
  if (cls === 'unknown') return O.sensitiveExts.length > 0;
  return false;
}

//-----------------------------------------------------------------------------
// Analysis + policy engine (mirrors analyze_file/plan_file of the reference)
//-----------------------------------------------------------------------------
function analyzeFile(realPath) {
  const A = {
    enc: 'none', hasCrlf: false, binary: false, validUtf8: true,
    nonAscii: false, candidate: false, oversize: false,
    size: 0, ext: '', extClass: 'unknown', buf: null,
  };
  let st;
  try { st = fs.statSync(realPath); } catch { return A; }
  A.size = st.size;
  if (A.size > O.maxSize) { A.oversize = true; return A; }
  A.ext = getExtension(realPath);
  A.extClass = extClass(A.ext);

  // The file is size-capped by --max-size; read it whole so every check
  // (magic, CRLF, NUL, UTF-8 validity, non-ASCII) is byte-exact over ALL
  // bytes — no sampling windows, none of the v2 false negatives.
  let buf;
  try {
    buf = fs.readFileSync(realPath);
  } catch {
    return A; // unreadable — handleFile reports it
  }
  A.buf = buf;
  A.enc = classifyBom(buf);

  const bomActionable = A.enc === 'utf8-bom' && !O.noBomClear;
  const crlfActionable = !O.noCrlfNormalize;

  if (A.enc === 'utf16le' || A.enc === 'utf16be' || A.enc === 'utf32le' || A.enc === 'utf32be') {
    // UTF-16/32: candidate ONLY if a real CRLF match would make a naive tool
    // rewrite it — then it must be protected. Otherwise silently clean.
    if (crlfActionable && hasCrlf(buf)) { A.hasCrlf = true; A.candidate = true; }
    return A;
  }
  if (!bomActionable && !crlfActionable) return A;
  if (crlfActionable && hasCrlf(buf)) A.hasCrlf = true;
  if (!bomActionable && !A.hasCrlf) return A;
  A.candidate = true;

  // Deep safety checks run ONLY for modification candidates.
  if (hasNul(buf)) { A.binary = true; return A; }
  if (!isValidUtf8(buf)) { A.validUtf8 = false; return A; }
  if (bomActionable && classIsSensitive(A.extClass)) A.nonAscii = hasNonAscii(buf, A.enc);
  return A;
}

function planFile(A) {
  const P = { stripBom: false, fixCrlf: false, bomKept: false, status: 'clean', reason: '' };
  if (A.oversize) { P.status = 'skip-size'; P.reason = `larger than --max-size (${fmtSize(O.maxSize)})`; return P; }
  if (!A.candidate) return P;

  // Hard refusals — never modified, not even under --force.
  if (A.enc === 'utf16le' || A.enc === 'utf16be' || A.enc === 'utf32le' || A.enc === 'utf32be') {
    P.status = 'protect'; P.reason = `bom-required-${A.enc}`; return P;
  }
  if (A.binary) { P.status = 'protect'; P.reason = 'binary-nul-bytes'; return P; }
  if (!A.validUtf8 && !O.force) { P.status = 'protect'; P.reason = 'invalid-utf8'; return P; }

  // BOM action
  if (A.enc === 'utf8-bom' && !O.noBomClear) {
    if (O.bomPolicy === 'keep') { P.bomKept = true; P.reason = 'bom-policy-keep'; }
    else if (O.bomPolicy === 'strip') { P.stripBom = true; }
    else if (O.force) { P.stripBom = true; }
    else if (classIsSensitive(A.extClass) && A.nonAscii) {
      P.bomKept = true; P.reason = 'bom-may-be-required';
    } else { P.stripBom = true; }
  }
  // CRLF action
  if (A.hasCrlf && !O.noCrlfNormalize) P.fixCrlf = true;

  if (P.stripBom || P.fixCrlf) P.status = 'change';
  else if (P.bomKept) P.status = 'keep';
  else if (!A.validUtf8 && !O.force) { P.status = 'protect'; P.reason = 'invalid-utf8'; }
  return P;
}

function fmtSize(b) {
  if (b >= 1073741824 && b % 1073741824 === 0) return `${b / 1073741824}G`;
  if (b >= 1048576 && b % 1048576 === 0) return `${b / 1048576}M`;
  if (b >= 1024 && b % 1024 === 0) return `${b / 1024}K`;
  return `${b}B`;
}

//-----------------------------------------------------------------------------
// JSON report (schema identical to the shell reference — docs/CLI-CONTRACT.md)
//-----------------------------------------------------------------------------
function jsonAddEntry(entry) { C.jsonEntries.push(entry); }

function jsonReport() {
  const mode = O.check ? 'check' : O.dryRun ? 'dry-run' : 'fix';
  const out = {
    tool: 'clean-bom-senior',
    version: VERSION,
    mode,
    startedAt: C.startIso,
    durationSeconds: Math.floor((Date.now() - C.startTime) / 1000),
    cwd: process.cwd(),
    options: {
      bomPolicy: O.bomPolicy,
      noBomClear: O.noBomClear,
      noCrlfNormalize: O.noCrlfNormalize,
      force: O.force,
      extensions: O.extensions.join(' '),
      sensitiveExtensions: O.sensitiveExts.join(' '),
      maxSizeBytes: O.maxSize,
      keepMtime: O.keepMtime,
    },
    summary: {
      scanned: C.scanned, changed: C.changed, wouldChange: C.wouldChange,
      clean: C.clean, bomKept: C.keptBom, bomRemoved: C.bomRemoved,
      crlfFixed: C.crlfFixed, protectedUtf16or32: C.protectedUtf16,
      protectedBinary: C.protectedBinary, protectedInvalidUtf8: C.protectedInvalid,
      skippedOversize: C.skippedSize, errors: C.errors,
    },
    files: C.jsonEntries,
  };
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
}

//-----------------------------------------------------------------------------
// Transformation (atomic, verified, attribute-preserving, hardlink-aware)
//-----------------------------------------------------------------------------
function displayPath(p) {
  // Contract: recursive walks print './x' style paths with forward slashes.
  return p.split(path.sep).join('/');
}

function makeTempInDir(dir) {
  const name = `.cleanbom.${process.pid}.${Math.random().toString(36).slice(2, 8)}`;
  return path.join(dir, name);
}

function makeBackupCopy(disp, realPath) {
  try {
    let dest;
    if (O.backupDir) {
      const rel = disp.replace(/^\.\//, '');
      dest = path.join(O.backupDir, rel.split('/').join(path.sep));
      fs.mkdirSync(path.dirname(dest), { recursive: true });
    } else {
      dest = `${realPath}.bak.${process.pid}`;
    }
    fs.copyFileSync(realPath, dest);
    logProcessing(`Backup saved: ${dest}`);
  } catch {
    logWarn(`Could not create backup for: ${disp} (continuing without it)`);
  }
}

function writeFileInPlace(realPath, content, origStat) {
  // Preserves the inode (hard links stay linked). Keeps a rollback buffer.
  const rollback = fs.readFileSync(realPath);
  try {
    fs.writeFileSync(realPath, content);
    if (O.keepMtime) fs.utimesSync(realPath, origStat.atime, origStat.mtime);
    return true;
  } catch {
    try { fs.writeFileSync(realPath, rollback); } catch { /* last resort */ }
    return false;
  }
}

function transformFile(disp, realPath, content, origStat) {
  const dir = path.dirname(realPath);
  let temp = null;
  try {
    temp = makeTempInDir(dir);
    fs.writeFileSync(temp, content, { mode: origStat.mode & 0o7777, flag: 'wx' });
    C.tempFiles.push(temp);
  } catch {
    // Directory not writable — guarded in-place fallback.
    temp = null;
    try { fs.accessSync(realPath, fs.constants.W_OK); } catch {
      logError(`Cannot create temp file next to: ${disp} (directory not writable)`);
      C.errAccess += 1;
      return false;
    }
    logWarn(`Directory not writable, rewriting in place (non-atomic): ${disp}`);
    if (O.backup) makeBackupCopy(disp, realPath);
    if (writeFileInPlace(realPath, content, origStat)) return true;
    logError(`In-place rewrite failed (original restored): ${disp}`);
    C.errProcessing += 1;
    return false;
  }

  if (O.backup) makeBackupCopy(disp, realPath);

  try {
    // Permissions / owner / timestamps on the temp file BEFORE the rename.
    try { fs.chmodSync(temp, origStat.mode & 0o7777); } catch { /* windows */ }
    if (typeof process.getuid === 'function' && process.getuid() === 0) {
      try { fs.chownSync(temp, origStat.uid, origStat.gid); } catch { /* best effort */ }
    }
    if (O.keepMtime) {
      try { fs.utimesSync(temp, origStat.atime, origStat.mtime); } catch { /* best effort */ }
    }

    let st;
    try { st = fs.statSync(realPath); } catch { st = origStat; }
    if (st.nlink > 1) {
      logWarn(`File has ${st.nlink} hard links — rewriting in place to keep them intact: ${disp}`);
      fs.rmSync(temp, { force: true });
      if (writeFileInPlace(realPath, content, origStat)) return true;
      logError(`In-place rewrite failed (original restored): ${disp}`);
      C.errProcessing += 1;
      return false;
    }

    fs.renameSync(temp, realPath);
    C.tempFiles = C.tempFiles.filter((t) => t !== temp);
    return true;
  } catch {
    // Atomic rename failed: guarded in-place retry, then give up.
    try {
      fs.accessSync(realPath, fs.constants.W_OK);
      logWarn(`Atomic replace failed, retrying in place: ${disp}`);
      fs.rmSync(temp, { force: true });
      if (writeFileInPlace(realPath, content, origStat)) return true;
    } catch { /* fall through */ }
    logError(`Failed to replace file (original untouched): ${disp}`);
    C.errProcessing += 1;
    try { fs.rmSync(temp, { force: true }); } catch { /* ignore */ }
    return false;
  }
}

//-----------------------------------------------------------------------------
// Per-file driver
//-----------------------------------------------------------------------------
function handleFile(disp, realPath) {
  C.scanned += 1;

  let st;
  try { st = fs.statSync(realPath); } catch {
    logError(`File not found: ${disp}`);
    C.errAccess += 1;
    return false;
  }
  if (!st.isFile()) {
    logError(`File not found: ${disp}`);
    C.errAccess += 1;
    return false;
  }
  try { fs.accessSync(realPath, fs.constants.R_OK); } catch {
    logError(`Cannot read file: ${disp}`);
    C.errAccess += 1;
    return false;
  }

  const A = analyzeFile(realPath);
  const P = planFile(A);

  switch (P.status) {
    case 'clean':
      C.clean += 1;
      logProcessing(`No issues detected, skipping: ${disp}`);
      return true;
    case 'skip-size':
      C.skippedSize += 1;
      logInfo(`Skipped (oversize, ${fmtSize(A.size)} > ${fmtSize(O.maxSize)}): ${disp}`);
      jsonAddEntry({ path: disp, status: 'skipped-size', encoding: A.enc, actions: [], bomKept: false, reason: P.reason });
      return true;
    case 'protect':
      if (P.reason.startsWith('bom-required-')) {
        C.protectedUtf16 += 1;
        logWarn(`NOT touched — ${A.enc} BOM is structurally required; stripping it would corrupt the file (convert with iconv if UTF-8 is needed): ${disp}`);
      } else if (P.reason === 'binary-nul-bytes') {
        C.protectedBinary += 1;
        logWarn(`NOT touched — contains NUL bytes (binary data or BOM-less UTF-16): ${disp}`);
      } else if (P.reason === 'invalid-utf8') {
        C.protectedInvalid += 1;
        logWarn(`NOT touched — content is not valid UTF-8; pass --force for byte-level cleaning: ${disp}`);
      }
      jsonAddEntry({ path: disp, status: 'protected', encoding: A.enc, actions: [], bomKept: false, reason: P.reason });
      return true;
    case 'keep':
      C.keptBom += 1;
      logInfo(`BOM kept (may be required for .${A.ext} with non-ASCII content; --force strips it): ${disp}`);
      jsonAddEntry({ path: disp, status: 'kept', encoding: A.enc, actions: [], bomKept: true, reason: P.reason });
      return true;
    default: break;
  }

  // status === 'change'
  const actions = [];
  if (P.stripBom) actions.push('strip-bom');
  if (P.fixCrlf) actions.push('crlf-to-lf');

  if (O.dryRun || O.check) {
    C.wouldChange += 1;
    if (P.bomKept) C.keptBom += 1;
    C.affectedFiles.push(disp);
    if (O.verbose) {
      process.stderr.write(`Would process: ${disp} (actions: ${actions.join(' + ')}; encoding: ${A.enc}` +
        `${P.bomKept ? '; BOM kept: may be required' : ''})\n`);
    }
    jsonAddEntry({ path: disp, status: 'would-change', encoding: A.enc, actions, bomKept: P.bomKept, reason: P.reason || null });
    return true;
  }

  logProcessing(`Processing: ${disp} (actions: ${actions.join(' + ')}, encoding: ${A.enc})`);
  if (!A.validUtf8) logWarn(`--force: byte-level cleaning of invalid-UTF-8 file: ${disp}`);

  const content = buildCleanContent(A.buf, P.stripBom, P.fixCrlf);

  // Defence in depth: verify the produced bytes satisfy the plan.
  if (P.stripBom && classifyBom(content) === 'utf8-bom') {
    logError(`Verification failed after cleaning (file NOT modified): ${disp}`);
    C.errProcessing += 1;
    jsonAddEntry({ path: disp, status: 'error', encoding: A.enc, actions, bomKept: P.bomKept, reason: 'transform-failed' });
    return false;
  }
  if (P.fixCrlf && hasCrlf(content)) {
    logError(`Verification failed after cleaning (file NOT modified): ${disp}`);
    C.errProcessing += 1;
    jsonAddEntry({ path: disp, status: 'error', encoding: A.enc, actions, bomKept: P.bomKept, reason: 'transform-failed' });
    return false;
  }

  if (transformFile(disp, realPath, content, st)) {
    C.changed += 1;
    if (P.stripBom) C.bomRemoved += 1;
    if (P.fixCrlf) C.crlfFixed += 1;
    if (P.bomKept) {
      C.keptBom += 1;
      logInfo(`BOM kept (may be required for .${A.ext}); CRLF normalised: ${disp}`);
    }
    C.changedExts.push(A.ext || 'other');
    C.affectedFiles.push(disp);
    jsonAddEntry({ path: disp, status: 'changed', encoding: A.enc, actions, bomKept: P.bomKept, reason: P.reason || null });
    logSuccess(`Successfully processed: ${disp} (${actions.join(' + ')})`);
    return true;
  }
  jsonAddEntry({ path: disp, status: 'error', encoding: A.enc, actions, bomKept: P.bomKept, reason: 'transform-failed' });
  return false;
}

//-----------------------------------------------------------------------------
// Selection: exclusions, walking, git mode
//-----------------------------------------------------------------------------

// Glob subset: '*' (any run incl. '/'), '?' (one char), character classes.
function matchGlob(pattern, str) {
  let pi = 0; let si = 0;
  let starP = -1; let starS = -1;
  while (si < str.length) {
    const pc = pattern[pi];
    if (pc === '*') { starP = pi; starS = si; pi += 1; continue; }
    if (pi < pattern.length && (pc === '?' || pc === str[si])) { pi += 1; si += 1; continue; }
    if (pc === '[') {
      const close = pattern.indexOf(']', pi + 1);
      if (close > pi) {
        const set = pattern.slice(pi + 1, close);
        const negate = set.startsWith('!');
        const body = negate ? set.slice(1) : set;
        let hit = false;
        for (let k = 0; k < body.length; k++) {
          if (body[k + 1] === '-' && body[k + 2] !== undefined) {
            if (str[si] >= body[k] && str[si] <= body[k + 2]) hit = true;
            k += 2;
          } else if (body[k] === str[si]) hit = true;
        }
        if (hit !== negate) { pi = close + 1; si += 1; continue; }
      }
    }
    if (starP !== -1) { pi = starP + 1; starS += 1; si = starS; continue; }
    return false;
  }
  while (pi < pattern.length && pattern[pi] === '*') pi += 1;
  return pi === pattern.length;
}

function pathExcluded(relPosix) {
  const bare = relPosix.replace(/^\.\//, '');
  for (const pat of O.excludePatterns) {
    if (matchGlob(pat, relPosix) || matchGlob(pat, bare)) return true;
  }
  const segments = bare.split('/');
  for (const d of O.excludeDirs) {
    if (segments.slice(0, -1).includes(d)) return true;
  }
  return false;
}

function walkDirectory(rootDir, rootDisplay) {
  // rootDisplay always ends with '/' ('./' for the cwd scan) so displayed
  // paths match the reference contract: './a.php', 'src/deep/b.php'.
  let entries;
  try {
    entries = fs.readdirSync(rootDir, { withFileTypes: true });
  } catch {
    logError(`Cannot read directory: ${rootDisplay}`);
    C.errAccess += 1;
    C.fileErrors = true;
    return;
  }
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const ent of entries) {
    const full = path.join(rootDir, ent.name);
    const disp = rootDisplay + ent.name;
    if (ent.isSymbolicLink()) continue; // never follow symlinks in the walk
    if (ent.isDirectory()) {
      if (O.excludeDirs.includes(ent.name)) continue;
      if (pathExcluded(`${disp}/`)) continue;
      walkDirectory(full, `${disp}/`);
      continue;
    }
    if (!ent.isFile()) continue;
    if (!O.extensions.includes(getExtension(ent.name))) continue;
    let st = null;
    try { st = fs.statSync(full); } catch { continue; }
    if (st.size === 0) continue; // empty files cannot carry BOM/CRLF
    if (pathExcluded(disp)) continue;
    if (!handleFile(disp, full)) C.fileErrors = true;
  }
}

function scanGitTracked() {
  const args = ['ls-files', '-z', '--'];
  if (O.positional.length > 0) args.push(...O.positional);
  const res = spawnSync('git', args, { encoding: 'buffer', maxBuffer: 512 * 1024 * 1024 });
  if (res.error) dieEnv('--git requires git(1) in PATH');
  if (res.status !== 0) dieEnv('--git: current directory is not inside a git work tree');
  logInfo('Git mode: processing tracked files only');
  const files = res.stdout.toString('utf8').split('\0').filter(Boolean).sort();
  for (const f of files) {
    if (!O.extensions.includes(getExtension(f))) continue;
    const disp = displayPath(f);
    if (pathExcluded(disp)) continue;
    let st = null;
    try { st = fs.statSync(f); } catch { continue; }
    if (!st.isFile() || st.size === 0) continue;
    if (!handleFile(disp, f)) C.fileErrors = true;
  }
}

//-----------------------------------------------------------------------------
// Reports (labels identical to the shell reference)
//-----------------------------------------------------------------------------
function displayStatistics() {
  const w = (s) => process.stderr.write(s);
  const elapsed = Math.floor((Date.now() - C.startTime) / 1000);
  w(`\n${COL.magenta}=== PROCESSING SUMMARY ===${COL.reset}\n`);
  w(`Execution time: ${elapsed} seconds\n`);
  w(`Files scanned: ${C.scanned}\n`);
  if (O.dryRun || O.check) w(`Files that would be processed: ${C.wouldChange}\n`);
  else w(`Files processed: ${C.changed}\n`);
  w(`Files skipped (clean): ${C.clean}\n`);
  w(`Errors encountered: ${C.errors}\n`);

  if (C.changed > 0) {
    w(`\n${COL.cyan}--- Issues Fixed ---${COL.reset}\n`);
    w(`BOM signatures removed: ${C.bomRemoved}\n`);
    w(`CRLF line endings fixed: ${C.crlfFixed}\n`);
    w(`\n${COL.cyan}--- File Type Distribution ---${COL.reset}\n`);
    const counts = new Map();
    for (const e of C.changedExts) counts.set(e, (counts.get(e) || 0) + 1);
    for (const [ext, n] of [...counts.entries()].sort()) {
      if (ext === 'other' || ext === '') w(`Other files: ${n}\n`);
      else w(`.${ext} files: ${n}\n`);
    }
  }

  const keptTotal = C.keptBom + C.protectedUtf16 + C.protectedBinary + C.protectedInvalid + C.skippedSize;
  if (keptTotal > 0) {
    w(`\n${COL.yellow}--- Protected / Kept Unchanged (Smart BOM Policy) ---${COL.reset}\n`);
    if (C.keptBom > 0) w(`UTF-8 BOM kept (may be required): ${C.keptBom}\n`);
    if (C.protectedUtf16 > 0) w(`UTF-16/UTF-32 files (BOM required): ${C.protectedUtf16}\n`);
    if (C.protectedBinary > 0) w(`Binary files (NUL bytes): ${C.protectedBinary}\n`);
    if (C.protectedInvalid > 0) w(`Invalid UTF-8 files: ${C.protectedInvalid}\n`);
    if (C.skippedSize > 0) w(`Oversize files skipped: ${C.skippedSize}\n`);
  }

  if (C.errors > 0) {
    w(`\n${COL.red}--- Error Breakdown ---${COL.reset}\n`);
    w(`Access errors: ${C.errAccess}\n`);
    w(`Processing errors: ${C.errProcessing}\n`);
    w(`Other errors: ${C.errOther}\n`);
  }

  if ((O.dryRun || O.check) && C.wouldChange > 0) {
    w(`\n${COL.yellow}--- Files That Would Be Processed ---${COL.reset}\n`);
    for (const f of C.affectedFiles) w(`${f}\n`);
  }
  w(`\n${COL.green}Processing completed at: ${timestamp()}${COL.reset}\n`);
}

function showGreeting() {
  const w = (s) => process.stderr.write(s);
  w(`\n${COL.magenta}=== UTF-8 BOM & CRLF Cleaner v${VERSION} (Node.js) ===${COL.reset}\n`);
  w(`${COL.blue}Author:${COL.reset} Mikhail Deynekin (mid1977@gmail.com)\n`);
  w(`${COL.blue}Website:${COL.reset} https://deynekin.com\n`);
  w(`${COL.blue}Started:${COL.reset} ${timestamp()}\n`);
  w(`\n${COL.cyan}--- Configuration ---${COL.reset}\n`);
  w(`Verbose mode: ${O.verbose ? 'ENABLED' : 'DISABLED'}\n`);
  if (O.check) w('Check mode: ENABLED (no files will be modified)\n');
  else if (O.dryRun) w('Dry-run mode: ENABLED (no files will be modified)\n');
  w(`BOM removal: ${O.noBomClear ? 'DISABLED' : 'ENABLED'}\n`);
  w(`CRLF normalization: ${O.noCrlfNormalize ? 'DISABLED' : 'ENABLED'}\n`);
  w(O.bomPolicy === 'auto'
    ? 'BOM policy: auto (smart: keep BOM where it may be required)\n'
    : `BOM policy: ${O.bomPolicy}\n`);
  w(`Force mode: ${O.force ? 'ENABLED' : 'DISABLED'}\n`);
  w(`Timestamps of modified files: ${O.keepMtime ? 'PRESERVED' : 'UPDATED'}\n`);
  w(`Supported extensions: ${O.extensions.join(' ')}\n`);
  w(`Maximum file size: ${fmtSize(O.maxSize)}\n`);
  if (O.excludeDirs.length > 0) w(`Excluded directories: ${O.excludeDirs.join(' ')}\n`);
  w(`\n${COL.green}Starting file processing...${COL.reset}\n\n`);
}

//-----------------------------------------------------------------------------
// Help (same topics and content as the reference; name adapted)
//-----------------------------------------------------------------------------
const HELP_TOPICS = 'usage options bom-policy safety exit-codes examples env ci update files json compatibility';

function helpText(topic) {
  const N = SCRIPT_NAME;
  const common = {
    usage: `USAGE
    ${N} [OPTIONS] [PATH...]

    PATH may be a file or a directory (directories are scanned recursively).
    With no PATH, the current directory is scanned recursively.
    Default exclusions: .git, .svn, .hg, node_modules (--no-default-excludes
    to lift them; --exclude / --exclude-dir to add your own).

QUICK START
    ${N}                     clean the current tree (smart, safe defaults)
    ${N} --check             CI gate: exit 10 when anything needs cleaning
    ${N} --dry-run           preview: what would change, and why
    ${N} --json              machine-readable report on stdout
    ${N} src index.php       clean a directory and a file
    ${N} --help bom-policy   the Smart BOM Policy in detail
`,
    options: `OPTIONS
  Operation
    -n, --dry-run            Analyse and report, modify nothing (implies -v)
    -c, --check              CI gate: like --dry-run but terse; exit 10 if any
                             file needs cleaning, 0 if the tree is clean
    -f, --fix                Clean (the default mode; exists for explicitness)
    -v, --verbose            Per-file processing log
    -q, --quiet              No greeting/summary; warnings and errors only
        --silent             Errors only
    -j, --json               JSON report on stdout (schema: --help json)
        --color WHEN         auto | always | never (honours NO_COLOR,
                             CLICOLOR_FORCE)
        --no-color           Alias for --color=never
        --log-file FILE      Append the full log to FILE

  Selection
        --ext LIST           Comma-separated extensions REPLACING the defaults
                             (default: php,css,js,txt,xml,htm,html)
        --add-ext LIST       Comma-separated extensions ADDED to the defaults
        --exclude GLOB       Repeatable; skip paths matching GLOB
                             (e.g. --exclude 'dist/*' --exclude '*/vendor/*')
        --exclude-dir NAME   Repeatable; never descend into directory NAME
        --no-default-excludes  Descend into .git/.svn/.hg/node_modules too
        --max-size SPEC      Skip files larger than SPEC (default 100M;
                             accepts 512K, 10M, 1G, or a byte count)
        --git                Process only git-tracked files (needs git; PATH
                             arguments become git pathspecs)

  Smart BOM Policy (the safety core — details: --help bom-policy)
        --bom-policy POL     auto (default) | strip | keep
        --sensitive-ext LIST Comma-separated; extensions whose UTF-8 BOM may be
                             required (default: txt,csv,tsv,ps1,psm1,psd1;
                             an empty list disables sensitivity)
        --force              Strip "may-be-required" BOMs anyway and clean
                             invalid-UTF-8 files at byte level. NEVER
                             overrides hard refusals (UTF-16/32, NUL-binary).

  Transformation
        --no-bom-clear       Do not remove any BOM (v2 compatible)
        --no-rn-normalize    Do not normalise CRLF (v2 compatible name)
        --no-crlf-normalize  Same flag, clearer name
        --update-mtime       Set a fresh mtime on modified files (default:
        --no-keep-mtime      original timestamps are preserved)
        --backup             Keep a backup of every modified file
                             (<file>.bak.<pid> next to the original)
        --backup-dir DIR     Implies --backup; copies mirror the tree in DIR

  Information / maintenance
    -h, --help               Full help; --help TOPIC for one section
        --help TOPIC         Topics: ${HELP_TOPICS}
    -V, --version            Version information
        --check-update       Query the repository; exit 11 if a newer version
                             exists, 0 if up to date
        --update             Self-update (npm-managed installs are refused
                             with instructions — use npm itself)
        --self-test          Run the built-in fixture test-suite and report
        --completion         Print a bash completion script
        --strict             Exit 1 if anything was kept/protected/skipped
                             (CI gate for "the tree is fully cleanable")
    --                       End of options (paths may start with '-')
`,
    'bom-policy': `SMART BOM POLICY — "does this file actually NEED cleaning, and is its BOM
perhaps load-bearing?"   (full rationale: docs/SMART-BOM.md)

Before touching a file, v3 classifies it by its actual bytes and answers two
questions: (1) is cleaning needed at all? (2) is the BOM safe to remove?

DECISION TABLE (top-down, first match wins)
  1. Oversize (> --max-size)
       → skipped, counted separately, never read in full.
  2. UTF-16/UTF-32 BOM (FF FE, FE FF, FF FE 00 00, 00 00 FE FF)
       → NEVER TOUCHED. For these encodings the BOM is part of the format:
         removing it makes the file unreadable or misinterpreted, and byte-
         level CRLF tools would corrupt UTF-16 content. Such a file is only
         reported when something (a CRLF match) would otherwise have made the
         tool rewrite it. Convert to UTF-8 deliberately if you need to.
  3. NUL bytes anywhere in the file
       → NEVER TOUCHED (binary data, or UTF-16 without BOM). Reported as
         "binary-nul-bytes".
  4. Content is not valid UTF-8
       → NOT TOUCHED by default (the file is not what its BOM/extension
         claims; rewriting could destroy data). Reported as "invalid-utf8".
         --force enables byte-level cleaning: BOM-strip and CRLF→LF are safe
         byte operations for ASCII-compatible encodings (cp1251, latin-1…).
  5. UTF-8 BOM present, extension is SENSITIVE (default: txt csv tsv ps1 psm1
     psd1 — plus any extension not in the known-code table), and the content
     after the BOM is NON-ASCII
       → BOM KEPT by default, with an explanation. Rationale: Excel and legacy
         Windows Notepad render BOM-less UTF-8 as ANSI (mojibake); Windows
         PowerShell 5.1 parses BOM-less non-ASCII .ps1 as ANSI (broken
         scripts). Here the BOM is a feature, not dirt.
         Strip anyway with --force or --bom-policy=strip.
         CRLF in the same file IS still normalised (the BOM stays intact).
  6. UTF-8 BOM present; extension is code (php js css html xml …) or the
     content is pure ASCII
       → BOM REMOVED. In PHP a BOM is outright harmful (breaks header(),
         causes "headers already sent", interferes with declare/namespace in
         edge cases); for a pure-ASCII file the BOM carries zero information,
         so removal is lossless for every consumer, Excel and Notepad
         included.
  7. No BOM, no CRLF
       → File is CLEAN: not rewritten at all — inode, timestamps and hard
         links stay byte-for-byte intact.

OVERRIDES
  --bom-policy=strip   strip every UTF-8 BOM (still never UTF-16/32 or binary)
  --bom-policy=keep    never strip any BOM (CRLF is still normalised)
  --force              = strip policy + byte-level cleaning of invalid UTF-8
  --sensitive-ext LST  redefine the sensitive set ("" disables sensitivity)
  --no-bom-clear       v2-compatible global BOM switch-off

Every keep/protect decision is logged with its reason and appears in --json
("status": "kept"|"protected", "reason": …). Nothing is ever modified
silently, and files that need no modification are never rewritten.
`,
    safety: `SAFETY GUARANTEES
  • Atomic replace: cleaned content is verified (BOM gone / CRLF gone), written
    to a temp file in the SAME directory, then rename(2)d over the original.
    A crash mid-way can never leave a half-written file.
  • Hard links: detected (nlink > 1) and rewritten IN PLACE through the inode,
    so linked copies stay linked. A warning is logged.
  • Symlink arguments are resolved to their targets; the recursive walk never
    follows symlinks (files or directories).
  • Permissions are transferred to the new inode; ownership too when running
    as root on POSIX. Timestamps of MODIFIED files are preserved by default
    (opt out: --update-mtime). Clean files are never rewritten at all.
  • Read-only directories: automatic fallback to a guarded in-place rewrite
    (rollback buffer kept until the write succeeds).
  • Backups: --backup keeps <file>.bak.<pid>; --backup-dir DIR mirrors the
    tree. The atomic replace itself needs no backup — the original stays
    intact until the verified rename.
  • The tool never deletes files and never creates files other than temps,
    requested backups and the log file.
`,
    'exit-codes': `EXIT CODES
  0   Success (tree clean, or everything cleaned)
  1   Completed, but some files had processing errors (see Error Breakdown),
      or --strict saw kept/protected/skipped files
  2   Invalid command line usage
  3   Environment problem: unusable directory, network failure during
      --check-update, or --update attempted on an npm-managed installation
      (use: npm install -g clean-bom-senior@latest)
  4   Critical internal error
  10  --check: at least one file needs cleaning (CI gate)
  11  --check-update: a newer version exists in the repository

Precedence when several apply: 2/3/4 (fatal) > 1 (file errors / strict) >
10 (check findings) > 0.
`,
    examples: `EXAMPLES
    ${N}                            clean current tree, smart defaults
    ${N} /path/to/project src       clean specific directories
    ${N} --check                    CI gate (exit 10 = needs cleaning)
    ${N} --check --json > r.json    machine-readable CI report
    ${N} --dry-run -v               explain every decision
    ${N} --git                      only git-tracked files
    ${N} --ext php,phtml,inc        custom extension set
    ${N} --add-ext md,json          extend the default set
    ${N} --exclude 'dist/*' --exclude-dir build
    ${N} --force notes.txt          strip a "may-be-required" BOM
    ${N} --bom-policy=keep          CRLF only, never touch BOMs
    ${N} --no-bom-clear             v2-compatible: CRLF only
    ${N} --backup --backup-dir /tmp/bak   keep mirrored backups
    ${N} --check-update             is there a new release? (exit 11)
    ${N} --self-test                verify the tool on this machine

GIT PRE-COMMIT HOOK  (.git/hooks/pre-commit, chmod +x)
    #!/bin/sh
    clean-bom-senior --check --git --quiet || {
      echo "BOM/CRLF issues found. Run: clean-bom-senior --git" >&2
      exit 1
    }
`,
    env: `ENVIRONMENT
  CLEAN_BOM_OPTS        Extra options prepended to argv (CI-wide defaults,
                        e.g. CLEAN_BOM_OPTS="--quiet --strict"). Simple
                        whitespace splitting — no quoting inside.
  CLEAN_BOM_GITHUB_REPO Repository slug used by --check-update/--update
                        (default: ${REPO_SLUG_DEFAULT})
  CLEAN_BOM_UPDATE_URL  Base URL override for updates (mirrors / air-gapped
                        setups). Must serve VERSION and bin/bom.js over HTTP(S).
  NO_COLOR              Any value disables colours (https://no-color.org)
  CLICOLOR_FORCE=1      Force colours even when stderr is not a TTY
  TMPDIR                Ignored by the Node implementation (temps live next
                        to the target file or in os.tmpdir())
`,
    ci: `CI / CD RECIPES
  Gate (fail the build when the tree is dirty):
      clean-bom-senior --check --quiet           # exit 10 = dirty
  Gate + machine report as an artifact:
      clean-bom-senior --check --json > bom-report.json; rc=$?
  Auto-fix job:
      clean-bom-senior --quiet && git diff --exit-code
  Strict policy ("no protected/kept files may exist in this repo"):
      clean-bom-senior --check --strict
  Updates: never run --update inside CI; pin the npm version instead.
  GitHub Actions: see .github/workflows/ci.yml for a ready-made job.
`,
    update: `AUTO-UPDATE
    ${N} --check-update    compare local v${VERSION} with the repository
    ${N} --update          download and replace this file

  How it works:
    1. Fetch VERSION from the repository over HTTPS (base URL overridable via
       CLEAN_BOM_UPDATE_URL for mirrors).
    2. Compare numeric major.minor.patch against the running version.
    3. --update downloads bin/bom.js of that release, verifies it (shebang +
       embedded version stamp), then replaces the running file atomically.

  Notes:
    • npm-managed installations (anything under node_modules) are detected and
      REFUSED with exit 3 — update those with:
          npm install -g clean-bom-senior@latest
      This keeps npm's integrity metadata consistent.
    • No telemetry: nothing is fetched unless you explicitly pass
      --check-update / --update.
`,
    files: `FILE TYPES & LIMITS
  Default extensions cleaned:   ${EXTENSIONS_DEFAULT.join(' ')}
  Always-safe-to-strip (code):  php js css html xml svg json ts vue … (see
                                --help bom-policy for the full behaviour)
  Sensitive (UTF-8 BOM may be required; kept when content is non-ASCII):
                                ${SENSITIVE_DEFAULT.join(' ')}
  Unknown extensions added via --ext/--add-ext are treated as sensitive
  (the safe default). Redefine with --sensitive-ext / --bom-policy.
  Max file size:                ${fmtSize(MAX_SIZE_DEFAULT)} by default (--max-size)
  Empty files:                  skipped by the walk (nothing to clean)
  UTF-16/UTF-32 files:          never modified (their BOM is part of the format)
  Binary (NUL) files:           never modified
`,
    json: `JSON REPORT (--json, printed on stdout)
  {
    "tool": "clean-bom-senior", "version": "${VERSION}",
    "mode": "fix|dry-run|check",
    "startedAt": "<ISO-8601 UTC>", "durationSeconds": N, "cwd": "...",
    "options": { bomPolicy, noBomClear, noCrlfNormalize, force, extensions,
                 sensitiveExtensions, maxSizeBytes, keepMtime },
    "summary": { scanned, changed, wouldChange, clean, bomKept, bomRemoved,
                 crlfFixed, protectedUtf16or32, protectedBinary,
                 protectedInvalidUtf8, skippedOversize, errors },
    "files": [ { "path", "status", "encoding", "actions", "bomKept",
                 "reason" } ]
  }
  file.status ∈ changed | would-change | kept | protected | skipped-size |
                error
  Clean files are counted in summary.clean but NOT listed in "files" (keeps
  reports small on big trees). Logs stay on stderr — stdout is pure JSON.
`,
    compatibility: `COMPATIBILITY & IMPLEMENTATIONS
  All v2 flags are supported: -h -V -v -n --no-bom-clear --no-rn-normalize
  -- and the "FILES..." positional form. Behavioural upgrades in v3 (details
  in CHANGELOG.md): byte-exact detection, real timestamp preservation,
  binary/UTF-16 protection, Smart BOM Policy, default exclusion of
  .git/node_modules, directory arguments, consistent exit codes.

  Implementation matrix:
    clean-bom-senior.sh   3.x    reference (Linux/macOS/WSL/Git Bash)
    bin/bom.js (npm CLI)  3.x    native Node.js — all platforms incl. Windows
    clean-bom-senior.ps1  3.x    PowerShell 7.6+ (Windows/Linux/macOS)
    clean-bom-senior.bat  2.07   legacy cmd.exe port (v2 contract, frozen)
  This IS the Node implementation — on Windows it is the recommended v3 CLI,
  together with the PowerShell port.
`,
  };
  const header = `Clean BOM Senior v${VERSION} — UTF-8 BOM & CRLF Cleaner with Smart BOM Policy\n` +
    `Repository: https://github.com/paulmann/Clean_BOM_Senior\n` +
    `Implementation: native Node.js (npm CLI)\n\n`;
  if (topic === '') {
    return header + common.usage + '\n' + common.options + '\n' + common['bom-policy'] + '\n' +
      common.safety + '\n' + common['exit-codes'] + '\n' + common.examples + '\n' + common.env + '\n' +
      `Topic help: ${SCRIPT_NAME} --help TOPIC\nTopics: ${HELP_TOPICS}\n`;
  }
  const aliases = {
    selection: 'options', bom: 'bom-policy', policy: 'bom-policy',
    exit: 'exit-codes', environment: 'env', compat: 'compatibility',
  };
  const key = aliases[topic] || topic;
  if (key === 'topics') return `Topics: ${HELP_TOPICS}\n`;
  if (Object.prototype.hasOwnProperty.call(common, key)) return header + common[key];
  process.stderr.write(`Unknown help topic: ${topic}\nTopics: ${HELP_TOPICS}\n`);
  cleanup(EXIT_USAGE);
  return '';
}

function showCompletion() {
  process.stdout.write(`# bash completion for the clean-bom-senior npm CLI
_clean_bom_senior() {
    local cur prev opts
    COMPREPLY=()
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    opts="-h --help -V --version -v --verbose -n --dry-run -c --check -f --fix
          -q --quiet --silent -j --json --color --no-color --log-file
          --ext --add-ext --exclude --exclude-dir --no-default-excludes
          --max-size --git --bom-policy --sensitive-ext --force --strict
          --no-bom-clear --no-rn-normalize --no-crlf-normalize --update-mtime
          --no-keep-mtime --backup --backup-dir --check-update --update
          --self-test --completion"
    case "$prev" in
        --color)      COMPREPLY=( $(compgen -W "auto always never" -- "$cur") ); return 0 ;;
        --bom-policy) COMPREPLY=( $(compgen -W "auto strip keep" -- "$cur") ); return 0 ;;
        --help)       COMPREPLY=( $(compgen -W "${HELP_TOPICS}" -- "$cur") ); return 0 ;;
        --log-file|--backup-dir) COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    else
        COMPREPLY=( $(compgen -f -- "$cur") )
    fi
    return 0
}
complete -F _clean_bom_senior clean-bom-senior
complete -F _clean_bom_senior bom
`);
}

//-----------------------------------------------------------------------------
// Update machinery (fetch-based; no external tools required)
//-----------------------------------------------------------------------------
function updateBaseUrl() {
  if (process.env.CLEAN_BOM_UPDATE_URL) return process.env.CLEAN_BOM_UPDATE_URL.replace(/\/+$/, '');
  const repo = process.env.CLEAN_BOM_GITHUB_REPO || REPO_SLUG_DEFAULT;
  return `https://raw.githubusercontent.com/${repo}/refs/heads/main`;
}

async function httpGet(url) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 20000);
  try {
    const res = await fetch(url, { signal: ctl.signal, redirect: 'follow' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.text();
  } finally {
    clearTimeout(timer);
  }
}

async function fetchRemoteVersion() {
  const text = await httpGet(`${updateBaseUrl()}/VERSION`);
  const v = text.split('\n')[0].trim();
  if (!/^\d+\.\d+\.\d+/.test(v)) throw new Error(`bad VERSION content: ${JSON.stringify(v.slice(0, 40))}`);
  return v;
}

function semverGt(a, b) {
  const pa = a.split('.').map((x) => parseInt(x, 10) || 0);
  const pb = b.split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) > (pb[i] || 0);
  }
  return false;
}

async function doCheckUpdate() {
  let remote;
  try {
    remote = await fetchRemoteVersion();
  } catch (e) {
    logError(`Could not determine the latest version from ${updateBaseUrl()}: ${e.message}`);
    cleanup(EXIT_ENV);
    return;
  }
  if (semverGt(remote, VERSION)) {
    logWarn(`Update available: ${VERSION} -> ${remote} (run: npm install -g clean-bom-senior@latest)`);
    cleanup(EXIT_UPDATE_AVAILABLE);
  }
  logInfo(`Up to date (local ${VERSION}, remote ${remote})`);
  cleanup(EXIT_OK);
}

async function doUpdate() {
  let remote;
  try {
    remote = await fetchRemoteVersion();
  } catch (e) {
    logError(`Could not determine the latest version from ${updateBaseUrl()}: ${e.message}`);
    cleanup(EXIT_ENV);
    return;
  }
  if (!semverGt(remote, VERSION)) {
    logInfo(`Already up to date (local ${VERSION}, remote ${remote})`);
    cleanup(EXIT_OK);
    return;
  }
  const selfPath = __filename;
  if (/[\\/]node_modules[\\/]/.test(selfPath)) {
    logError(`This installation is npm-managed: ${selfPath}`);
    logError('Update it with: npm install -g clean-bom-senior@latest');
    cleanup(EXIT_ENV);
    return;
  }
  const repo = process.env.CLEAN_BOM_GITHUB_REPO || REPO_SLUG_DEFAULT;
  const urls = process.env.CLEAN_BOM_UPDATE_URL
    ? [`${updateBaseUrl()}/bin/bom.js`]
    : [
        `https://raw.githubusercontent.com/${repo}/refs/tags/v${remote}/bin/bom.js`,
        `${updateBaseUrl()}/bin/bom.js`,
      ];
  let content = '';
  for (const u of urls) {
    try { content = await httpGet(u); if (content) break; } catch { /* try next */ }
  }
  if (!content) {
    logError(`Download failed (tried: ${urls.join(', ')})`);
    cleanup(EXIT_ENV);
    return;
  }
  if (!content.startsWith('#!/usr/bin/env node')) {
    logError('Downloaded content failed verification (bad shebang) — refusing to install');
    cleanup(EXIT_ENV);
    return;
  }
  if (!content.includes(`const VERSION = '${remote}'`)) {
    logError(`Downloaded content failed verification (version stamp != ${remote}) — refusing to install`);
    cleanup(EXIT_ENV);
    return;
  }
  const dir = path.dirname(selfPath);
  const temp = path.join(dir, `.cleanbom-update.${process.pid}.${Math.random().toString(36).slice(2, 8)}`);
  try {
    fs.writeFileSync(temp, `${content.replace(/\n$/, '')}\n`, { mode: 0o755 });
    fs.renameSync(temp, selfPath);
  } catch (e) {
    try { fs.rmSync(temp, { force: true }); } catch { /* ignore */ }
    logError(`Cannot replace ${selfPath}: ${e.message}`);
    logError('Re-run with sufficient privileges, or: npm install -g clean-bom-senior@latest');
    cleanup(EXIT_ENV);
    return;
  }
  process.stderr.write(`Updated ${SCRIPT_NAME}: ${VERSION} -> ${remote} (${selfPath})\n`);
  cleanup(EXIT_OK);
}

//-----------------------------------------------------------------------------
// Argument parsing (identical contract to the shell reference)
//-----------------------------------------------------------------------------
function normalizeExtList(s) {
  return s.split(/[,\s.]+/).map((x) => x.trim().toLowerCase()).filter(Boolean);
}

function parseSize(spec) {
  const m = /^(\d+)\s*([KMGB]?)(B?)$/i.exec(String(spec).trim());
  if (!m) return null;
  const n = parseInt(m[1], 10);
  const unit = m[2].toUpperCase();
  switch (unit) {
    case '': case 'B': return n;
    case 'K': return n * 1024;
    case 'M': return n * 1024 * 1024;
    case 'G': return n * 1024 * 1024 * 1024;
    default: return null;
  }
}

function needsValue(args, i, name) {
  if (i + 1 >= args.length) dieUsage(`${name} requires a value`);
  return args[i + 1];
}

function parseArguments(args) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const eq = a.indexOf('=');
    const inline = eq > 2 ? a.slice(eq + 1) : null;
    const name = eq > 2 ? a.slice(0, eq) : a;
    switch (name) {
      case '-h': case '--help':
        O.help = true;
        if (eq < 0 && i + 1 < args.length && !args[i + 1].startsWith('-')) { O.helpTopic = args[++i]; }
        else if (inline) { O.helpTopic = inline; }
        break;
      case '-V': case '--version': O.version = true; break;
      case '-v': case '--verbose': O.verbose = true; break;
      case '-n': case '--dry-run': O.dryRun = true; O.verbose = true; break;
      case '-c': case '--check': O.check = true; O.quiet = true; break;
      case '-f': case '--fix': break;
      case '-q': case '--quiet': O.quiet = true; break;
      case '--silent': O.quiet = true; O.silent = true; break;
      case '-j': case '--json': O.json = true; break;
      case '--color': {
        const v = inline !== null ? inline : needsValue(args, i, '--color'); if (inline === null) i++;
        if (!['auto', 'always', 'never'].includes(v)) dieUsage(`Invalid --color value: ${v} (expected auto|always|never)`);
        O.colorMode = v; break;
      }
      case '--no-color': O.colorMode = 'never'; break;
      case '--log-file': { const v = inline !== null ? inline : needsValue(args, i, '--log-file'); if (inline === null) i++; O.logFile = v; break; }
      case '--ext': { const v = inline !== null ? inline : needsValue(args, i, '--ext'); if (inline === null) i++; O.extensions = normalizeExtList(v); break; }
      case '--add-ext': { const v = inline !== null ? inline : needsValue(args, i, '--add-ext'); if (inline === null) i++; O.extensions = [...new Set([...O.extensions, ...normalizeExtList(v)])]; break; }
      case '--sensitive-ext': { const v = inline !== null ? inline : needsValue(args, i, '--sensitive-ext'); if (inline === null) i++; O.sensitiveExts = normalizeExtList(v); break; }
      case '--exclude': { const v = inline !== null ? inline : needsValue(args, i, '--exclude'); if (inline === null) i++; O.excludePatterns.push(v); break; }
      case '--exclude-dir': { const v = inline !== null ? inline : needsValue(args, i, '--exclude-dir'); if (inline === null) i++; O.excludeDirs.push(v); O.userExcludeDirs.push(v); break; }
      case '--no-default-excludes': O.useDefaultExcludes = false; break;
      case '--max-size': {
        const v = inline !== null ? inline : needsValue(args, i, '--max-size'); if (inline === null) i++;
        const n = parseSize(v);
        if (n === null || n <= 0) dieUsage(`Invalid --max-size: ${v} (examples: 512K, 10M, 1G, 1048576)`);
        O.maxSize = n; break;
      }
      case '--bom-policy': {
        const v = inline !== null ? inline : needsValue(args, i, '--bom-policy'); if (inline === null) i++;
        if (!['auto', 'strip', 'keep'].includes(v)) dieUsage(`Invalid --bom-policy: ${v} (expected auto|strip|keep)`);
        O.bomPolicy = v; break;
      }
      case '--force': O.force = true; break;
      case '--strict': O.strict = true; break;
      case '--git': O.gitMode = true; break;
      case '--no-bom-clear': O.noBomClear = true; break;
      case '--no-rn-normalize': case '--no-crlf-normalize': O.noCrlfNormalize = true; break;
      case '--update-mtime': case '--no-keep-mtime': O.keepMtime = false; break;
      case '--backup': O.backup = true; break;
      case '--backup-dir': { const v = inline !== null ? inline : needsValue(args, i, '--backup-dir'); if (inline === null) i++; O.backup = true; O.backupDir = v; break; }
      case '--check-update': O.checkUpdate = true; break;
      case '--update': O.update = true; break;
      case '--self-test': O.selfTest = true; break;
      case '--completion': O.completion = true; break;
      case '--':
        O.positional.push(...args.slice(i + 1));
        return;
      default:
        if (a.startsWith('-') && a !== '-') { logError(`Unknown option: ${a}`); cleanup(EXIT_USAGE); return; }
        if (a === '-') { logError('Unknown option: -'); cleanup(EXIT_USAGE); return; }
        O.positional.push(a);
    }
  }
  if (O.extensions.length === 0) dieUsage('Extension list is empty — nothing to do (check --ext/--add-ext)');
  if (!O.useDefaultExcludes) O.excludeDirs = [...O.userExcludeDirs];
}

//-----------------------------------------------------------------------------
// Self-test (same acceptance fixtures as the shell reference)
//-----------------------------------------------------------------------------
async function selfTest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cleanbom-selftest-'));
  let pass = 0; let fail = 0;
  const run = (args, cwd) => spawnSync(process.execPath, [__filename, ...args], { cwd: cwd || dir, stdio: ['ignore', 'pipe', 'pipe'] });
  const hex = (f) => { try { return fs.readFileSync(f).toString('hex'); } catch { return '<missing>'; } };
  const check = (name, file, want) => {
    const got = hex(file);
    if (got === want) { pass++; process.stdout.write(`ok   ${name}\n`); }
    else { fail++; process.stdout.write(`FAIL ${name}: got [${got}] want [${want}]\n`); }
  };

  fs.writeFileSync(path.join(dir, 't1.php'), Buffer.from('efbbbf3c3f706870 0d0a 6563686f20313b 0d0a'.replace(/ /g, ''), 'hex'));
  run(['--quiet', 't1.php']);
  check('t1 php: BOM stripped, CRLF→LF', path.join(dir, 't1.php'), '3c3f7068700a6563686f20313b0a');

  fs.writeFileSync(path.join(dir, 't2.txt'), Buffer.from('fffe680069000d000a00', 'hex'));
  run(['--quiet', 't2.txt']);
  check('t2 utf16le: never touched', path.join(dir, 't2.txt'), 'fffe680069000d000a00');

  fs.writeFileSync(path.join(dir, 't3.txt'), Buffer.from('efbbbf636166c3a90d0a', 'hex'));
  run(['--quiet', 't3.txt']);
  check('t3 sensitive txt: BOM kept, CRLF fixed', path.join(dir, 't3.txt'), 'efbbbf636166c3a90a');

  fs.writeFileSync(path.join(dir, 't4.txt'), Buffer.from('efbbbf636166c3a90d0a', 'hex'));
  run(['--quiet', '--force', 't4.txt']);
  check('t4 --force strips sensitive BOM', path.join(dir, 't4.txt'), '636166c3a90a');

  fs.writeFileSync(path.join(dir, 't5.txt'), Buffer.from('efbbbf706c61696e2061736369690d0a', 'hex'));
  run(['--quiet', 't5.txt']);
  check('t5 ascii-only txt: BOM stripped', path.join(dir, 't5.txt'), '706c61696e2061736369690a');

  fs.writeFileSync(path.join(dir, 't6.js'), Buffer.from('42494e004152590d0a', 'hex'));
  run(['--quiet', 't6.js']);
  check('t6 binary (NUL): never touched', path.join(dir, 't6.js'), '42494e004152590d0a');

  fs.writeFileSync(path.join(dir, 't7.css'), 'clean file\r\n');
  run(['--quiet', 't7.css']);
  const ino1 = fs.statSync(path.join(dir, 't7.css')).ino;
  run(['--quiet', 't7.css']);
  const ino2 = fs.statSync(path.join(dir, 't7.css')).ino;
  if (ino1 === ino2 && hex(path.join(dir, 't7.css')) === '636c65616e2066696c650a') {
    pass++; process.stdout.write('ok   t7 clean file not rewritten (inode stable)\n');
  } else { fail++; process.stdout.write('FAIL t7\n'); }

  fs.writeFileSync(path.join(dir, 't8.php'), 'x\r\n');
  let r = run(['--check', 't8.php']);
  if (r.status === 10) { pass++; process.stdout.write('ok   t8 --check exit 10 on dirty file\n'); }
  else { fail++; process.stdout.write(`FAIL t8 (rc=${r.status})\n`); }
  run(['--quiet', 't8.php']);
  r = run(['--check', 't8.php']);
  if (r.status === 0) { pass++; process.stdout.write('ok   t9 --check exit 0 when clean\n'); }
  else { fail++; process.stdout.write(`FAIL t9 (rc=${r.status})\n`); }

  r = run(['--json', '--check', 't8.php']);
  try {
    JSON.parse(r.stdout.toString('utf8'));
    pass++; process.stdout.write('ok   t10 --json emits valid JSON\n');
  } catch { fail++; process.stdout.write('FAIL t10\n'); }

  fs.rmSync(dir, { recursive: true, force: true });
  process.stdout.write(`\nself-test: ${pass} passed, ${fail} failed\n`);
  cleanup(fail === 0 ? EXIT_OK : EXIT_FILE_ERRORS);
}

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------
async function main() {
  const envOpts = (process.env.CLEAN_BOM_OPTS || '').trim();
  const argv = envOpts ? [...envOpts.split(/\s+/), ...process.argv.slice(2)] : process.argv.slice(2);
  parseArguments(argv);
  colorInit();

  if (O.logFile) {
    try {
      fs.appendFileSync(O.logFile, `\n===== ${SCRIPT_NAME} v${VERSION} run at ${timestamp()} =====\n`);
    } catch {
      dieEnv(`Cannot write to log file: ${O.logFile}`);
    }
  }

  if (O.completion) { showCompletion(); cleanup(EXIT_OK); return; }
  if (O.help) { process.stdout.write(helpText(O.helpTopic)); cleanup(EXIT_OK); return; }
  if (O.version) {
    process.stdout.write(`${SCRIPT_NAME} version ${VERSION} (Node.js implementation)\n`);
    process.stdout.write('Author: Mikhail Deynekin <mid1977@gmail.com>\n');
    process.stdout.write('Website: https://deynekin.com\n');
    cleanup(EXIT_OK); return;
  }

  if (O.selfTest) { await selfTest(); return; }
  if (O.checkUpdate) { await doCheckUpdate(); return; }
  if (O.update) { await doUpdate(); return; }

  if (!O.check && !O.quiet && !O.json) showGreeting();

  if (O.gitMode) {
    scanGitTracked();
  } else if (O.positional.length === 0) {
    logInfo(`Recursive mode: scanning '.' for extensions: ${O.extensions.join(' ')}`);
    walkDirectory('.', './');
  } else {
    for (const arg of O.positional) {
      let lst = null;
      try { lst = fs.lstatSync(arg); } catch { /* missing */ }
      if (lst === null) {
        logError(`File not found: ${arg}`);
        C.errAccess += 1; C.fileErrors = true;
        continue;
      }
      if (lst.isSymbolicLink()) {
        let real;
        try { real = fs.realpathSync(arg); } catch {
          logError(`File not found: ${arg}`);
          C.errAccess += 1; C.fileErrors = true;
          continue;
        }
        let rst = null;
        try { rst = fs.statSync(real); } catch { /* dangling */ }
        if (rst === null) {
          logError(`File not found: ${arg}`);
          C.errAccess += 1; C.fileErrors = true;
        } else if (rst.isDirectory()) {
          logInfo(`Directory mode (symlink resolved): scanning '${arg}'`);
          walkDirectory(real, `${displayPath(real).replace(/\/$/, '')}/`);
        } else {
          logInfo(`Symlink argument resolved: ${arg} -> ${real}`);
          if (!handleFile(arg, real)) C.fileErrors = true;
        }
        continue;
      }
      if (lst.isDirectory()) {
        logInfo(`Directory mode: scanning '${arg}' for extensions: ${O.extensions.join(' ')}`);
        walkDirectory(arg, `${displayPath(arg).replace(/\/$/, '')}/`);
        continue;
      }
      // Explicit file arguments are echoed VERBATIM (the v2 contract).
      if (!handleFile(arg, arg)) C.fileErrors = true;
    }
  }

  if (O.json) jsonReport();
  if (O.check) {
    if (O.quiet && !O.verbose) {
      const kept = C.keptBom + C.protectedUtf16 + C.protectedBinary + C.protectedInvalid;
      process.stderr.write(`check: ${C.wouldChange} file(s) need cleaning, ${kept} kept/protected, ${C.errors} error(s)\n`);
    } else {
      displayStatistics();
    }
  } else if (!O.quiet && !O.silent) {
    displayStatistics();
  }

  let rc = EXIT_OK;
  const keptTotal = C.keptBom + C.protectedUtf16 + C.protectedBinary + C.protectedInvalid + C.skippedSize;
  if (C.fileErrors || C.errors > 0) rc = EXIT_FILE_ERRORS;
  else if (O.strict && keptTotal > 0) {
    logWarn(`--strict: ${keptTotal} file(s) were kept/protected/skipped`);
    rc = EXIT_FILE_ERRORS;
  } else if (O.check && C.wouldChange > 0) rc = EXIT_CHECK_FOUND;
  cleanup(rc);
}

main().catch((e) => {
  logError(`Internal error: ${e && e.stack ? e.stack : e}`);
  cleanup(EXIT_INTERNAL);
});
