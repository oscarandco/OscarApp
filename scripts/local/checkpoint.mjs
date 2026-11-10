import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, docker, localDir, sql } from './runtime.mjs'

// A complete local checkpoint includes managed Auth/Storage definitions, unlike
// the original application-only schema export. Never restore over the working DB.
const scratch = `oscarapp_restore_check_${randomBytes(6).toString('hex')}`
const containerPath = `/tmp/${scratch}.dump`
const checkpointDir = join(localDir, 'checkpoints', new Date().toISOString().replaceAll(/[:.]/g, '-'))

function queryDatabase(database, query) {
  return docker(['exec', '-i', 'oscarapp-db', 'psql', '-U', 'supabase_admin',
    '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: query })
}

const fingerprintQuery = `
  select jsonb_build_object(
    'sales', (select count(*) from public.sales_transactions),
    'staff', (select count(*) from public.staff_members),
    'assignments', (select count(*) from public.staff_role_assignments),
    'plans', (select count(*) from public.remuneration_plans),
    'rates', (select count(*) from public.remuneration_plan_rates),
    'invoices', (select count(*) from public.contractor_invoices),
    'auth_users', (select count(*) from auth.users),
    'storage_objects', (select count(*) from storage.objects),
    'commission_digest', (select md5(string_agg(to_jsonb(c)::text, '' order by c.id))
      from public.v_commission_calculations_core c)
  );`

try {
  assertLocalDocker()
  assert.equal(Number(sql('select count(*) from private.sales_daily_sheets_import_config')), 0,
    'Production import configuration must be absent before checkpointing')
  await mkdir(checkpointDir, { recursive: true })
  const fingerprint = JSON.parse(queryDatabase('postgres', fingerprintQuery))
  docker(['exec', 'oscarapp-db', 'pg_dump', '-U', 'supabase_admin', '-d', 'postgres',
    '--format=custom', '--file', containerPath])
  const file = join(checkpointDir, 'database.dump')
  docker(['cp', `oscarapp-db:${containerPath}`, file])

  const roles = docker(['exec', 'oscarapp-db', 'pg_dumpall', '-U', 'supabase_admin', '--roles-only'])
  await writeFile(join(checkpointDir, 'roles.sql'), `${roles}\n`, { mode: 0o600 })

  // A random, newly created database in the local cluster proves the dump can be
  // restored with the existing Supabase roles/extensions. No active DB is reset.
  // pg_cron can only be installed in its configured database (postgres). Keep it
  // in the full recovery dump but omit its installation/data from this scratch
  // restore, which must never run the working database's scheduled jobs.
  const inventory = docker(['exec', 'oscarapp-db', 'pg_restore', '--list', containerPath]).split('\n')
  const cronEntry = /\b(?:EXTENSION -? ?pg_cron|SCHEMA cron|(?:TABLE DATA|SEQUENCE SET|DEFAULT ACL|ACL|FUNCTION|TABLE|SEQUENCE|COMMENT) cron)\b/
  const excluded = inventory.filter(line => !line.startsWith(';') && cronEntry.test(line))
  const listFile = join(checkpointDir, 'scratch-restore.list')
  await writeFile(listFile, inventory.filter(line => !cronEntry.test(line)).join('\n') + '\n', { mode: 0o600 })
  docker(['cp', listFile, `oscarapp-db:/tmp/${scratch}.list`])
  queryDatabase('postgres', `create database ${scratch} template template0;`)
  docker(['exec', 'oscarapp-db', 'pg_restore', '-U', 'supabase_admin',
    '--dbname', scratch, '--exit-on-error', '--use-list', `/tmp/${scratch}.list`, containerPath])
  const restored = JSON.parse(queryDatabase(scratch, fingerprintQuery))
  assert.deepEqual(restored, fingerprint, 'Restored checkpoint does not match the source local DB')

  const digest = createHash('sha256').update(await readFile(file)).digest('hex')
  await writeFile(join(checkpointDir, 'verification.json'), `${JSON.stringify({
    createdAt: new Date().toISOString(), sha256: digest, fingerprint,
    restoreVerified: true,
    restoreScope: 'New empty database in the same local PostgreSQL 17 cluster, with existing Supabase roles/extensions',
    scratchRestoreExcludes: excluded,
    schedulerIncludedInRecoveryDump: true,
    storageFileBytesIncluded: false,
  }, null, 2)}\n`, { mode: 0o600 })

  // Only this freshly created disposable database is removed, after verification.
  queryDatabase('postgres', `drop database ${scratch};`)
  console.log(`Local checkpoint saved and restore-tested: ${checkpointDir}`)
  console.log(`${fingerprint.sales} sales and full commission-line digest matched; working database unchanged.`)
} catch (error) {
  console.error(error.message)
  console.error(`Checkpoint did not finish. Inspect ${checkpointDir}; any scratch DB is named ${scratch}.`)
  process.exitCode = 1
}
