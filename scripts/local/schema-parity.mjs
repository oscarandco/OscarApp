import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, docker, localDir, root } from './runtime.mjs'

// Parse statement boundaries without splitting PL/pgSQL bodies or quoted strings.
export function statements(source) {
  const result = []
  let start = 0
  let mode = null
  let dollar = ''
  let commentDepth = 0
  for (let i = 0; i < source.length; i++) {
    const c = source[i]
    const next = source[i + 1]
    if (mode === 'line') { if (c === '\n') mode = null; continue }
    if (mode === 'block') {
      if (c === '/' && next === '*') { commentDepth++; i++ }
      else if (c === '*' && next === '/') { if (--commentDepth === 0) mode = null; i++ }
      continue
    }
    if (mode === 'single' || mode === 'double') {
      const quote = mode === 'single' ? "'" : '"'
      if (c === quote) { if (next === quote) i++; else mode = null }
      else if (c === '\\' && mode === 'single') i++
      continue
    }
    if (mode === 'dollar') {
      if (source.startsWith(dollar, i)) { i += dollar.length - 1; mode = null }
      continue
    }
    if (c === '-' && next === '-') { mode = 'line'; i++; continue }
    if (c === '/' && next === '*') { mode = 'block'; commentDepth = 1; i++; continue }
    if (c === "'") { mode = 'single'; continue }
    if (c === '"') { mode = 'double'; continue }
    if (c === '$') {
      const match = source.slice(i).match(/^\$[a-z_0-9]*\$/i)
      if (match) { dollar = match[0]; mode = 'dollar'; i += dollar.length - 1; continue }
    }
    if (c === ';') { result.push(source.slice(start, i + 1)); start = i + 1 }
  }
  if (source.slice(start).trim()) result.push(source.slice(start))
  return result
}

const views = new Set([
  'v_sales_transactions_powerbi_parity', 'v_sales_transactions_enriched',
  'v_commission_calculations_core', 'v_commission_calculations_qa',
  'v_admin_payroll_lines', 'v_admin_payroll_lines_weekly', 'v_admin_payroll_summary_weekly',
])
const functions = new Set([
  'staff_profile_at', 'apply_staff_role_assignment', 'list_staff_role_assignments',
  'get_admin_payroll_lines_weekly', 'get_admin_payroll_summary_weekly',
  'get_my_sales_trend_weekly', 'preview_contractor_invoice', 'create_contractor_invoice',
])
const scratch = `oscarapp_schema_parity_${randomBytes(6).toString('hex')}`
const baselineCommit = 'c6748c7'
function baselineGit(args) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024 })
  if (result.error || result.status !== 0) throw new Error(result.error?.message ?? result.stderr)
  return result.stdout
}
const query = (database, source) => docker(['exec', '-i', 'oscarapp-db', 'psql',
  '-U', 'supabase_admin', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: source })

function objectQuery(kind, name) {
  return kind === 'VIEW'
    ? `select to_jsonb(pg_get_viewdef('public.${name}'::regclass, true))`
    : `select to_jsonb(string_agg(pg_get_functiondef(p.oid), E'\\n' order by pg_get_function_identity_arguments(p.oid)))
       from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='${name}'`
}

// pg_get_viewdef canonicalises equivalent view syntax. Function bodies keep source
// formatting, so their comparisons ignore whitespace/comments but preserve text values.
function normalise(source) {
  return source.replace(/--[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\s+/g, ' ').trim()
}

try {
  assertLocalDocker()
  const checkpoint = join(localDir, 'checkpoints/2026-11-09T08-36-47-986Z/database.dump')
  await readFile(checkpoint) // Fail before creating a database if the baseline checkpoint is unavailable.
  const latest = new Map()
  const migrationFiles = baselineGit(['ls-tree', '-r', '--name-only', baselineCommit, '--', 'supabase/migrations'])
    .trim().split(/\r?\n/).filter((name) => name.endsWith('.sql')).sort()
  for (const path of migrationFiles) {
    const file = path.split('/').at(-1)
    for (const statement of statements(baselineGit(['show', `${baselineCommit}:${path}`]))) {
      const ddl = statement.replace(/^(?:\s|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*/, '').trim()
      const match = ddl.match(/^CREATE\s+(?:OR\s+REPLACE\s+)?(VIEW|FUNCTION)\s+"?public"?\."?([a-z_0-9]+)"?/i)
      if (!match) continue
      const kind = match[1].toUpperCase(), name = match[2]
      if ((kind === 'VIEW' ? views : functions).has(name)) latest.set(`${kind}:${name}`, { kind, name, ddl, file })
    }
  }
  const containerDump = `/tmp/${scratch}.dump`
  docker(['cp', checkpoint, `oscarapp-db:${containerDump}`])
  query('postgres', `create database ${scratch} template template0;`)
  docker(['exec', 'oscarapp-db', 'pg_restore', '-U', 'supabase_admin', '-d', scratch,
    '--exit-on-error', containerDump])
  const findings = []
  for (const candidate of latest.values()) {
    const before = JSON.parse(query(scratch, objectQuery(candidate.kind, candidate.name)))
    try {
      const ddl = candidate.ddl.replace(/^CREATE\s+(?:OR\s+REPLACE\s+)?/i, 'CREATE OR REPLACE ')
      const after = JSON.parse(query(scratch, `begin; ${ddl}\n${objectQuery(candidate.kind, candidate.name)}; rollback;`)
        .split('\n').filter((line) => !['BEGIN', 'CREATE VIEW', 'CREATE FUNCTION', 'ROLLBACK'].includes(line)).join('\n'))
      const left = normalise(before), right = normalise(after)
      const firstDifference = [...left].findIndex((value, index) => value !== right[index])
      findings.push({ kind: candidate.kind, name: candidate.name, file: candidate.file,
        matches: left === right,
        ...(left !== right ? { firstDifference, sourceFragment: left.slice(Math.max(0,firstDifference-70),firstDifference+170),
          repositoryFragment: right.slice(Math.max(0,firstDifference-70),firstDifference+170) } : {}) })
    } catch (error) {
      findings.push({ kind: candidate.kind, name: candidate.name, file: candidate.file,
        matches: false, error: error.message.slice(0, 1000) })
    }
  }
  const report = { checkedAt: new Date().toISOString(),
    repositoryBaselineCommit: baselineCommit,
    source: 'Complete local pre-feature checkpoint 2026-11-09T08-36-47-986Z',
    scope: 'Final repository definitions at the pre-feature baseline commit for commission/reporting, staff profile/history and contractor invoice entry points, canonicalised by PostgreSQL in an isolated restored scratch database.',
    note: 'Not proof that every one of the repository migration files was applied. Do not fabricate migration history.', findings }
  await writeFile(join(localDir, 'schema-parity.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
  query('postgres', `drop database ${scratch};`)
  console.log(JSON.stringify({ matched: findings.filter((f) => f.matches).length,
    checked: findings.length, differences: findings.filter((f) => !f.matches),
    report: 'local-db.local/schema-parity.json' }, null, 2))
  assert.ok(findings.length >= 12, 'Expected critical source definitions were not found')
  if (findings.some((finding) => !finding.matches)) process.exitCode = 1
} catch (error) {
  console.error(error.message)
  console.error(`Inspect any scratch database named ${scratch}; the working database was not changed.`)
  process.exitCode = 1
}
