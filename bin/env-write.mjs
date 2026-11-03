#!/usr/bin/env node
// env-write.mjs <file> "<only names>" "<except names>" < NAME=value lines
//
// Writes values into an env file in place: a key already there gets the new
// value on its own line (comments and order kept), a key it lacks is
// appended. A missing file starts from <file>.example when there is one.
// With only, just those names; with except, all but those. Used by
// `yarn deploy env-sync` (lib/outputs.sh). Prints what changed, never a value.

import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const [file, onlyArg = '', exceptArg = ''] = process.argv.slice(2);
const only = new Set(onlyArg.split(/\s+/).filter(Boolean));
const except = new Set(exceptArg.split(/\s+/).filter(Boolean));
const KEY_LINE = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/;

const values = new Map();
for (const line of readFileSync(0, 'utf8').split('\n')) {
  const i = line.indexOf('=');
  if (i < 1) continue;
  const key = line.slice(0, i);
  if (only.size && !only.has(key)) continue;
  if (except.has(key)) continue;
  values.set(key, line.slice(i + 1));
}

if (!existsSync(file) && existsSync(`${file}.example`)) copyFileSync(`${file}.example`, file);
const lines = existsSync(file) ? readFileSync(file, 'utf8').replace(/\n$/, '').split('\n') : [];
const seen = new Set();
let changed = 0;
const quote = v => (/[\s#"'$`\\]/.test(v) ? `"${v.replace(/(["\\$`])/g, '\\$1')}"` : v);
const out = lines.map(line => {
  const m = KEY_LINE.exec(line);
  if (!m || !values.has(m[1])) return line;
  seen.add(m[1]);
  const next = `${m[1]}=${quote(values.get(m[1]))}`;
  if (next !== line) changed += 1;
  return next;
});
// Appended keys go under one marker line, as the apps' env-sync scripts
// wrote them.
const missing = [...values].filter(([key]) => !seen.has(key));
if (missing.length) out.push('', '# ── Added by yarn env:sync ──');
for (const [key, value] of missing) {
  out.push(`${key}=${quote(value)}`);
  changed += 1;
}
writeFileSync(file, `${out.join('\n')}\n`);
console.log(`✓ env/${basename(file)} ← terraform outputs (${values.size} values, ${changed} changed)`);
