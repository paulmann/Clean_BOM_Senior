#!/usr/bin/env node
'use strict';
/*=============================================================================
 * Clean BOM Senior v3 — Node.js implementation test suite
 *=============================================================================
 * Mirrors the shell suite (tests/sh/run-tests.sh) against `node bin/bom.js`,
 * so BOTH v3 implementations are pinned to the same CLI contract
 * (docs/CLI-CONTRACT.md). Runs on Linux, macOS and Windows (CI matrix).
 *
 *   Usage:  node tests/node/run-tests.mjs [FILTER]
 *   Exit:   0 = all passed, 1 = failures, 2 = prerequisite missing.
 *===========================================================================*/

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..', '..');
const BOM_JS = path.join(REPO_ROOT, 'bin', 'bom.js');

if (!fs.existsSync(BOM_JS)) {
  process.stderr.write(`FATAL: implementation not found: ${BOM_JS}\n`);
  process.exit(2);
}

const FILTER = process.argv[2] || '';
const IS_WINDOWS = process.platform === 'win32';

const HAVE_GIT = spawnSync('git', ['--version'], { stdio: 'ignore' }).status === 0;

let PASS = 0;
let FAIL = 0;
const FAILED = [];
let WS = null;

const color = process.stdout.isTTY
  ? { red: '\x1b[0;31m', grn: '\x1b[0;32m', ylw: '\x1b[1;33m', rst: '\x1b[0m' }
  : { red: '', grn: '', ylw: '', rst: '' };

//-----------------------------------------------------------------------------
// Harness
//-----------------------------------------------------------------------------
function newWs() {
  if (WS) fs.rmSync(WS, { recursive: true, force: true });
  WS = fs.mkdtempSync(path.join(os.tmpdir(), 'cleanbom-node-test-'));
  fs.mkdirSync(path.join(WS, 'work'));
}

function tool(...args) {
  const r = spawnSync(process.execPath, [BOM_JS, ...args], {
    cwd: path.join(WS, 'work'),
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  return { rc: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

function toolEnv(env, ...args) {
  const r = spawnSync(process.execPath, [BOM_JS, ...args], {
    cwd: path.join(WS, 'work'),
    encoding: 'utf8',
    env: { ...process.env, ...env },
    maxBuffer: 64 * 1024 * 1024,
  });
  return { rc: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// Async spawn — REQUIRED for the update tests: they talk to an HTTP server
// living in THIS process, and spawnSync would block its event loop (deadlock).
function toolAsync(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [BOM_JS, ...args], {
      cwd: path.join(WS, 'work'),
      env: { ...process.env, ...env },
    });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (rc) => resolve({ rc, stdout, stderr }));
  });
}

function spawnAsync(file, args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [file, ...args], {
      cwd: path.join(WS, 'work'),
      env: { ...process.env, ...env },
    });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (rc) => resolve({ rc, stdout, stderr }));
  });
}

const w = (...p) => path.join(WS, 'work', ...p);
const writeFixture = (name, hex) => fs.writeFileSync(w(name), Buffer.from(hex, 'hex'));
const readHex = (name) => fs.readFileSync(w(name)).toString('hex');

function ok(name) { PASS++; process.stdout.write(`${color.grn}ok${color.rst}   ${name}\n`); }
function bad(name, detail) {
  FAIL++; FAILED.push(name);
  process.stdout.write(`${color.red}FAIL${color.rst} ${name}\n`);
  if (detail) process.stdout.write(`       ${detail}\n`);
}
function assertBytes(name, file, wantHex) {
  const got = readHex(name);
  if (got === wantHex) ok(file); else bad(file, `bytes of ${name}: got [${got}] want [${wantHex}]`);
}
function assertRc(r, want, name) {
  if (r.rc === want) ok(`${name} (rc=${r.rc})`); else bad(name, `exit code: got ${r.rc} want ${want}\n--- stderr ---\n${r.stderr.slice(0, 600)}`);
}
function assertGrep(haystack, needle, name) {
  if (haystack.includes(needle)) ok(name); else bad(name, `[${needle}] not found in output`);
}
function assertNotGrep(haystack, needle, name) {
  if (!haystack.includes(needle)) ok(name); else bad(name, `[${needle}] unexpectedly present`);
}
function section(title) { process.stdout.write(`\n${color.ylw}== ${title} ==${color.rst}\n`); }

const BOM = 'efbbbf';
const CRLF = '0d0a';

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------
const tests = [];
function test(name, fn) { tests.push([name, fn]); }

section('core cleaning');

test('core: BOM+CRLF php', () => {
  writeFixture('a.php', `${BOM}3c3f706870${CRLF}6563686f20313b${CRLF}`);
  assertRc(tool('--quiet', 'a.php'), 0, 'core: exit 0');
  assertBytes('a.php', 'core: BOM stripped + CRLF→LF', '3c3f7068700a6563686f20313b0a');
});

test('core: BOM only', () => {
  writeFixture('b.php', `${BOM}3c3f7068700a`);
  tool('--quiet', 'b.php');
  assertBytes('b.php', 'core: BOM-only stripped', '3c3f7068700a');
});

test('core: CRLF only', () => {
  writeFixture('c.js', `78203d20313b${CRLF}79203d20323b${CRLF}`);
  tool('--quiet', 'c.js');
  assertBytes('c.js', 'core: CRLF-only normalized', '78203d20313b0a79203d20323b0a');
});

test('core: clean file untouched (inode + mtime stable)', () => {
  fs.writeFileSync(w('d.php'), '<?php\necho 1;\n');
  const old = new Date('2019-05-05T05:05:05Z');
  fs.utimesSync(w('d.php'), old, old);
  const st1 = fs.statSync(w('d.php'));
  tool('--quiet', 'd.php');
  const st2 = fs.statSync(w('d.php'));
  if (!IS_WINDOWS && st1.ino === st2.ino) ok('clean: inode stable (not rewritten)');
  else if (IS_WINDOWS) ok('clean: inode check skipped on Windows');
  else bad('clean: inode stable', `${st1.ino} -> ${st2.ino}`);
  if (st2.mtimeMs === st1.mtimeMs) ok('clean: mtime stable'); else bad('clean: mtime stable');
});

test('core: empty file', () => {
  fs.writeFileSync(w('empty.xml'), '');
  assertRc(tool('--quiet', 'empty.xml'), 0, 'empty file: exit 0');
  assertBytes('empty.xml', 'empty file: still empty', '');
});

test('core: 3-byte BOM-only file becomes empty', () => {
  writeFixture('onlybom.htm', BOM);
  tool('--quiet', 'onlybom.htm');
  assertBytes('onlybom.htm', '3-byte BOM-only file becomes empty', '');
});

test('core: no trailing newline preserved', () => {
  writeFixture('noeol.php', `${BOM}6e6f656f6c${CRLF}7365636f6e64`);
  tool('--quiet', 'noeol.php');
  assertBytes('noeol.php', 'no-trailing-newline preserved', '6e6f656f6c0a7365636f6e64');
});

test('core: CRLF past byte 1024 (v2 regression)', () => {
  const xs = Buffer.alloc(2000, 0x78);
  fs.writeFileSync(w('late.php'), Buffer.concat([xs, Buffer.from('y\r\nz\n')]));
  tool('--quiet', 'late.php');
  assertBytes('late.php', 'regression: late CRLF found and fixed',
    Buffer.concat([xs, Buffer.from('y\nz\n')]).toString('hex'));
});

test('core: hex false positive regression (30 d0 a5)', () => {
  writeFixture('fp.php', '30d0a57461696c0a');
  const st1 = fs.statSync(w('fp.php'));
  tool('--quiet', 'fp.php');
  const st2 = fs.statSync(w('fp.php'));
  assertBytes('fp.php', 'regression: bytes intact', '30d0a57461696c0a');
  if (IS_WINDOWS) ok('regression: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('regression: not rewritten (inode stable)');
  else bad('regression: inode stable', `${st1.ino} -> ${st2.ino}`);
});

test('core: uppercase extension .PHP', () => {
  writeFixture('UP.PHP', `${BOM}58${CRLF}`);
  tool('--quiet', 'UP.PHP');
  assertBytes('UP.PHP', 'uppercase extension processed', '580a');
});

test('core: lone CRs and EOF CR semantics', () => {
  writeFixture('mix.php', '610d620d0a630d'); // a\r b\r\n c\r(EOF)
  tool('--quiet', 'mix.php');
  assertBytes('mix.php', 'mixed: lone CR kept, CRLF fixed, EOF CR removed', '610d620a63');
  writeFixture('cronly.php', '610d620d630d'); // a\rb\rc\r — no LF at all
  const st1 = fs.statSync(w('cronly.php'));
  tool('--quiet', 'cronly.php');
  const st2 = fs.statSync(w('cronly.php'));
  assertBytes('cronly.php', 'CR-only bytes intact', '610d620d630d');
  if (IS_WINDOWS) ok('CR-only: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('CR-only file untouched (inode stable)');
  else bad('CR-only untouched', 'inode changed');
});

section('Smart BOM Policy');

test('policy: UTF-16LE never touched (incl. embedded ASCII CRLF)', () => {
  writeFixture('u16.txt', 'fffe680069000d000a00');
  tool('--quiet', 'u16.txt');
  assertBytes('u16.txt', 'utf16le: never touched', 'fffe680069000d000a00');
  writeFixture('u16mix.txt', 'fffe68000d0a5a5a'); // UTF-16LE 'h' + ASCII CR LF + ZZ
  const r = tool('--quiet', 'u16mix.txt');
  assertBytes('u16mix.txt', 'utf16le with ASCII CRLF inside: still never touched', 'fffe68000d0a5a5a');
  assertGrep(r.stderr, 'structurally required', 'utf16: refusal explained');
});

test('policy: CRLF detection is byte-exact, not line-based (sh regression)', () => {
  // A UTF-16LE line break is 0D 00 0A: a CR at the end of an LF-delimited
  // line, but NOT the byte pair 0D 0A. The shell reference used to detect CRLF
  // with grep '<CR>$' and an awk end-of-line test, so it flagged these files as
  // modification candidates and reported them as protected UTF-16 - inflating
  // protectedUtf16or32 and warning about files that needed nothing. That
  // contradicted AGENTS.md invariant 3 ("CRLF = byte 0D immediately before
  // 0A") and docs/SMART-BOM.md section 2. This implementation was already
  // byte-exact; the test pins it so a future "optimisation" cannot regress it.
  writeFixture('u16le_nc.txt', 'fffe680069000d000a00');
  writeFixture('u16be_nc.xml', 'feff0068006900000d000a');
  writeFixture('u32le_nc.txt', 'fffe00000068000000690d0000000a');
  const r = tool('--quiet', 'u16le_nc.txt', 'u16be_nc.xml', 'u32le_nc.txt');
  assertBytes('u16le_nc.txt', 'utf16le without a 0D0A pair: untouched', 'fffe680069000d000a00');
  assertBytes('u16be_nc.xml', 'utf16be without a 0D0A pair: untouched', 'feff0068006900000d000a');
  assertBytes('u32le_nc.txt', 'utf32le without a 0D0A pair: untouched', 'fffe00000068000000690d0000000a');
  assertNotGrep(r.stderr, 'structurally required', 'no UTF-16 refusal is logged');
  assertNotGrep(r.stderr, 'NOT touched', 'nothing is reported as protected');
  const j = JSON.parse(tool('--json', '--quiet', 'u16le_nc.txt', 'u16be_nc.xml', 'u32le_nc.txt').stdout);
  if (j.summary.protectedUtf16or32 === 0) ok('protectedUtf16or32 stays 0');
  else bad('protectedUtf16or32 stays 0', `got ${j.summary.protectedUtf16or32}`);
  if (j.summary.clean === 3) ok('all three are clean, not candidates');
  else bad('all three are clean, not candidates', `got clean=${j.summary.clean}`);
  // A UTF-16 file that DOES contain a literal 0D 0A pair is still refused.
  writeFixture('u16le_rc.txt', 'fffe68000d0a5a5a');
  const r2 = tool('--quiet', 'u16le_rc.txt');
  assertBytes('u16le_rc.txt', 'utf16le WITH a real 0D0A pair: still never touched', 'fffe68000d0a5a5a');
  assertGrep(r2.stderr, 'structurally required', 'the real-CRLF case is still refused and explained');
});

test('policy: UTF-16BE / UTF-32 protected, even with --force', () => {
  writeFixture('u16be.txt', 'feff006800690d0a');
  writeFixture('u32le.txt', 'fffe0000680000000d0a');
  writeFixture('u32be.txt', '0000feff000000680d0a');
  tool('--quiet', 'u16be.txt', 'u32le.txt', 'u32be.txt');
  assertBytes('u16be.txt', 'utf16be: never touched', 'feff006800690d0a');
  assertBytes('u32le.txt', 'utf32le: never touched', 'fffe0000680000000d0a');
  assertBytes('u32be.txt', 'utf32be: never touched', '0000feff000000680d0a');
  tool('--quiet', '--force', 'u16be.txt', 'u32le.txt', 'u32be.txt');
  assertBytes('u16be.txt', 'utf16be: --force cannot override hard refusal', 'feff006800690d0a');
});

test('policy: binary NUL never touched (incl. NUL beyond 8 KiB)', () => {
  writeFixture('bin1.txt', `${BOM}42494e004152590d0a`);
  writeFixture('bin2.js', '42494e004152590d0a');
  const far = Buffer.concat([Buffer.from(BOM, 'hex'), Buffer.alloc(9000, 0x78), Buffer.from('000d0a', 'hex')]);
  fs.writeFileSync(w('bin3.php'), far);
  tool('--quiet', 'bin1.txt', 'bin2.js', 'bin3.php');
  assertBytes('bin1.txt', 'binary with BOM: never touched', `${BOM}42494e004152590d0a`);
  assertBytes('bin2.js', 'binary no BOM + CRLF: never touched', '42494e004152590d0a');
  assertBytes('bin3.php', 'binary with far NUL: never touched', far.toString('hex'));
});

test('policy: invalid UTF-8 protected; --force cleans byte-level', () => {
  writeFixture('bad.php', `${BOM}c0c10d0a`); // cp1251-ish bytes, invalid UTF-8
  const r1 = tool('--quiet', 'bad.php');
  assertBytes('bad.php', 'invalid UTF-8: untouched by default', `${BOM}c0c10d0a`);
  assertGrep(r1.stderr, 'not valid UTF-8', 'invalid UTF-8: refusal explained');
  tool('--quiet', '--force', 'bad.php');
  assertBytes('bad.php', 'invalid UTF-8 + --force: byte-level clean', 'c0c10a');
});

test('policy: sensitive txt keeps BOM, CRLF still fixed', () => {
  writeFixture('notes.txt', `${BOM}636166c3a90d0a`); // "café" + CRLF
  const r = tool('notes.txt');
  assertBytes('notes.txt', 'sensitive txt: BOM KEPT, CRLF fixed', `${BOM}636166c3a90a`);
  assertGrep(r.stderr, 'BOM kept', 'sensitive txt: keep explained');
});

test('policy: --force strips sensitive BOM', () => {
  writeFixture('notes.txt', `${BOM}636166c3a90d0a`);
  tool('--quiet', '--force', 'notes.txt');
  assertBytes('notes.txt', '--force strips the sensitive BOM', '636166c3a90a');
});

test('policy: ASCII-only sensitive txt gets BOM stripped', () => {
  writeFixture('ascii.txt', `${BOM}706c61696e2061736369690d0a`);
  tool('--quiet', 'ascii.txt');
  assertBytes('ascii.txt', 'ascii-only txt: BOM stripped', '706c61696e2061736369690a');
});

test('policy: --bom-policy keep/strip', () => {
  writeFixture('p.php', `${BOM}3c3f7068700d0a`);
  writeFixture('p.txt', `${BOM}706c61696e0d0a`);
  tool('--quiet', '--bom-policy=keep', 'p.php', 'p.txt');
  assertBytes('p.php', 'policy keep: php BOM untouched, CRLF fixed', `${BOM}3c3f7068700a`);
  assertBytes('p.txt', 'policy keep: txt BOM untouched, CRLF fixed', `${BOM}706c61696e0a`);
  writeFixture('s.txt', `${BOM}636166c3a90d0a`);
  tool('--quiet', '--bom-policy=strip', 's.txt');
  assertBytes('s.txt', 'policy strip: sensitive BOM stripped', '636166c3a90a');
});

test('policy: sensitive-ext customization', () => {
  writeFixture('data.dat', `${BOM}636166c3a90d0a`);
  tool('--quiet', '--ext', 'dat', 'data.dat');
  assertBytes('data.dat', 'unknown ext: sensitive-by-default (BOM kept)', `${BOM}636166c3a90a`);
  writeFixture('data2.dat', `${BOM}636166c3a90d0a`);
  tool('--quiet', '--ext', 'dat', '--sensitive-ext', '', 'data2.dat');
  assertBytes('data2.dat', "--sensitive-ext '' disables sensitivity", '636166c3a90a');
  writeFixture('sens.php', `${BOM}636166c3a90d0a`);
  tool('--quiet', '--sensitive-ext', 'php', 'sens.php');
  assertBytes('sens.php', '--sensitive-ext php: php becomes sensitive', `${BOM}636166c3a90a`);
});

test('policy: --no-bom-clear', () => {
  writeFixture('nb.php', `${BOM}6f6e6c79626f6d0a`);
  const st1 = fs.statSync(w('nb.php'));
  tool('--quiet', '--no-bom-clear', 'nb.php');
  const st2 = fs.statSync(w('nb.php'));
  assertBytes('nb.php', '--no-bom-clear: BOM-only file untouched', `${BOM}6f6e6c79626f6d0a`);
  if (IS_WINDOWS) ok('--no-bom-clear: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('--no-bom-clear: not rewritten');
  else bad('--no-bom-clear: not rewritten', 'inode changed');
  writeFixture('nb2.php', `${BOM}626f74680d0a`);
  tool('--quiet', '--no-bom-clear', 'nb2.php');
  assertBytes('nb2.php', '--no-bom-clear: CRLF fixed, BOM kept', `${BOM}626f74680a`);
});

test('policy: --no-rn-normalize (v2/MSYS regression)', () => {
  writeFixture('nc.php', `63726c66${CRLF}6f6e6c79${CRLF}`);
  const st1 = fs.statSync(w('nc.php'));
  tool('--quiet', '--no-rn-normalize', 'nc.php');
  const st2 = fs.statSync(w('nc.php'));
  if (IS_WINDOWS) ok('--no-rn-normalize: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('--no-rn-normalize: CRLF-only file untouched');
  else bad('--no-rn-normalize untouched', 'inode changed');
  writeFixture('nc2.php', `${BOM}626f74680d0a`);
  tool('--quiet', '--no-rn-normalize', 'nc2.php');
  assertBytes('nc2.php', '--no-rn-normalize: BOM stripped, CRLF really kept', '626f74680d0a');
  writeFixture('nc3.php', `${BOM}626f74680d0a`);
  tool('--quiet', '--no-crlf-normalize', 'nc3.php');
  assertBytes('nc3.php', '--no-crlf-normalize alias works', '626f74680d0a');
});

test('policy: both disabled rewrites nothing', () => {
  writeFixture('x.php', `${BOM}626f74680d0a`);
  const st1 = fs.statSync(w('x.php'));
  tool('--quiet', '--no-bom-clear', '--no-rn-normalize', 'x.php');
  const st2 = fs.statSync(w('x.php'));
  if (IS_WINDOWS) ok('both disabled: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('both disabled: nothing rewritten at all');
  else bad('both disabled: nothing rewritten', 'inode changed');
});

section('metadata & safety');

test('meta: mtime preserved by default; --update-mtime refreshes', () => {
  writeFixture('m.php', `${BOM}3c3f7068700a`);
  const old = new Date('2020-01-01T00:00:00Z');
  fs.utimesSync(w('m.php'), old, old);
  tool('--quiet', 'm.php');
  const m2 = fs.statSync(w('m.php')).mtimeMs;
  if (Math.abs(m2 - old.getTime()) < 1000) ok('mtime preserved on modified file');
  else bad('mtime preserved', `${old.getTime()} -> ${m2}`);
  writeFixture('m2.php', `${BOM}3c3f7068700a`);
  fs.utimesSync(w('m2.php'), old, old);
  tool('--quiet', '--update-mtime', 'm2.php');
  const m3 = fs.statSync(w('m2.php')).mtimeMs;
  if (Math.abs(m3 - old.getTime()) > 1000) ok('--update-mtime refreshes mtime');
  else bad('--update-mtime', 'mtime unchanged');
});

test('meta: permissions preserved (POSIX)', () => {
  if (IS_WINDOWS) { ok('meta: permissions SKIPPED on Windows'); return; }
  writeFixture('perm.php', `${BOM}3c3f7068700a`);
  fs.chmodSync(w('perm.php'), 0o640);
  tool('--quiet', 'perm.php');
  const mode = fs.statSync(w('perm.php')).mode & 0o777;
  if (mode === 0o640) ok('permissions preserved (640)'); else bad('permissions preserved', `mode=${mode.toString(8)}`);
});

test('meta: hard links rewritten in place (POSIX)', () => {
  if (IS_WINDOWS) { ok('meta: hardlink SKIPPED on Windows'); return; }
  writeFixture('hl.php', `${BOM}686172640d0a`);
  fs.linkSync(w('hl.php'), w('hl_link.php'));
  const st1 = fs.statSync(w('hl.php'));
  const r = tool('--quiet', 'hl.php');
  const st2 = fs.statSync(w('hl.php'));
  if (st1.ino === st2.ino) ok('hardlink: inode preserved'); else bad('hardlink inode', `${st1.ino} -> ${st2.ino}`);
  assertBytes('hl_link.php', 'hardlink: second link sees cleaned content', '686172640a');
  assertGrep(r.stderr, 'hard links', 'hardlink: warning logged');
});

test('meta: symlink argument resolves to target', () => {
  if (IS_WINDOWS) { ok('meta: symlink SKIPPED on Windows'); return; }
  writeFixture('real.php', `${BOM}7265616c0d0a`);
  fs.symlinkSync('real.php', w('link.php'));
  tool('--quiet', 'link.php');
  assertBytes('real.php', 'symlink arg: target cleaned', '7265616c0a');
  if (fs.lstatSync(w('link.php')).isSymbolicLink()) ok('symlink arg: link intact');
  else bad('symlink arg: link intact', 'link destroyed');
});

test('meta: --backup and --backup-dir', () => {
  writeFixture('bk.php', `${BOM}6f6c640d0a`);
  tool('--quiet', '--backup', 'bk.php');
  const baks = fs.readdirSync(path.join(WS, 'work')).filter((f) => f.startsWith('bk.php.bak.'));
  if (baks.length === 1) ok('--backup: backup file created');
  else { bad('--backup: backup created', JSON.stringify(baks)); return; }
  assertBytes(`bk.php.bak.${baks[0].split('.').pop()}`, '--backup: original bytes kept', `${BOM}6f6c640d0a`);
  writeFixture('bk2.php', `${BOM}6f6c64320d0a`);
  const bdir = path.join(WS, 'baks');
  fs.mkdirSync(bdir, { recursive: true });
  tool('--quiet', '--backup-dir', bdir, 'bk2.php');
  if (fs.existsSync(path.join(bdir, 'bk2.php'))) ok('--backup-dir: copy created');
  else bad('--backup-dir: copy created', 'missing');
});

test('meta: no temp/backup leftovers', () => {
  writeFixture('l.php', `${BOM}6c65616b0d0a`);
  tool('--quiet', 'l.php');
  const leftovers = fs.readdirSync(path.join(WS, 'work')).filter((f) => f.startsWith('.cleanbom.') || f.includes('.bak.'));
  if (leftovers.length === 0) ok('no leftovers after a normal run'); else bad('no leftovers', JSON.stringify(leftovers));
});

test('meta: idempotent second run', () => {
  writeFixture('a.php', `${BOM}3c3f7068700d0a`);
  tool('--quiet', 'a.php');
  const st1 = fs.statSync(w('a.php'));
  const r = tool('a.php');
  const st2 = fs.statSync(w('a.php'));
  if (IS_WINDOWS) ok('idempotent: inode check skipped on Windows');
  else if (st1.ino === st2.ino) ok('idempotent: second run does not rewrite');
  else bad('idempotent', 'inode changed');
  assertGrep(r.stderr, 'Files processed: 0', 'idempotent: summary reports 0 processed');
});

section('modes: dry-run / check / json / strict / quiet');

test('mode: dry-run modifies nothing', () => {
  writeFixture('a.php', `${BOM}3c3f7068700d0a`);
  const r = tool('--dry-run', 'a.php');
  assertRc(r, 0, 'dry-run: exit 0');
  assertBytes('a.php', 'dry-run: bytes intact', `${BOM}3c3f7068700d0a`);
  assertGrep(r.stderr, 'Would process', 'dry-run: reports what would happen');
});

test('mode: --check exit codes', () => {
  writeFixture('a.php', `${BOM}3c3f7068700d0a`);
  const r1 = tool('--check', 'a.php');
  assertRc(r1, 10, '--check: exit 10 when dirty');
  assertBytes('a.php', '--check: file NOT modified', `${BOM}3c3f7068700d0a`);
  tool('--quiet', 'a.php');
  assertRc(tool('--check', 'a.php'), 0, '--check: exit 0 when clean');
});

test('mode: --json schema and counters', () => {
  writeFixture('j1.php', `${BOM}3c3f7068700d0a`);
  writeFixture('j2.txt', 'fffe7a000d0a');
  writeFixture('j3.txt', `${BOM}636166c3a90a`);
  fs.writeFileSync(w('j4.css'), 'clean\n');
  const r = tool('--json', '--check', '.');
  assertRc(r, 10, '--json --check: exit 10');
  let j = null;
  try { j = JSON.parse(r.stdout); } catch (e) { bad('--json: valid JSON', e.message); return; }
  ok('--json: stdout is valid JSON');
  const s = j.summary;
  const fails = [];
  if (s.wouldChange !== 1) fails.push(`wouldChange=${s.wouldChange}`);
  if (s.clean !== 1) fails.push(`clean=${s.clean}`);
  if (s.bomKept !== 1) fails.push(`bomKept=${s.bomKept}`);
  if (s.protectedUtf16or32 !== 1) fails.push(`protectedUtf16or32=${s.protectedUtf16or32}`);
  if (fails.length === 0) ok('--json: summary counters correct'); else bad('--json: counters', fails.join(', '));
  const wc = j.files.find((f) => f.status === 'would-change');
  if (wc && wc.actions.includes('strip-bom') && wc.actions.includes('crlf-to-lf')) ok('--json: would-change entry');
  else bad('--json: would-change entry', JSON.stringify(wc));
  const kept = j.files.find((f) => f.status === 'kept');
  if (kept && kept.bomKept === true && kept.reason === 'bom-may-be-required') ok('--json: kept entry');
  else bad('--json: kept entry', JSON.stringify(kept));
  const prot = j.files.find((f) => f.status === 'protected');
  if (prot && prot.reason === 'bom-required-utf16le') ok('--json: protected entry');
  else bad('--json: protected entry', JSON.stringify(prot));
  assertNotGrep(r.stdout, 'INFO', '--json: stdout pure (logs on stderr)');
});

test('mode: --strict', () => {
  writeFixture('st.txt', `${BOM}636166c3a90d0a`);
  assertRc(tool('--check', '--strict', 'st.txt'), 1, '--strict: kept BOM fails with 1');
  writeFixture('st2.php', `${BOM}6f6b0d0a`);
  assertRc(tool('--check', '--strict', 'st2.php'), 10, '--strict: ordinary dirty still 10');
});

test('mode: --quiet / --silent', () => {
  writeFixture('a.php', `${BOM}3c3f7068700d0a`);
  assertNotGrep(tool('--quiet', 'a.php').stderr, 'PROCESSING SUMMARY', '--quiet: no summary');
  writeFixture('a2.php', `${BOM}3c3f7068700d0a`);
  const r = tool('--silent', 'a2.php');
  if (r.stderr === '') ok('--silent: stderr empty on success'); else bad('--silent empty', JSON.stringify(r.stderr.slice(0, 200)));
});

test('mode: --log-file', () => {
  writeFixture('a.php', `${BOM}3c3f7068700d0a`);
  const lf = path.join(WS, 'run.log');
  tool('-v', '--log-file', lf, 'a.php');
  if (!fs.existsSync(lf)) { bad('--log-file created', 'missing'); return; }
  ok('--log-file: created');
  const content = fs.readFileSync(lf, 'utf8');
  assertGrep(content, 'Successfully processed', '--log-file: contains records');
  if (!content.includes('\x1b')) ok('--log-file: no ANSI escapes'); else bad('--log-file: no ANSI', 'escapes found');
});

section('selection');

test('select: directory argument, recursive', () => {
  fs.mkdirSync(w('src', 'deep'), { recursive: true });
  writeFixture2('src/a.php', `${BOM}3c3f7068700d0a`);
  writeFixture2('src/deep/b.php', `${BOM}3c3f7068700d0a`);
  writeFixture2('outside.js', `${BOM}7661722078${CRLF}`);
  tool('--quiet', 'src');
  assertBytes2('src/a.php', 'directory arg: file cleaned', '3c3f7068700a');
  assertBytes2('src/deep/b.php', 'directory arg: nested file cleaned', '3c3f7068700a');
  assertBytes2('outside.js', 'directory arg: outside untouched', `${BOM}7661722078${CRLF}`);
});
function writeFixture2(rel, hex) { fs.writeFileSync(w(...rel.split('/')), Buffer.from(hex, 'hex')); }
function assertBytes2(rel, name, wantHex) {
  const got = fs.readFileSync(w(...rel.split('/'))).toString('hex');
  if (got === wantHex) ok(name); else bad(name, `${rel}: got [${got}] want [${wantHex}]`);
}

test('select: default recursive scan', () => {
  fs.mkdirSync(w('sub'), { recursive: true });
  writeFixture2('sub/s.css', `${BOM}780d0a`);
  tool('--quiet');
  assertBytes2('sub/s.css', 'no args: recursive scan from CWD', '780a');
});

test('select: --ext / --add-ext', () => {
  writeFixture('e.php', `${BOM}780d0a`);
  writeFixture('e.md', `${BOM}780d0a`);
  tool('--quiet', '--ext', 'md', '.');
  assertBytes('e.php', '--ext: replaces defaults (php untouched)', `${BOM}780d0a`);
  assertBytes('e.md', '--ext: md processed', '780a');
  writeFixture('e2.md', `${BOM}780d0a`);
  tool('--quiet', '--add-ext', 'md', '.');
  assertBytes('e2.md', '--add-ext: extends defaults', '780a');
  assertBytes('e.php', '--add-ext: defaults still processed', '780a');
});

test('select: exclusions', () => {
  fs.mkdirSync(w('node_modules', 'pkg'), { recursive: true });
  fs.mkdirSync(w('.git'), { recursive: true });
  fs.mkdirSync(w('vendor'), { recursive: true });
  fs.mkdirSync(w('dist'), { recursive: true });
  writeFixture2('node_modules/pkg/i.js', `${BOM}780d0a`);
  writeFixture2('.git/g.php', `${BOM}780d0a`);
  writeFixture2('vendor/v.php', `${BOM}780d0a`);
  writeFixture2('dist/d.js', `${BOM}780d0a`);
  writeFixture2('ok.php', `${BOM}780d0a`);
  tool('--quiet', '--exclude', 'dist/*');
  assertBytes2('node_modules/pkg/i.js', 'default exclusion: node_modules untouched', `${BOM}780d0a`);
  assertBytes2('.git/g.php', 'default exclusion: .git untouched', `${BOM}780d0a`);
  assertBytes2('vendor/v.php', 'vendor processed by default', '780a');
  assertBytes2('dist/d.js', '--exclude glob: dist untouched', `${BOM}780d0a`);
  assertBytes2('ok.php', 'normal file cleaned', '780a');
  tool('--quiet', '--no-default-excludes');
  assertBytes2('node_modules/pkg/i.js', '--no-default-excludes: node_modules processed', '780a');
});

test('select: --max-size', () => {
  const big = Buffer.concat([Buffer.from(BOM, 'hex'), Buffer.alloc(20 * 1024, 0x78), Buffer.from(CRLF, 'hex')]);
  fs.writeFileSync(w('big.php'), big);
  const r = tool('--max-size', '10K', 'big.php');
  assertRc(r, 0, '--max-size: exit 0');
  assertGrep(r.stderr, 'oversize', '--max-size: skip reported');
  assertBytes('big.php', '--max-size: oversized untouched', big.toString('hex'));
  tool('--max-size', '100K', 'big.php');
  const cleaned = Buffer.concat([Buffer.alloc(20 * 1024, 0x78), Buffer.from('0a', 'hex')]);
  assertBytes('big.php', '--max-size 100K: now cleaned', cleaned.toString('hex'));
  assertRc(tool('--max-size', 'bogus', 'big.php'), 2, '--max-size bogus: exit 2');
});

test('select: --git mode', () => {
  if (!HAVE_GIT) { ok('--git: SKIPPED (git unavailable)'); return; }
  const cwd = path.join(WS, 'work');
  const g = (...a) => spawnSync('git', a, { cwd, stdio: 'ignore' });
  g('init', '-q', '.');
  g('config', 'user.email', 't@t.t');
  g('config', 'user.name', 't');
  writeFixture('tracked.php', `${BOM}747261636b65640d0a`);
  writeFixture('untracked.php', `${BOM}756e747261636b65640d0a`);
  g('add', 'tracked.php');
  g('-c', 'commit.gpgsign=false', 'commit', '-qm', 'init');
  tool('--quiet', '--git');
  assertBytes('tracked.php', '--git: tracked file cleaned', '747261636b65640a');
  assertBytes('untracked.php', '--git: untracked untouched', `${BOM}756e747261636b65640d0a`);
});

section('CLI contract');

test('cli: unknown option / bare dash', () => {
  const r1 = tool('--bogus-option');
  assertRc(r1, 2, 'unknown long option: exit 2');
  assertGrep(r1.stderr, 'Unknown option: --bogus-option', 'unknown option: message');
  const r2 = tool('-');
  assertRc(r2, 2, "bare '-': exit 2 (v2 contract)");
  assertGrep(r2.stderr, 'Unknown option: -', "bare '-': message");
});

test('cli: -- terminator with dash filename', () => {
  writeFixture('-weird-.php', `${BOM}780d0a`);
  const r = tool('--quiet', '--', '-weird-.php');
  assertRc(r, 0, "'--' terminator: exit 0");
  assertBytes('-weird-.php', "'--': dash-prefixed filename processed", '780a');
});

test('cli: missing file → exit 1 (v2 gave 0)', () => {
  const r = tool('--quiet', 'nope.php');
  assertRc(r, 1, 'missing file: exit 1');
  assertGrep(r.stderr, 'File not found: nope.php', 'missing file: message');
});

test('cli: mixed success + failure → exit 1', () => {
  writeFixture('good.php', `${BOM}780d0a`);
  const r = tool('--quiet', 'good.php', 'missing.php');
  assertRc(r, 1, 'one good + one missing: exit 1');
  assertBytes('good.php', 'good file still processed', '780a');
});

test('cli: interspersed options', () => {
  writeFixture('i.php', `${BOM}780d0a`);
  const r = tool('--quiet', 'i.php', '--dry-run');
  assertRc(r, 0, 'interspersed: exit 0');
  assertBytes('i.php', 'interspersed: --dry-run after path honored', `${BOM}780d0a`);
});

test('cli: help/version/completion', () => {
  const h = tool('--help');
  assertRc(h, 0, '--help: exit 0');
  assertGrep(h.stdout, 'USAGE', '--help: USAGE');
  assertGrep(h.stdout, 'SMART BOM POLICY', '--help: Smart BOM Policy section');
  assertGrep(h.stdout, 'EXIT CODES', '--help: EXIT CODES');
  const hb = tool('--help', 'bom-policy');
  assertRc(hb, 0, '--help bom-policy: exit 0');
  assertGrep(hb.stdout, 'DECISION TABLE', '--help bom-policy: decision table');
  assertRc(tool('--help', 'nosuchtopic'), 2, '--help nosuchtopic: exit 2');
  assertRc(tool('-h'), 0, '-h: exit 0 (full help)');
  const v = tool('--version');
  assertRc(v, 0, '--version: exit 0');
  assertGrep(v.stdout, 'version 3.0.0', '--version: prints version');
  const c = tool('--completion');
  assertRc(c, 0, '--completion: exit 0');
  assertGrep(c.stdout, 'complete -F _clean_bom_senior', '--completion: bash completion');
});

test('cli: CLEAN_BOM_OPTS env', () => {
  writeFixture('env.php', `${BOM}780d0a`);
  toolEnv({ CLEAN_BOM_OPTS: '--dry-run' }, 'env.php');
  assertBytes('env.php', 'CLEAN_BOM_OPTS=--dry-run honored', `${BOM}780d0a`);
});

test('cli: color modes', () => {
  writeFixture('a.php', `${BOM}780d0a`);
  assertGrep(tool('--color=always', 'a.php').stderr, '\x1b', '--color=always: ANSI even when piped');
  writeFixture('a2.php', `${BOM}780d0a`);
  assertNotGrep(tool('--color=never', 'a2.php').stderr, '\x1b', '--color=never: no ANSI');
  writeFixture('a3.php', `${BOM}780d0a`);
  assertGrep(toolEnv({ NO_COLOR: '1' }, '--color=always', 'a3.php').stderr, '\x1b', '--color=always beats NO_COLOR');
});

test('cli: summary counts on a mixed tree', () => {
  writeFixture('s1.php', `${BOM}610d0a`);
  fs.writeFileSync(w('s2.php'), 'clean\n');
  writeFixture('s3.txt', 'fffe78000d0a');
  writeFixture('s4.txt', `${BOM}636166c3a90a`);
  const r = tool('.');
  assertGrep(r.stderr, 'Files scanned: 4', 'summary: scanned=4');
  assertGrep(r.stderr, 'Files processed: 1', 'summary: processed=1');
  assertGrep(r.stderr, 'Files skipped (clean): 1', 'summary: clean=1');
  assertGrep(r.stderr, 'BOM signatures removed: 1', 'summary: bom removed=1');
  assertGrep(r.stderr, 'UTF-8 BOM kept (may be required): 1', 'summary: kept=1');
  assertGrep(r.stderr, 'UTF-16/UTF-32 files (BOM required): 1', 'summary: protected utf16=1');
});

test('cli: special filenames (space, quote)', () => {
  writeFixture('with space.php', `${BOM}780d0a`);
  fs.writeFileSync(w("quote'file.php"), Buffer.from(`${BOM}780d0a`, 'hex'));
  const r = tool('--quiet', 'with space.php', "quote'file.php");
  assertRc(r, 0, 'special filenames: exit 0');
  assertBytes('with space.php', 'filename with space processed', '780a');
  assertBytes("quote'file.php", 'filename with quote processed', '780a');
});

test('cli: json escapes a filename with a double quote', () => {
  fs.writeFileSync(w('we"ird.php'), Buffer.from(`${BOM}780d0a`, 'hex'));
  const r = tool('--json', '--check', '.');
  try { JSON.parse(r.stdout); ok('json: quote in filename escaped correctly'); }
  catch { bad('json escaping', 'stdout not valid JSON'); }
});

test('cli: --self-test', () => {
  const r = spawnSync(process.execPath, [BOM_JS, '--self-test'], { cwd: path.join(WS, 'work'), encoding: 'utf8' });
  if (r.status === 0) ok('--self-test: passes on this machine'); else bad('--self-test', `rc=${r.status}\n${r.stdout}`);
  assertGrep(r.stdout, 'self-test:', '--self-test: reports');
});

section('auto-update (local HTTP "repository")');

async function withFakeRepo(version, scriptContent, fn) {
  const http = await import('node:http');
  const repoDir = path.join(WS, 'fakerepo');
  fs.mkdirSync(repoDir, { recursive: true });
  fs.writeFileSync(path.join(repoDir, 'VERSION'), `${version}\n`);
  fs.writeFileSync(path.join(repoDir, 'bom.js'), scriptContent);
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent(req.url.split('?')[0]);
    const file = path.join(repoDir, urlPath === '/bin/bom.js' ? 'bom.js' : urlPath.replace(/^\//, ''));
    try {
      const data = fs.readFileSync(file);
      res.writeHead(200); res.end(data);
    } catch {
      res.writeHead(404); res.end('nope');
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  try {
    await fn(`http://127.0.0.1:${port}`);
  } finally {
    server.close();
  }
}

test('update: check-update detects a newer version (exit 11)', async () => {
  const self = fs.readFileSync(BOM_JS, 'utf8');
  const newer = self.replace("const VERSION = '3.0.0'", "const VERSION = '9.9.9'");
  await withFakeRepo('9.9.9', newer, async (base) => {
    const installed = w('installed.js');
    fs.copyFileSync(BOM_JS, installed);
    const r = await toolAsync(['--check-update'], { CLEAN_BOM_UPDATE_URL: base });
    // note: runs the repo copy; version comparison is 3.0.0 vs 9.9.9
    if (r.rc === 11) ok('--check-update: exit 11 when newer exists'); else bad('--check-update exit 11', `rc=${r.rc}\n${r.stderr.slice(0, 300)}`);
    assertGrep(r.stderr, 'Update available: 3.0.0 -> 9.9.9', '--check-update: announces versions');
  });
});

test('update: up-to-date exits 0', async () => {
  await withFakeRepo('3.0.0', '', async (base) => {
    const r = await toolAsync(['--check-update'], { CLEAN_BOM_UPDATE_URL: base });
    assertRc(r, 0, '--check-update: exit 0 when up to date');
  });
});

test('update: --update replaces the running script and verifies it', async () => {
  const self = fs.readFileSync(BOM_JS, 'utf8');
  const newer = self.replace("const VERSION = '3.0.0'", "const VERSION = '9.9.9'");
  await withFakeRepo('9.9.9', newer, async (base) => {
    const installed = w('installed.js');
    fs.copyFileSync(BOM_JS, installed);
    const r = await spawnAsync(installed, ['--update'], { CLEAN_BOM_UPDATE_URL: base });
    if (r.rc === 0) ok('--update: exit 0'); else bad('--update exit 0', `rc=${r.rc}\n${(r.stderr || '').slice(0, 400)}`);
    const v = spawnSync(process.execPath, [installed, '--version'], { encoding: 'utf8' });
    if (v.stdout.includes('9.9.9')) ok('--update: script replaced with the new version');
    else bad('--update: new version', v.stdout.slice(0, 200));
  });
});

test('update: tampered download is refused (exit 3), file unchanged', async () => {
  const self = fs.readFileSync(BOM_JS, 'utf8'); // stamp says 3.0.0, VERSION says 9.9.8
  await withFakeRepo('9.9.8', self, async (base) => {
    const installed = w('installed.js');
    fs.copyFileSync(BOM_JS, installed);
    const before = fs.readFileSync(installed).toString('hex');
    const r = await spawnAsync(installed, ['--update'], { CLEAN_BOM_UPDATE_URL: base });
    if (r.rc === 3) ok('--update: verification failure exits 3'); else bad('--update verify exit 3', `rc=${r.rc}`);
    assertGrep(r.stderr || '', 'refusing to install', '--update: refusal explained');
    const after = fs.readFileSync(installed).toString('hex');
    if (before === after) ok('--update: failed update leaves the script byte-identical');
    else bad('--update: script unchanged on failure', 'bytes differ');
  });
});

section('repository consistency');

test('repo: version consistency across artifacts', () => {
  const shSrc = fs.readFileSync(path.join(REPO_ROOT, 'clean-bom-senior.sh'), 'utf8');
  const shVer = /^VERSION="([0-9.]+)"/m.exec(shSrc)[1];
  const jsVer = /^const VERSION = '([0-9.]+)';/m.exec(fs.readFileSync(BOM_JS, 'utf8'))[1];
  const pkgVer = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8')).version;
  const verFile = fs.readFileSync(path.join(REPO_ROOT, 'VERSION'), 'utf8').trim();
  const all = [shVer, jsVer, pkgVer, verFile];
  if (all.every((v) => v === shVer)) ok(`versions consistent: ${shVer} (sh, node, package.json, VERSION)`);
  else bad('versions consistent', JSON.stringify({ shVer, jsVer, pkgVer, verFile }));
});

test('repo: differential sh vs node on shared fixtures', () => {
  // The two v3 implementations must produce IDENTICAL bytes for the same
  // inputs — the core promise of the one-contract design.
  const shTool = path.join(REPO_ROOT, 'clean-bom-senior.sh');
  if (!fs.existsSync(shTool)) { ok('differential: SKIPPED (sh reference missing)'); return; }
  const fixtures = {
    'f1.php': `${BOM}3c3f7068700d0a6563686f20313b0d0a`,
    'f2.txt': `${BOM}636166c3a90d0a`,
    'f3.txt': 'fffe68000d0a5a5a',
    'f4.js':  `42494e004152590d0a`,
    'f5.php': `${BOM}c0c10d0a`,
    'f6.css': `636c65616e0a`,
    'f7.htm': `${BOM}6d69786564`,
    'f8.xml': `780d0d0a790d0a`,
  };
  const dirs = {};
  for (const impl of ['sh', 'node']) {
    const d = path.join(WS, `diff-${impl}`);
    fs.mkdirSync(d, { recursive: true });
    for (const [name, hex] of Object.entries(fixtures)) fs.writeFileSync(path.join(d, name), Buffer.from(hex, 'hex'));
    dirs[impl] = d;
  }
  spawnSync('bash', [shTool, '--quiet'], { cwd: dirs.sh, stdio: 'ignore' });
  spawnSync(process.execPath, [BOM_JS, '--quiet'], { cwd: dirs.node, stdio: 'ignore' });
  let same = 0; const diffs = [];
  for (const name of Object.keys(fixtures)) {
    const a = fs.readFileSync(path.join(dirs.sh, name)).toString('hex');
    const b = fs.readFileSync(path.join(dirs.node, name)).toString('hex');
    if (a === b) same++; else diffs.push(`${name}: sh=[${a}] node=[${b}]`);
  }
  if (diffs.length === 0) ok(`differential: ${same}/${same} fixtures byte-identical between sh and node`);
  else bad('differential sh vs node', diffs.join('\n'));
});

//-----------------------------------------------------------------------------
// Runner
//-----------------------------------------------------------------------------
process.stdout.write('Clean BOM Senior v3 — Node.js implementation test suite\n');
process.stdout.write(`impl: ${BOM_JS}\nplatform: ${process.platform}  node: ${process.version}  git: ${HAVE_GIT}\n`);

let selected = tests;
if (FILTER) selected = tests.filter(([n]) => n.includes(FILTER));

for (const [name, fn] of selected) {
  newWs();
  try {
    await fn();
  } catch (e) {
    bad(`${name}: EXCEPTION`, e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : String(e));
  }
}

process.stdout.write('\n----------------------------------------\n');
if (FAIL === 0) {
  process.stdout.write(`${color.grn}ALL PASSED${color.rst}: ${PASS} assertions\n`);
} else {
  process.stdout.write(`${color.red}FAILURES${color.rst}: ${PASS} passed, ${FAIL} failed\n`);
  process.stdout.write(`failed tests:${FAILED.map((f) => `\n  - ${f}`).join('')}\n`);
}
if (WS) fs.rmSync(WS, { recursive: true, force: true });
process.exit(FAIL === 0 ? 0 : 1);
