// =============================================================================
// Rawaan DB runner — applies every migration, then runs every SQL test.
// =============================================================================
// In-process Postgres 17 (PGlite) with pgcrypto and PostGIS. No Docker, no psql.
//
//   node db/runner/run.mjs                       all migrations, all tests
//   node db/runner/run.mjs --exclude 000006      skip migrations/tests whose
//                                                filename contains the text
//                                                (repeatable)
//   node db/runner/run.mjs --tests d5            only tests whose name matches
//   node db/runner/run.mjs --sql probe.sql       run an extra file at the end
//
// Exit code 0 only when every migration applied and every test passed.
//
// SUPABASE STUBS. A real Supabase database ships the auth schema, the anon /
// authenticated / service_role roles, and default grants that expose every
// public table to anon and authenticated. The stubs below reproduce exactly
// those parts, so an RLS test here fails the same way it would on Supabase.
// Impersonate a user in a test with:
//   PERFORM set_config('request.jwt.claim.sub', '<uuid>', true);
//   SET LOCAL ROLE authenticated;   -- then RESET ROLE
// =============================================================================

import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { postgis } from '@electric-sql/pglite-postgis';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const args = process.argv.slice(2);
const excludes = [];
let testFilter = null;
let extraSql = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--exclude') excludes.push(args[++i]);
  else if (args[i] === '--tests') testFilter = args[++i];
  else if (args[i] === '--sql') extraSql = args[++i];
}
const kept = (f) => !excludes.some((x) => f.includes(x));

const SUPABASE_STUBS = `
  CREATE SCHEMA IF NOT EXISTS extensions;
  CREATE SCHEMA IF NOT EXISTS auth;
  CREATE SCHEMA IF NOT EXISTS storage;

  DO $$ BEGIN
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  EXCEPTION WHEN duplicate_object THEN NULL; END $$;

  CREATE TABLE auth.users (
    id uuid PRIMARY KEY, aud text, role text, email text, encrypted_password text,
    email_confirmed_at timestamptz, created_at timestamptz, updated_at timestamptz,
    raw_app_meta_data jsonb, raw_user_meta_data jsonb);

  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid $$;
  CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    )::text $$;

  GRANT USAGE ON SCHEMA public, extensions, auth TO anon, authenticated, service_role;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
`;

const db = await PGlite.create({ extensions: { pgcrypto, postgis } });
let failed = 0;

async function step(label, sql) {
  const notices = [];
  try {
    await db.exec(sql, { onNotice: (n) => notices.push(`${n.severity}: ${n.message}`) });
    console.log(`\n=== ${label}: OK`);
  } catch (e) {
    failed++;
    console.log(`\n=== ${label}: ERROR -> ${e.message}` +
      (e.where ? `\n   where: ${e.where}` : '') +
      (e.position ? `\n   at character ${e.position}` : ''));
  }
  for (const n of notices) console.log(`   ${n}`);
}

await step('supabase stubs', SUPABASE_STUBS);

const migDir = join(root, 'supabase', 'migrations');
for (const f of readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort().filter(kept))
  await step(`migration ${f}`, readFileSync(join(migDir, f), 'utf8'));

const testDir = join(root, 'db', 'tests');
for (const f of readdirSync(testDir).filter((f) => f.endsWith('.test.sql')).sort().filter(kept)
  .filter((f) => !testFilter || f.includes(testFilter))) {
  // Each test runs as the migration owner with a clean role/JWT state.
  await db.exec(`RESET ROLE; SELECT set_config('request.jwt.claim.sub', '', false);`);
  await step(`test ${f}`, readFileSync(join(testDir, f), 'utf8'));
}

if (extraSql) await step(`extra ${extraSql}`, readFileSync(resolve(extraSql), 'utf8'));

await db.close();
console.log(failed ? `\nFAILED: ${failed} step(s) errored.` : '\nALL GREEN.');
process.exit(failed ? 1 : 0);
