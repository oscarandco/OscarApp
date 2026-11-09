import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import {
  adminEmail, appUrl, assertLocalDocker, compose, localDir, mailUrl,
  prepareRuntime, request, sql, waitForAuth,
} from './runtime.mjs'

try {
  const action = process.argv[2] ?? 'up'
  if (action === 'credentials') {
    console.log(await readFile(join(localDir, 'login.json'), 'utf8'))
  } else if (action === 'up') {
    assertLocalDocker()
    const runtime = await prepareRuntime()
    // This adopts the existing restored volume; it never resets, reseeds or pulls a hosted DB.
    compose(['up', '--detach', '--wait'])
    const count = Number(sql('select count(*) from public.sales_transactions;'))
    if (!count) throw new Error('Expected the restored OscarApp database. No test account was created.')
    if (Number(sql('select count(*) from private.sales_daily_sheets_import_config;')) !== 0) {
      throw new Error('Local import configuration still contains a source endpoint. Clear it locally before proceeding.')
    }
    await waitForAuth(runtime)
    const { users } = await request(runtime, '/auth/v1/admin/users?page=1&per_page=1000', { service: true })
    let admin = users.find((user) => user.email === adminEmail)
    if (!admin) {
      admin = await request(runtime, '/auth/v1/admin/users', {
        service: true, method: 'POST',
        body: JSON.stringify({ email: adminEmail, password: runtime.adminPassword, email_confirm: true }),
      })
    }
    if (!/^[0-9a-f-]{36}$/i.test(admin.id)) throw new Error('Auth returned an invalid local test-user ID.')
    sql(`
      insert into public.staff_member_user_access (user_id, staff_member_id, access_role, is_active)
      select '${admin.id}'::uuid, null, 'admin', true
      where not exists (select 1 from public.staff_member_user_access where user_id='${admin.id}'::uuid);
    `)
    console.log(`Local stack ready. App: ${appUrl}; email capture: ${mailUrl}`)
    console.log(`Test admin: ${adminEmail}; credentials: local-db.local/login.json`)
    console.log('Start the frontend with npm run dev:local. Production .env was not changed.')
  } else if (action === 'down') {
    // External database and named storage volumes are retained. No --volumes flag.
    compose(['down'])
  } else if (action === 'status') {
    compose(['ps'])
  } else {
    throw new Error('Use up, down, status or credentials.')
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}
