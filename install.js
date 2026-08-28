#!/usr/bin/env node
/**
 * git-config-sync one-click installer / uninstaller.
 * Cross-platform: Windows / macOS / Linux — only requires Node.js and git.
 *
 * Usage:
 *   node install.js                          install from a cloned repo (reads config/gitconfig beside it)
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

const REPO_RAW_BASE = 'https://raw.githubusercontent.com/anonymous/git-config-sync/main';

const IS_WINDOWS = process.platform === 'win32';
const TOOL_NAME = 'git-config-sync';

const USAGE = `用法：
  node install.js                        在仓库目录内安装（读取旁边的 config/gitconfig）
  node install.js /path/to/gitconfig     从本地文件安装
  node install.js --uninstall            卸载（移除 include.path 条目并删除托管配置）`;

// Colors: only when writing to a terminal (and NO_COLOR is unset), so
// piped output and log files stay free of ANSI escape codes.
const colorFor = (stream) =>
  (stream.isTTY && !process.env.NO_COLOR && process.TERM !== 'dumb')
    ? { green: '\x1b[32m', yellow: '\x1b[33m', red: '\x1b[31m', reset: '\x1b[0m' }
    : { green: '', yellow: '', red: '', reset: '' };
const OUT = colorFor(process.stdout);
const ERR = colorFor(process.stderr);

function ok(msg) { console.log(`${OUT.green}✓ ${msg}${OUT.reset}`); }
function warn(msg) { console.log(`${OUT.yellow}⚠ ${msg}${OUT.reset}`); }

function die(msg) {
  console.error(`${ERR.red}错误：${msg}${ERR.reset}`);
  if (DOWNLOADED_SELF && fs.existsSync(DOWNLOADED_SELF)) {
    console.error(`（安装脚本保留在 ${DOWNLOADED_SELF}，修复后可直接 node install.js 重试）`);
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
      ok(`已清理下载的安装脚本：${DOWNLOADED_SELF}`);
    } catch (e) {
      console.log(`  （安装脚本可手动删除：${DOWNLOADED_SELF}）`);
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
        if (redirectsLeft <= 0) return reject(new Error('重定向次数过多'));
        return resolve(download(res.headers.location, redirectsLeft - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`下载失败：HTTP ${res.statusCode}（${url}）`));
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
    if (!process.env.APPDATA) die('环境变量 APPDATA 未设置，无法确定用户配置目录');
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
    die('未检测到 git：同步与语法校验都依赖它。安装见 https://git-scm.com/downloads');
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
      die(`无法更新全局 include.path：${res.output}`);
    }
  }
}

// ── include.path management ─────────────────────────────
// Idempotent: nothing is written when exactly one matching entry already
// exists. Duplicate or differently-spelled matches collapse into one.
function ensureInclude() {
  const matches = getIncludePaths().filter((p) => samePath(p, MANAGED_INCLUDE));
  if (matches.length === 1 && matches[0] === MANAGED_INCLUDE) {
    ok(`全局 include.path 已就绪：${MANAGED_INCLUDE}`);
    return false;
  }
  if (matches.length > 1) {
    warn(`检测到 ${matches.length} 条重复的 include.path，正在合并为一条`);
  }
  unsetIncludeEntries([...new Set(matches)]);
  const res = git(['config', '--global', '--add', 'include.path', MANAGED_INCLUDE]);
  if (res.status !== 0) die(`无法写入全局 include.path：${res.output}`);
  ok(`已在全局配置添加 include.path：${MANAGED_INCLUDE}`);
  return true;
}

// ── Managed file install (temp + rename, atomic) ────────
// Validate the source via git BEFORE replacing anything, so a broken file
// aborts with the previous install untouched.
function installManaged(source) {
  const installed = fs.existsSync(MANAGED) ? fs.readFileSync(MANAGED) : null;
  if (installed !== null && installed.equals(source)) {
    ok(`托管配置已是最新：${MANAGED}`);
    return false;
  }
  if (installed !== null) {
    warn('已存在的托管配置与安装源不同，将覆盖——本地修改会丢失');
  }

  fs.mkdirSync(MANAGED_DIR, { recursive: true });
  // die() exits without running finally blocks, so clean the temp file up
  // explicitly before dying — otherwise it blocks a later uninstall's rmdir.
  const temp = path.join(MANAGED_DIR, `.gitconfig-${process.pid}.tmp`);
  fs.writeFileSync(temp, source);
  const check = git(['config', '--file', temp, '--list']);
  if (check.status !== 0) {
    try { fs.unlinkSync(temp); } catch (e) { /* best effort */ }
    die(`源 gitconfig 无效：\n${check.output}`);
  }
  fs.renameSync(temp, MANAGED);
  ok(`已安装托管配置：${MANAGED}`);
  return true;
}

// ── Source resolution ───────────────────────────────────
async function resolveSource(explicitPath) {
  if (explicitPath) {
    const p = path.resolve(explicitPath);
    if (!fs.existsSync(p)) die(`找不到文件：${p}`);
    ok(`使用本地源文件：${p}`);
    return fs.readFileSync(p);
  }
  const local = path.join(process.cwd(), 'config', 'gitconfig');
  if (fs.existsSync(local)) {
    ok(`使用本地源文件：${local}`);
    return fs.readFileSync(local);
  }
  console.log('正在从 GitHub 下载 config/gitconfig …');
  try {
    return await download(`${REPO_RAW_BASE}/config/gitconfig`);
  } catch (e) {
    die(`${e.message}\n网络不通时可手动下载 config/gitconfig，再执行：node install.js /path/to/gitconfig`);
  }
}

// ── Install ─────────────────────────────────────────────
async function install(explicitPath) {
  requireGit();
  const source = await resolveSource(explicitPath);
  const fileChanged = installManaged(source);
  const includeChanged = ensureInclude();

  // Tailor the closing line so a no-op run doesn't read as if something
  // had been modified.
  console.log('');
  if (fileChanged || includeChanged) {
    console.log(`${OUT.green}同步完成。托管配置覆盖同名的既有全局配置，立即生效。${OUT.reset}`);
  } else {
    console.log(`${OUT.green}已是最新，未做任何改动。${OUT.reset}`);
  }
  cleanupDownloadedSelf();
}

// ── Uninstall ───────────────────────────────────────────
function uninstall() {
  requireGit();
  const matches = getIncludePaths().filter((p) => samePath(p, MANAGED_INCLUDE));
  if (matches.length > 0) {
    unsetIncludeEntries([...new Set(matches)]);
    ok(`已移除全局配置中指向托管文件的 include.path 条目：${MANAGED_INCLUDE}`);
  } else {
    console.log('全局配置中没有指向托管文件的 include.path，跳过。');
  }
  if (fs.existsSync(MANAGED)) {
    fs.rmSync(MANAGED);
    ok(`已删除 ${MANAGED}`);
    try { fs.rmdirSync(MANAGED_DIR); } catch (e) { /* directory not empty */ }
  } else {
    console.log(`未找到 ${MANAGED}，跳过。`);
  }
  console.log(`${OUT.green}卸载完成。其他全局配置与 include.path 条目均未改动。${OUT.reset}`);
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
