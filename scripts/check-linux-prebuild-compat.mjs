#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';

const allowedGlibc = [2, 36];
const dirs = process.argv.slice(2);
const repoRoot = process.cwd();

if (dirs.length === 0) {
  console.error('Usage: node scripts/check-linux-prebuild-compat.mjs prebuilds/linux-x64 [prebuilds/linux-arm64 ...]');
  process.exit(1);
}

function runReadelf(args) {
  return execFileSync('readelf', args, { encoding: 'utf8' });
}

function isElfCandidate(fileName) {
  return fileName.endsWith('.node') || fileName.includes('.so');
}

function compareVersion(a, b) {
  return a[0] === b[0] ? a[1] - b[1] : a[0] - b[0];
}

function dockerPlatformForDir(dir) {
  const name = path.basename(dir);
  if (name === 'linux-x64') return 'linux/amd64';
  if (name === 'linux-arm64') return 'linux/arm64';
  return null;
}

function localArchMatchesDir(dir) {
  const name = path.basename(dir);
  return process.platform === 'linux'
    && ((name === 'linux-x64' && process.arch === 'x64')
      || (name === 'linux-arm64' && process.arch === 'arm64'));
}

function commandExists(command) {
  const result = spawnSync(command, ['--version'], { encoding: 'utf8', stdio: 'ignore' });
  return !result.error;
}

function runDocker(args, options = {}) {
  return spawnSync('docker', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: options.stdio || 'pipe',
  });
}

function shellQuote(value) {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function validateRuntimeLocally(dir, failures) {
  if (!localArchMatchesDir(dir)) return;

  for (const file of readdirSync(dir).filter(isElfCandidate)) {
    const fullPath = path.join(dir, file);
    const result = spawnSync('ldd', [fullPath], { cwd: repoRoot, encoding: 'utf8' });
    const output = `${result.stdout || ''}${result.stderr || ''}`;
    process.stdout.write(`ldd ${fullPath}\n${output}`);
    if (result.status !== 0 || output.includes('not found')) {
      failures.push(`${fullPath}: ldd failed or reported a missing dependency`);
    }
  }

  const importResult = spawnSync(process.execPath, [
    '-e',
    "import('wsjtx-lib').then(()=>console.log('wsjtx-lib import ok')).catch((error)=>{console.error(error); process.exit(42);})",
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, PREBUILDS_ONLY: '1' },
  });
  if (importResult.stdout) process.stdout.write(importResult.stdout);
  if (importResult.stderr) process.stderr.write(importResult.stderr);
  if (importResult.status !== 0) {
    failures.push(`${dir}: local runtime import failed (exit ${importResult.status})`);
  }
}

function validateInDocker(dir, failures) {
  const platform = dockerPlatformForDir(dir);
  if (!platform) return;

  if (!commandExists('docker')) {
    console.warn(`Docker runtime validation skipped for ${dir}: docker not available`);
    validateRuntimeLocally(dir, failures);
    return;
  }

  const probe = runDocker(['run', '--rm', '--platform', platform, 'node:22-slim', 'uname', '-m']);
  if (probe.status !== 0) {
    console.warn(`Docker runtime validation skipped for ${dir}: ${platform} is not runnable here`);
    const detail = (probe.stderr || probe.stdout || '').trim();
    if (detail) console.warn(detail);
    validateRuntimeLocally(dir, failures);
    return;
  }

  const mountedDir = `/work/${dir.replace(/^\.\//, '')}`;
  const script = `
    set -euo pipefail
    dir=${shellQuote(mountedDir)}
    for file in "$dir"/*.node "$dir"/*.so "$dir"/*.so.*; do
      [ -f "$file" ] || continue
      echo "ldd $file"
      output=$(ldd "$file")
      printf '%s\\n' "$output"
      if printf '%s\\n' "$output" | grep -q 'not found'; then
        exit 41
      fi
    done
    PREBUILDS_ONLY=1 node -e "import('wsjtx-lib').then(()=>console.log('wsjtx-lib import ok')).catch((error)=>{console.error(error); process.exit(42);})"
  `;

  const result = runDocker([
    'run',
    '--rm',
    '--platform',
    platform,
    '-v',
    `${repoRoot}:/work:ro`,
    '-w',
    '/work',
    'node:22-slim',
    'bash',
    '-lc',
    script,
  ], { stdio: 'pipe' });

  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) {
    failures.push(`${dir}: Docker ${platform} runtime validation failed (exit ${result.status})`);
  }
}

const failures = [];

for (const dir of dirs) {
  if (!existsSync(dir)) {
    failures.push(`${dir}: directory does not exist`);
    continue;
  }

  const files = readdirSync(dir)
    .filter(isElfCandidate)
    .map((fileName) => path.join(dir, fileName));

  if (files.length === 0) {
    failures.push(`${dir}: no ELF candidates found`);
    continue;
  }

  for (const file of files) {
    const programHeaders = runReadelf(['-W', '-l', file]);
    const stackLine = programHeaders.split('\n').find((line) => line.includes('GNU_STACK'));
    const stackFlags = stackLine?.trim().split(/\s+/).at(-2) || '';
    console.log(`GNU_STACK ${file}: ${stackFlags || 'missing'}`);
    if (!stackFlags) {
      failures.push(`${file}: missing GNU_STACK program header`);
    } else if (stackFlags.includes('E')) {
      failures.push(`${file}: executable stack is not allowed (${stackFlags})`);
    }

    const dynSymbols = runReadelf(['--dyn-syms', '--wide', file]);
    for (const match of dynSymbols.matchAll(/GLIBC_(\d+)\.(\d+)/g)) {
      const version = [Number(match[1]), Number(match[2])];
      if (compareVersion(version, allowedGlibc) > 0) {
        failures.push(`${file}: GLIBC_${match[1]}.${match[2]} exceeds Debian 12 / glibc 2.36 baseline`);
      }
    }
  }

  if (dir.endsWith('linux-arm64')) {
    const core = path.join(dir, 'libwsjtx_core.so');
    const dynamicSection = runReadelf(['-d', core]);
    if (/NEEDED.*libmvec\.so\.1/.test(dynamicSection)) {
      failures.push(`${core}: linux-arm64 prebuild must not depend on libmvec.so.1`);
    }
  }

  validateInDocker(dir, failures);
}

if (failures.length > 0) {
  console.error('Linux prebuild compatibility check failed:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Linux prebuild compatibility OK: glibc <= ${allowedGlibc.join('.')}`);
