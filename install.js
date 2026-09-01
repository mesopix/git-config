#!/usr/bin/env node
/**
 * git-config-sync one-click installer / uninstaller.
 * Cross-platform: Windows / macOS / Linux — only requires Node.js and git.
 *
 * Usage:
 *   node install.js                          download config/gitconfig from GitHub and install
 *   node install.js /path/to/gitconfig       install from a local file
 *   curl -fsSL <url> | node                  remote install (downloads config/gitconfig from GitHub)
 *   node install.js --uninstall              remove the include.path entry and the managed gitconfig
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const { spawnSync } = require('child_process');

const REPO_RAW_BASE = 'https://raw.githubusercontent.com/mesopix/git-config/main';

const IS_WINDOWS = process.platform === 'win32';
const TOOL_NAME = 'git-config-sync';

const USAGE = `Usage:
  node install.js                        download config/gitconfig from GitHub and install
  node install.js /path/to/gitconfig     install from a local file
  node install.js --uninstall            remove the include.path entry and the managed gitconfig`;

// Colors: only when writing to a terminal (and NO_COLOR is unset), so
// piped output and log files stay free of ANSI escape codes.
const colorFor = (stream) =>
  (stream.isTTY && !process.env.NO_COLOR && process.TERM !== 'dumb')
    ? { green: '\x1b[32m', yellow: '\x1b[33m', red: '\x1b[31m', reset: '\x1b[0m' }
    : { green: '', yellow: '', red: '', reset: '' };
const OUT = colorFor(process.stdout);
const ERR = colorFor(process.stderr);

// okText/warnText build colored lines; ok prints one immediately. The
// install flow buffers its lines via okText/warnText instead, so a no-op
// run prints a single summary line rather than a multi-line report that
// reads like a failure.
function okText(msg) { return `${OUT.green}✓ ${msg}${OUT.reset}`; }
function warnText(msg) { return `${OUT.yellow}⚠ ${msg}${OUT.reset}`; }
function ok(msg) { console.log(okText(msg)); }

function die(msg) {
  console.error(`${ERR.red}Error: ${msg}${ERR.reset}`);
  if (DOWNLOADED_SELF && fs.existsSync(DOWNLOADED_SELF)) {
    console.error(`(the installer was kept at ${DOWNLOADED_SELF}; fix the problem and re-run: node install.js)`);
  }
  process.exit(1);
}

// The Windows flow "curl.exe -o install.js && node install.js" is the only
// mode that leaves install.js on disk (curl | node piping never writes a
// file). Detect that lone downloaded copy — but never one inside a repo.
const DOWNLOADED_SELF = (() => {
  const self = process.argv[1];
  if (!self) return null; // piped via stdin
  const resolved = path.resolve(self);
  if (path.basename(resolved).toLowerCase() !== 'install.js') return null;
  // Compare real paths: argv[1] and cwd may differ by symlinks (/var vs
  // /private/var on macOS) even when they denote the same directory.
  let dir;
  try {
    dir = fs.realpathSync(path.dirname(resolved));
  } catch (e) {
    return null;
  }
  if (dir !== fs.realpathSync(process.cwd())) return null;
  if (fs.existsSync(path.join(dir, 'config', 'gitconfig'))) return null; // repo clone
  if (fs.existsSync(path.join(dir, '.git'))) return null; // repo clone
  return resolved;
})();

// Remove the downloaded installer after a successful run. On failure it is
// deliberately kept so the user can fix the problem and re-run directly.
function cleanupDownloadedSelf() {
  if (DOWNLOADED_SELF && fs.existsSync(DOWNLOADED_SELF)) {
    try {
      fs.unlinkSync(DOWNLOADED_SELF);
      ok(`removed downloaded installer: ${DOWNLOADED_SELF}`);
    } catch (e) {
      console.log(`(you can delete the installer manually: ${DOWNLOADED_SELF})`);
    }
  }
}

// ── Download (follows redirects, e.g. repo renames) ─────
function download(url, redirectsLeft) {
  redirectsLeft = redirectsLeft === undefined ? 5 : redirectsLeft;
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'git-config-sync-installer' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        if (redirectsLeft <= 0) return reject(new Error('too many redirects'));
        return resolve(download(res.headers.location, redirectsLeft - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`download failed: HTTP ${res.statusCode} (${url})`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
}

// ── Managed locations ───────────────────────────────────
// Same directories the previous Go build used (Go's os.UserConfigDir
// semantics), so an existing include.path keeps pointing at the right file
// and is simply updated in place.
function userConfigDir() {
  if (IS_WINDOWS) {
    if (!process.env.APPDATA) die('Environment variable APPDATA is not set; cannot determine the user config directory');
    return process.env.APPDATA;
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support');
  }
  return process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
}

const MANAGED_DIR = path.join(userConfigDir(), TOOL_NAME);
const MANAGED = path.join(MANAGED_DIR, 'gitconfig');
// git stores include.path verbatim; forward slashes work on every platform.
const MANAGED_INCLUDE = MANAGED.split(path.sep).join('/');

// ── git invocation ──────────────────────────────────────
function git(args) {
  const res = spawnSync('git', args, { encoding: 'utf8' });
  return {
    status: res.status,
    output: `${res.stdout || ''}${res.stderr || ''}`.trim(),
  };
}

function requireGit() {
  const res = spawnSync('git', ['--version'], { encoding: 'utf8' });
  if (res.status !== 0) {
    die('git not found: sync and syntax validation both require it. Install from https://git-scm.com/downloads');
  }
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Existing include.path values ([] when the key is absent, exit code 1).
function getIncludePaths() {
  const res = git(['config', '--global', '--get-all', 'include.path']);
  if (res.status !== 0) return [];
  return res.output ? res.output.split(/\r?\n/) : [];
}

function samePath(left, right) {
  const normalize = (p) => p.replace(/\\/g, '/');
  return IS_WINDOWS
    ? normalize(left).toLowerCase() === normalize(right).toLowerCase()
    : normalize(left) === normalize(right);
}

// Remove only the entries pointing at the managed file; include.path values
// belonging to other tools are preserved. Returns nothing; caller decides
// whether anything was expected to match.
function unsetIncludeEntries(spellings) {
  for (const stored of spellings) {
    const pattern = `^${escapeRegex(stored)}$`;
    const res = git(['config', '--global', '--unset-all', 'include.path', pattern]);
    if (res.status !== 0 && res.status !== 5) {
      die(`unable to update global include.path: ${res.output}`);
    }
  }
}

// ── include.path management ─────────────────────────────
// Idempotent: nothing is written when exactly one matching entry already
// exists. Duplicate or differently-spelled matches collapse into one.
function ensureInclude() {
  const notices = [];
  const matches = getIncludePaths().filter((p) => samePath(p, MANAGED_INCLUDE));
  if (matches.length === 1 && matches[0] === MANAGED_INCLUDE) {
    notices.push(okText(`global include.path already set: ${MANAGED_INCLUDE}`));
    return { changed: false, notices };
  }
  if (matches.length > 1) {
    notices.push(warnText(`found ${matches.length} duplicate include.path entries; merging into one`));
  }
  unsetIncludeEntries([...new Set(matches)]);
  const res = git(['config', '--global', '--add', 'include.path', MANAGED_INCLUDE]);
  if (res.status !== 0) die(`unable to write global include.path: ${res.output}`);
  notices.push(okText(`added include.path to global config: ${MANAGED_INCLUDE}`));
  return { changed: true, notices };
}

// ── Managed file install (temp + rename, atomic) ────────
// Validate the source via git BEFORE replacing anything, so a broken file
// aborts with the previous install untouched.
function installManaged(source) {
  const notices = [];
  const installed = fs.existsSync(MANAGED) ? fs.readFileSync(MANAGED) : null;
  if (installed !== null && installed.equals(source)) {
    notices.push(okText(`managed config is already up to date: ${MANAGED}`));
    return { changed: false, notices };
  }
  if (installed !== null) {
    notices.push(warnText('existing managed config differs from the source and will be overwritten — local changes will be lost'));
  }

  fs.mkdirSync(MANAGED_DIR, { recursive: true });
  // die() exits without running finally blocks, so clean the temp file up
  // explicitly before dying — otherwise it blocks a later uninstall's rmdir.
  const temp = path.join(MANAGED_DIR, `.gitconfig-${process.pid}.tmp`);
  fs.writeFileSync(temp, source);
  const check = git(['config', '--file', temp, '--list']);
  if (check.status !== 0) {
    try { fs.unlinkSync(temp); } catch (e) { /* best effort */ }
    die(`invalid gitconfig source:\n${check.output}`);
  }
  fs.renameSync(temp, MANAGED);
  notices.push(okText(`installed managed config: ${MANAGED}`));
  return { changed: true, notices };
}

// ── Source resolution ───────────────────────────────────
async function resolveSource(explicitPath) {
  if (explicitPath) {
    const p = path.resolve(explicitPath);
    if (!fs.existsSync(p)) die(`file not found: ${p}`);
    return { source: fs.readFileSync(p), notices: [okText(`using local source: ${p}`)] };
  }
  try {
    const source = await download(`${REPO_RAW_BASE}/config/gitconfig`);
    return { source, notices: [okText('fetched config/gitconfig from GitHub')] };
  } catch (e) {
    die(`${e.message}\nif the network is unavailable, download config/gitconfig manually, then run: node install.js /path/to/gitconfig`);
  }
}

// ── Install ─────────────────────────────────────────────
async function install(explicitPath) {
  requireGit();
  const { source, notices } = await resolveSource(explicitPath);
  const file = installManaged(source);
  const inc = ensureInclude();

  // Tailor the closing output: a no-op run prints one affirmative line,
  // so it can't be mistaken for a failure.
  if (!file.changed && !inc.changed) {
    console.log(`${OUT.green}Already up to date — nothing to do.${OUT.reset}`);
  } else {
    [...notices, ...file.notices, ...inc.notices].forEach((n) => console.log(n));
    console.log(`${OUT.green}Sync complete. Managed config overrides same-name global settings and takes effect immediately.${OUT.reset}`);
  }
  cleanupDownloadedSelf();
}

// ── Uninstall ───────────────────────────────────────────
function uninstall() {
  requireGit();
  const matches = getIncludePaths().filter((p) => samePath(p, MANAGED_INCLUDE));
  let changed = false;
  if (matches.length > 0) {
    unsetIncludeEntries([...new Set(matches)]);
    ok(`removed include.path entry pointing to the managed file: ${MANAGED_INCLUDE}`);
    changed = true;
  }
  if (fs.existsSync(MANAGED)) {
    fs.rmSync(MANAGED);
    ok(`deleted ${MANAGED}`);
    try { fs.rmdirSync(MANAGED_DIR); } catch (e) { /* directory not empty */ }
    changed = true;
  }
  if (changed) {
    console.log(`${OUT.green}Uninstall complete. Other global config and include.path entries were not touched.${OUT.reset}`);
  } else {
    console.log(`${OUT.green}Nothing to uninstall.${OUT.reset}`);
  }
  cleanupDownloadedSelf();
}

// ── Main ────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  if (args.includes('-h') || args.includes('--help')) {
    console.log(USAGE);
    return;
  }
  if (args.includes('--uninstall') || args.includes('-u')) {
    uninstall();
    return;
  }
  await install(args.find((a) => !a.startsWith('-')));
}

main().catch((e) => die(e.message));
