import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, localDir, root, sql } from './runtime.mjs'

try {
  assertLocalDocker()
  const source = await readFile(join(root, 'scripts/local/survey-tests.sql'), 'utf8')
  if (!/^--[^]*?BEGIN;/i.test(source) || !/ROLLBACK;\s*$/.test(source)) throw new Error('Survey fixtures must be rollback-only')
  const output = sql(source)
  await writeFile(join(localDir, 'survey-check.log'), `${output}\n`, { mode: 0o600 })
  console.log(output.split('\n').find(line => line.startsWith('PASS:')))
  console.log('All survey fixtures rolled back. Evidence: local-db.local/survey-check.log')
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}
