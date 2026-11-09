import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { apiUrl, localDir, readRuntime, request, sql } from './runtime.mjs'

const baselinePath = join(localDir, 'payroll-baseline.json')
const backupDir = join(localDir, 'backups/20261109T075855Z')
const lineFields = [
  'id', 'sale_date', 'location_id', 'invoice', 'product_service_name', 'quantity',
  'price_ex_gst', 'price_incl_gst', 'commission_category_final',
  'product_type_actual_derived', 'product_type_short_derived',
  'commission_product_service_derived', 'staff_commission_id', 'staff_work_id',
  'derived_staff_paid_id', 'derived_staff_paid_plan_id', 'derived_staff_paid_plan_name',
  'is_internal_non_commission', 'is_named_non_commission_category',
  'actual_commission_rate', 'actual_commission_amt_ex_gst',
  'theoretical_commission_rate', 'theoretical_commission_amt_ex_gst',
  'assistant_commission_amt_ex_gst', 'theoretical_assistant_commission_amt_ex_gst',
  'calculation_alert',
]
const summaryFields = [
  'pay_week_start', 'location_id', 'derived_staff_paid_id', 'line_count',
  'total_sales_ex_gst', 'total_actual_commission_ex_gst',
  'total_theoretical_commission_ex_gst', 'total_assistant_commission_ex_gst',
]
const weeklyLineFields = [
  'id', 'pay_week_start', 'price_ex_gst', 'actual_commission_amt_ex_gst',
  'theoretical_commission_amt_ex_gst', 'derived_staff_paid_id',
]

function jsonSql(query) {
  return JSON.parse(sql(`begin read only; ${query}; commit;`)
    .split('\n').filter((line) => line !== 'BEGIN' && line !== 'COMMIT').join('\n'))
}

function rowsFromView(view, fields, order, where = '') {
  return jsonSql(`select coalesce(jsonb_agg(to_jsonb(r) order by ${order}), '[]'::jsonb)
    from (select ${fields.join(', ')} from public.${view} ${where}) r`)
}

function project(rows, fields) {
  return rows.map((row) => Object.fromEntries(fields.map((field) => [field, row[field]])))
}

function canonical(rows) {
  return rows.map((row) => JSON.stringify(Object.fromEntries(Object.entries(row).sort())))
    .sort().join('\n')
}

function sameRows(actual, expected, description) {
  assert.equal(actual.length, expected.length, `${description}: row count changed`)
  // Report a compact failure without printing sensitive payroll/customer records.
  assert.ok(canonical(actual) === canonical(expected), `${description}: row values changed`)
}

async function rpcRows(runtime, token, name, body, order) {
  const result = []
  for (let offset = 0; ; offset += 500) {
    const rows = await request(runtime,
      `/rest/v1/rpc/${name}?order=${order}&offset=${offset}&limit=500`,
      { token, method: 'POST', body: JSON.stringify(body) })
    assert.ok(Array.isArray(rows), `${name} did not return rows`)
    result.push(...rows)
    if (rows.length < 500) return result
  }
}

try {
  assert.ok(process.argv.slice(2).every((arg) => arg === '--capture-baseline'), 'Unknown check option')
  const runtime = await readRuntime()
  const hashes = JSON.parse(await readFile(join(backupDir, 'checksums.json'), 'utf8'))
  for (const file of hashes) {
    const path = join(backupDir, basename(file.Path.replaceAll('\\', '/')))
    const hash = createHash('sha256').update(await readFile(path)).digest('hex').toUpperCase()
    assert.equal(hash, file.Hash, `Source backup changed: ${basename(path)}`)
  }
  console.log('PASS: original backup checksums match.')

  const lines = rowsFromView('v_commission_calculations_core', lineFields, 'id')
  const weekly = rowsFromView('v_admin_payroll_summary_weekly', summaryFields,
    'pay_week_start, location_id, derived_staff_paid_id')
  assert.ok(lines.length > 0 && weekly.length > 0, 'Expected the restored OscarApp dataset')
  const week = weekly.map((row) => row.pay_week_start).sort().at(-1)
  assert.match(week, /^\d{4}-\d{2}-\d{2}$/)
  const weeklyLines = rowsFromView('v_admin_payroll_lines_weekly', weeklyLineFields,
    'id', `where pay_week_start='${week}'::date`)
  const snapshot = { version: 1, capturedAt: new Date().toISOString(), week, lines, weekly, weeklyLines }

  if (process.argv.includes('--capture-baseline')) {
    await writeFile(baselinePath, `${JSON.stringify(snapshot)}\n`, { flag: 'wx', mode: 0o600 })
    console.log('Captured the initial baseline; existing baselines are never overwritten.')
  }
  const baseline = JSON.parse(await readFile(baselinePath, 'utf8'))
  assert.equal(baseline.version, snapshot.version, 'Unsupported baseline version')
  assert.equal(week, baseline.week, 'Latest imported pay week changed')
  // Display labels may be intentionally renamed, but permanent plan identities,
  // money, rates, categories and attribution must still match the original file.
  const historicalFields = lineFields.filter((field) => field !== 'derived_staff_paid_plan_name')
  sameRows(project(lines, historicalFields), project(baseline.lines, historicalFields), 'Commission-core baseline')
  const currentPlanNames = jsonSql(`select coalesce(jsonb_object_agg(id::text, plan_name), '{}'::jsonb) from public.remuneration_plans`)
  for (const line of lines) {
    if (line.derived_staff_paid_plan_id == null) {
      assert.equal(line.derived_staff_paid_plan_name, null, 'A plan label exists without a permanent plan identity')
    } else {
      assert.ok(Object.hasOwn(currentPlanNames, line.derived_staff_paid_plan_id), 'Historical plan identity no longer exists')
      assert.equal(line.derived_staff_paid_plan_name, currentPlanNames[line.derived_staff_paid_plan_id],
        'Historical plan display label does not match its permanent identity')
    }
  }
  const originalLabels = new Map(baseline.lines.map((line) => [line.id, line.derived_staff_paid_plan_name]))
  const renamedLineCount = lines.filter((line) => line.derived_staff_paid_plan_name !== originalLabels.get(line.id)).length
  console.log(`PASS: ${renamedLineCount} label-only plan-name differences; every current label matches its unchanged permanent plan ID.`)
  sameRows(weekly, baseline.weekly, 'Weekly summary baseline')
  sameRows(weeklyLines, baseline.weeklyLines, 'Latest-week line baseline')
  console.log(`PASS: ${lines.length} commission lines and ${weekly.length} weekly summary rows match the saved baseline.`)

  const session = await request(runtime, '/auth/v1/token?grant_type=password', {
    method: 'POST', body: JSON.stringify({ email: runtime.adminEmail, password: runtime.adminPassword }),
  })
  const token = session.access_token
  assert.equal(session.user.email, runtime.adminEmail)
  const [profile] = await request(runtime, '/rest/v1/rpc/get_my_access_profile', {
    token, method: 'POST', body: '{}',
  })
  assert.equal(profile.access_role, 'admin')
  assert.equal(profile.is_active, true)
  console.log('PASS: local password sign-in and active admin access.')

  const summary = await rpcRows(runtime, token, 'get_admin_payroll_summary_weekly', {},
    'pay_week_start,location_id,derived_staff_paid_id')
  sameRows(project(summary, summaryFields), weekly, 'Authenticated weekly summary RPC')
  const detail = await rpcRows(runtime, token, 'get_admin_payroll_lines_weekly',
    { p_pay_week_start: week }, 'id')
  sameRows(project(detail, weeklyLineFields), weeklyLines, 'Authenticated weekly line RPC')
  console.log(`PASS: browser-facing payroll RPCs match the database (${week}: ${detail.length} lines).`)

  const denied = await fetch(`${apiUrl}/rest/v1/rpc/get_admin_payroll_summary_weekly`, {
    method: 'POST', headers: {
      apikey: runtime.anonKey, Authorization: `Bearer ${runtime.anonKey}`, 'Content-Type': 'application/json',
    }, body: '{}', signal: AbortSignal.timeout(10_000),
  })
  const denial = await denied.json()
  // The copied RPC raises P0001 "Access denied", which PostgREST maps to HTTP 400.
  assert.ok(!denied.ok && !Array.isArray(denial) && (
    [401, 403].includes(denied.status) ||
    (denied.status === 400 && denial.code === 'P0001' && denial.message === 'Access denied')
  ), 'Anonymous payroll request did not produce the expected access rejection')
  const disabled = await fetch(`${apiUrl}/functions/v1/sales-daily-sheets-import`, {
    headers: { apikey: runtime.anonKey }, signal: AbortSignal.timeout(10_000),
  })
  assert.equal(disabled.status, 501, 'Local Edge Functions must remain disabled')
  const importConfigCount = jsonSql('select count(*) from private.sales_daily_sheets_import_config')
  assert.equal(importConfigCount, 0, 'Production import configuration must be absent locally')
  console.log('PASS: anonymous payroll access denied; production import configuration absent; Edge Functions disabled.')

  await request(runtime, '/storage/v1/bucket', { service: true })
  console.log('PASS: local Storage API responds. Copied Storage objects still require their original file bytes.')
  await request(runtime, '/auth/v1/logout?scope=local', { token, method: 'POST', body: '{}' })
  console.log('Local checks passed. No production requests or payroll writes were made.')
} catch (error) {
  if (error.code === 'ENOENT' && error.path === baselinePath) {
    console.error('No baseline exists. Capture it once on the verified restore: npm run local:check -- --capture-baseline')
  } else {
    console.error(error.message)
  }
  process.exitCode = 1
}
