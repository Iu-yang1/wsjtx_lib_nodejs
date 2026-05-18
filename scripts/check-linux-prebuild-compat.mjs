#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';

const allowedGlibc = [2, 36];
const dirs = process.argv.slice(2);

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

const failures = [];

for (const dir of dirs) {
  const files = readdirSync(dir)
    .filter(isElfCandidate)
    .map((fileName) => path.join(dir, fileName));

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
}

if (failures.length > 0) {
  console.error('Linux prebuild compatibility check failed:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Linux prebuild compatibility OK: glibc <= ${allowedGlibc.join('.')}`);
