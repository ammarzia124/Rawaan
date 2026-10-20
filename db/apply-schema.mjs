// =============================================================================
// apply-schema.mjs — render every migration, in order, into one SQL script.
// =============================================================================
//   node db/apply-schema.mjs                          public schema, to stdout
//   node db/apply-schema.mjs --schema demo            demo variant, to stdout
//   node db/apply-schema.mjs --schema demo --out x.sql
//
// --schema <name> (default "public", meaning no rewrite) prepends
// CREATE SCHEMA IF NOT EXISTS <name>; and rewrites the ONLY places a schema
// name is allowed to appear in a migration:
//   SET search_path TO public, extensions;            (migration header)
//   SET search_path = public[, extensions], pg_temp   (SECURITY DEFINER pin)
// Everything else is unqualified by convention, so it follows search_path.
// A schema-qualified `public.` anywhere else would silently escape the
// rewrite, so the render refuses to run and lists each file:line.
// Node stdlib only.
// =============================================================================

import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const migDir = join(root, 'supabase', 'migrations');

const args = process.argv.slice(2);
let schema = 'public';
let out = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--schema') schema = args[++i];
  else if (args[i] === '--out') out = args[++i];
  else die(`unknown argument: ${args[i]}`);
}
if (!/^[a-z_][a-z0-9_]*$/.test(schema ?? '')) die(`invalid schema name: ${schema}`);
if (args.includes('--out') && !out) die('--out needs a file name');

function die(msg) {
  console.error(`apply-schema: ${msg}`);
  process.exit(1);
}

const HEADER = /^SET search_path TO public, extensions;$/gm;
const DEFINER = /SET search_path = public, (extensions, )?pg_temp\b/g;

const files = readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort();
const offenders = [];
const parts = schema === 'public' ? [] : [`CREATE SCHEMA IF NOT EXISTS ${schema};\n`];

for (const f of files) {
  const sql = readFileSync(join(migDir, f), 'utf8');
  sql.split('\n').forEach((line, i) => {
    const code = line.replace(HEADER, '').replace(DEFINER, '').replace(/--.*$/, '');
    if (/\bpublic\./i.test(code)) offenders.push(`${f}:${i + 1}: ${line.trim()}`);
  });
  const body = schema === 'public' ? sql : sql
    .replace(HEADER, `SET search_path TO ${schema}, extensions;`)
    .replace(DEFINER, (_, ext) => `SET search_path = ${schema}, ${ext ?? ''}pg_temp`);
  parts.push(`-- ---- ${f} ----\n${body}\n`);
}

if (offenders.length)
  die(`schema-qualified "public." found; objects must be unqualified:\n  ${offenders.join('\n  ')}`);

const rendered = parts.join('\n');
if (out) writeFileSync(resolve(out), rendered);
else process.stdout.write(rendered);
