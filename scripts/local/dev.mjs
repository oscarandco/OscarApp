import { spawn } from 'node:child_process'
import { join } from 'node:path'
import { apiUrl, readRuntime, request, root } from './runtime.mjs'

try {
  const runtime = await readRuntime()
  await request(runtime, '/auth/v1/health')
  // Process environment takes precedence over Vite's .env loading. Both values are injected,
  // so neither URL nor key can fall back to the production .env when using dev:local.
  const server = spawn(process.execPath, [
    join(root, 'node_modules/vite/bin/vite.js'), '--mode', 'docker',
    '--host', '127.0.0.1', '--port', '5173', '--strictPort',
  ], {
    cwd: root,
    windowsHide: true,
    stdio: 'inherit',
    env: {
      ...process.env,
      VITE_SUPABASE_URL: apiUrl,
      VITE_SUPABASE_ANON_KEY: runtime.anonKey,
      VITE_APP_ENV: 'local',
    },
  })
  server.on('error', (error) => { console.error(error.message); process.exitCode = 1 })
  server.on('exit', (code) => { process.exitCode = code ?? 0 })
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.kill(signal))
} catch (error) {
  console.error(`Local frontend could not start: ${error.message}`)
  console.error('Start the local services with npm run local:up first.')
  process.exitCode = 1
}
