// The fixture's version command: <build|patch|minor|major> or set <v> <b> [--breaking].
import { readFileSync, writeFileSync } from 'node:fs';
const p = new URL('../package.json', import.meta.url);
const pkg = JSON.parse(readFileSync(p, 'utf8'));
const [cmd, a, b] = process.argv.slice(2);
const [M, m, pa] = pkg.version.split('.').map(Number);
if (cmd === 'set') { pkg.version = a; pkg.build = Number(b); }
else {
  pkg.build += 1;
  if (cmd === 'patch') pkg.version = `${M}.${m}.${pa + 1}`;
  if (cmd === 'minor') pkg.version = `${M}.${m + 1}.0`;
  if (cmd === 'major') pkg.version = `${M + 1}.0.0`;
}
if (process.argv.includes('--breaking')) pkg.minBuild = pkg.build;
writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
console.log(`  ✓ ${pkg.version} (${pkg.build})`);
