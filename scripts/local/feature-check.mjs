import { spawnSync } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, localDir, readRuntime, root, sql } from './runtime.mjs'

const logDir = join(localDir, 'feature-checks')
const log = []
const stamp = new Date().toISOString().replaceAll(/[:.]/g, '-')
let failure

function runScript(file, label) {
  const result = spawnSync(process.execPath, [join(root, 'scripts/local', file)], {
    cwd: root, encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024,
  })
  log.push(`\n${label}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
  if (result.error || result.status !== 0) throw new Error(`${label} failed: ${result.error?.message ?? result.stderr ?? 'see log'}`)
  console.log(`PASS: ${label}`)
}

const baseline = (label) => runScript('check.mjs', label)

try {
  assertLocalDocker()
  await readRuntime() // Validates fixed loopback URLs before any checks.
  await mkdir(logDir, { recursive: true })
  baseline('Original line/week baseline, local Auth and reporting APIs before fixtures')
  const configuredCutover = Number(sql(`select ((select count(*) from public.theoretical_commission_benchmarks)>1
    or exists(select 1 from public.remuneration_plans where lower(btrim(plan_name))='commission'
      and deduct_service_product_costs))::integer;`)) === 1
  if (configuredCutover) {
    console.log('Configured plan/benchmark transition detected; original-state acceptance fixtures run in an isolated pre-configuration restore.')
    log.push('\nConfigured cutover detected; working configuration is preserved.\n')
    runScript('verify-feature-restore.mjs', 'Acceptance fixtures on an isolated pre-configuration restore')
  } else for (const [file, description] of [
    ['service-cost-plan-tests.sql', 'Stable plan IDs, dates, archive protections and undo'],
    ['service-cost-tests.sql', 'Service-cost calculation and reporting acceptance fixtures'],
    ['service-cost-permission-tests.sql', 'Authenticated view/none and anonymous permissions'],
    ['service-cost-archive-tests.sql', 'Archive dates, reactivation and legacy unknown dates'],
  ]) {
    const source = await readFile(join(root, 'scripts/local', file), 'utf8')
    // Every harness owns a transaction which ends in rollback. No fixture is seeded permanently.
    if (!/\bBEGIN\s*;/i.test(source) || !/ROLLBACK\s*;\s*$/.test(source)) {
      throw new Error(`${file} must contain a rollback-only fixture transaction`)
    }
    log.push(`\n${description}\n${sql(source)}\n`)
    console.log(`PASS: ${description}`)
  }
  baseline('Original line/week baseline, local Auth and reporting APIs after rollback')
  console.log('Feature checks passed. Fixture transactions rolled back; current local configuration preserved; no production requests or permanent payroll changes.')
} catch (error) {
  failure = error
  log.push(`\nFAIL: ${error.message}\n`)
  console.error(error.message)
  process.exitCode = 1
} finally {
  await mkdir(logDir, { recursive: true })
  const path = join(logDir, `${stamp}.log`)
  await writeFile(path, `${log.join('\n')}\n${failure ? 'FAILED' : 'PASSED'}\n`, { mode: 0o600 })
  console.log(`Local evidence: ${path}`)
}
