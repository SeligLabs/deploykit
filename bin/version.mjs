#!/usr/bin/env node
// deploykit's version bump: the app's version and build number in its root
// package.json, their single source of truth, and in any committed native
// project file that carries them too (dk_config version_files).
//
//   version.mjs <major|minor|patch|build> [--breaking] [--files "<file> ..."]
//   version.mjs set <x.y.z> [build] [--force] [--breaking] [--files "<file> ..."]
//
// Every bump increments the build number, which the app stores require to be
// unique per upload. `set` takes the build too (default: current + 1); it
// must be above the current one, as App Store Connect rejects one that isn't
// (--force lifts that, for resetting a version nothing has shipped with).
// --breaking: older app builds must update, so minBuild (the oldest build the
// API serves) becomes the new build.
//
// --files names the other files to rewrite, by kind:
//   *.plist        CFBundleShortVersionString and CFBundleVersion, where
//                  they hold a value (a $(MARKETING_VERSION) is left alone)
//   *.pbxproj      MARKETING_VERSION and CURRENT_PROJECT_VERSION, only where
//                  they equal the current version and build (an app's own
//                  placeholders are its Info.plist's business)
//   build.gradle   versionName and versionCode (build.gradle.kts likewise)
//   package.json   ignored (always written)
// Paths are relative to the app's root (DK_APP_ROOT, else the git checkout).

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';

const argv = process.argv.slice(2);
const flag = name => {
  const i = argv.indexOf(name);
  if (i === -1) return false;
  argv.splice(i, 1);
  return true;
};
const option = name => {
  const i = argv.indexOf(name);
  if (i === -1) return '';
  const [, value] = argv.splice(i, 2);
  return value ?? '';
};
const force = flag('--force');
const breaking = flag('--breaking');
const files = option('--files').split(/\s+/).filter(Boolean);
const [target, setVersion, setBuild] = argv;

if (!['major', 'minor', 'patch', 'build', 'set'].includes(target)) {
  console.error(
    'Usage: version.mjs <major|minor|patch|build> | set <x.y.z> [build] [--force] [--breaking] [--files "..."]',
  );
  process.exit(2);
}

const ROOT =
  process.env.DK_APP_ROOT ||
  execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const PACKAGE_JSON = resolve(ROOT, 'package.json');
const pkg = JSON.parse(readFileSync(PACKAGE_JSON, 'utf8'));
const current = { version: pkg.version, build: Number(pkg.build ?? 0) };
const [major, minor, patch] = current.version.split('.').map(Number);

const next = {
  version: {
    major: `${major + 1}.0.0`,
    minor: `${major}.${minor + 1}.0`,
    patch: `${major}.${minor}.${patch + 1}`,
    build: current.version,
    set: setVersion,
  }[target],
  build: target === 'set' && setBuild !== undefined ? Number(setBuild) : current.build + 1,
};

// set: three numbers (all CFBundleShortVersionString allows) and a build
// above the current one, or any positive build with --force.
if (target === 'set') {
  if (!/^\d+\.\d+\.\d+$/.test(next.version ?? '')) {
    console.error(`Version must be three numbers, like 1.2.3: '${next.version ?? ''}'`);
    process.exit(1);
  }
  if (!Number.isInteger(next.build) || next.build < 1) {
    console.error(`Build must be a whole number above 0: '${setBuild}'`);
    process.exit(1);
  }
  if (!force && next.build <= current.build) {
    console.error(`Build must be above ${current.build} (--force to allow): '${setBuild}'`);
    process.exit(1);
  }
}

// Each native file is read and checked before anything is written, so a
// file the bump can't find its numbers in leaves every file as it was.
const writers = [];
for (const file of files) {
  const path = resolve(ROOT, file);
  const name = basename(file);
  if (name === 'package.json') continue;
  let text = readFileSync(path, 'utf8');
  const before = text;
  if (name.endsWith('.plist')) {
    text = text.replace(
      /(<key>CFBundleShortVersionString<\/key>\s*<string>)([^<$]*)(<\/string>)/,
      `$1${next.version}$3`,
    );
    text = text.replace(/(<key>CFBundleVersion<\/key>\s*<string>)([^<$]*)(<\/string>)/, `$1${next.build}$3`);
  } else if (name.endsWith('.pbxproj')) {
    text = text
      .split(`MARKETING_VERSION = ${current.version};`)
      .join(`MARKETING_VERSION = ${next.version};`)
      .split(`CURRENT_PROJECT_VERSION = ${current.build};`)
      .join(`CURRENT_PROJECT_VERSION = ${next.build};`);
  } else if (name === 'build.gradle' || name === 'build.gradle.kts') {
    text = text.replace(/versionName\s*(=\s*)?"[^"]*"/, m => m.replace(/"[^"]*"/, `"${next.version}"`));
    text = text.replace(/versionCode\s*(=\s*)?\d+/, m => m.replace(/\d+$/, String(next.build)));
  } else {
    console.error(`version.mjs doesn't know how to write ${file} (a .plist, .pbxproj or build.gradle).`);
    process.exit(1);
  }
  if (text === before && (current.version !== next.version || current.build !== next.build)) {
    console.error(`${file} holds neither the version nor the build to rewrite.`);
    process.exit(1);
  }
  writers.push(() => writeFileSync(path, text));
}

console.log(`\n  ✓ version  ${current.version} → ${next.version}`);
console.log(`  ✓ build    ${pkg.build} → ${next.build}`);
if (breaking) console.log(`  ✓ minBuild ${pkg.minBuild ?? 0} → ${next.build} (older builds must update)`);

pkg.version = next.version;
pkg.build = next.build;
if (breaking) pkg.minBuild = next.build;
writeFileSync(PACKAGE_JSON, `${JSON.stringify(pkg, null, 2)}\n`);
for (const write of writers) write();
for (const file of files) if (basename(file) !== 'package.json') console.log(`    ${file}`);
console.log('');
