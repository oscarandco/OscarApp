import assert from 'node:assert/strict'
import { readdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { localDir, root, sql } from './runtime.mjs'

try {
  const sources = await readdir(join(root, 'src'), { recursive: true })
  const references = new Set()
  for (const path of sources.filter((path) => /\.tsx?$/.test(path))) {
    const source = await readFile(join(root, 'src', path), 'utf8')
    for (const match of source.matchAll(/\.rpc\(\s*['"]([a-z_0-9]+)['"]/g)) references.add(match[1])
  }
  const migrations = (await readdir(join(root, 'supabase/migrations')))
    .filter((path) => path.endsWith('.sql')).sort()
  const inventory = JSON.parse(sql(`
    select jsonb_build_object(
      'migration_history_present', to_regclass('supabase_migrations.schema_migrations') is not null,
      'functions', (select jsonb_agg(jsonb_build_object(
        'name', p.proname, 'arguments', pg_get_function_identity_arguments(p.oid),
        'definition_md5', md5(pg_get_functiondef(p.oid))) order by p.proname, p.oid)
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.prokind='f'),
      'views', (select jsonb_agg(jsonb_build_object(
        'name', c.relname, 'definition_md5', md5(pg_get_viewdef(c.oid, true))) order by c.relname)
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='v')
    );`))
  const available = new Set(inventory.functions.map((fn) => fn.name))
  const missing = [...references].filter((name) => !available.has(name)).sort()
  await writeFile(join(localDir, 'schema-audit.json'), `${JSON.stringify({
    capturedAt: new Date().toISOString(), frontendRpcNames: [...references].sort(),
    missingFrontendRpcs: missing, repositoryMigrations: migrations, ...inventory,
    scope: 'Name coverage and local definition fingerprints; not a full replay or semantic comparison of migration DDL.',
  }, null, 2)}\n`, { mode: 0o600 })
  assert.equal(missing.length, 0, `Missing frontend RPCs: ${missing.join(', ')}`)
  console.log(`PASS: all ${references.size} literal frontend RPC names exist in the restored database.`)
  console.log(`Recorded ${migrations.length} repository migration files and local function/view fingerprints.`)
  console.log(inventory.migration_history_present
    ? 'Migration-history table exists; reconcile its entries before applying feature migrations.'
    : 'Migration-history table is absent. Do not replay the migration folder or mark its files applied without schema reconciliation.')
  console.log('Report: local-db.local/schema-audit.json. No schema or migration-history changes made.')
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}
