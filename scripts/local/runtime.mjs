import { createHmac, randomBytes } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
export const localDir = join(root, 'local-db.local')
export const apiUrl = 'http://127.0.0.1:54321'
export const appUrl = 'http://127.0.0.1:5173'
export const mailUrl = 'http://127.0.0.1:54324'
export const adminEmail = 'local-admin@oscarapp.test'

export function docker(args, { input, inherit = false } = {}) {
  const result = spawnSync('docker', args, {
    cwd: root,
    input,
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: 32 * 1024 * 1024,
    stdio: inherit ? 'inherit' : ['pipe', 'pipe', 'pipe'],
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error(`Docker command failed: ${result.stderr || 'see terminal output'}`)
  }
  return result.stdout?.trim() ?? ''
}

export function assertLocalDocker() {
  if (process.env.DOCKER_HOST && !/^(npipe:|unix:)/.test(process.env.DOCKER_HOST)) {
    throw new Error('Local setup cannot use a remote DOCKER_HOST.')
  }
  const host = JSON.parse(docker(['context', 'inspect', '--format', '{{json .Endpoints.docker.Host}}']))
  if (!host.startsWith('npipe:') && !host.startsWith('unix:')) {
    throw new Error('Local setup requires a local Docker socket, not a remote Docker context.')
  }
}

export function sql(query) {
  assertLocalDocker()
  return docker([
    'exec', '-i', 'oscarapp-db', 'psql', '-U', 'postgres', '-d', 'postgres',
    '-X', '-v', 'ON_ERROR_STOP=1', '-At',
  ], { input: query })
}

function jwt(secret, role) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const content = `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({
    iss: 'oscarapp-local', role, iat: now, exp: now + 365 * 24 * 60 * 60,
  })}`
  return `${content}.${createHmac('sha256', secret).update(content).digest('base64url')}`
}

export async function readRuntime() {
  try {
    const runtime = JSON.parse(await readFile(join(localDir, 'runtime.json'), 'utf8'))
    if (runtime.apiUrl !== apiUrl || runtime.appUrl !== appUrl || runtime.adminEmail !== adminEmail) {
      throw new Error('Local runtime configuration must use the fixed loopback endpoints and local test email.')
    }
    if (!runtime.jwtSecret || !runtime.anonKey || !runtime.serviceRoleKey || !runtime.adminPassword) {
      throw new Error('Local runtime credentials are incomplete.')
    }
    return runtime
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error('Run npm run local:up to initialise the local environment.')
    throw error
  }
}

export async function prepareRuntime() {
  await mkdir(localDir, { recursive: true })
  try {
    await readFile(join(localDir, 'runtime.json'))
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
    const secret = randomBytes(48).toString('base64url')
    await writeFile(join(localDir, 'runtime.json'), `${JSON.stringify({
      apiUrl, appUrl, adminEmail,
      jwtSecret: secret,
      anonKey: jwt(secret, 'anon'),
      serviceRoleKey: jwt(secret, 'service_role'),
      adminPassword: `${randomBytes(21).toString('base64url')}aA1!`,
    }, null, 2)}\n`, { flag: 'wx', mode: 0o600 })
  }
  const runtime = await readRuntime()
  await writeFile(join(localDir, 'stack.env'), [
    `LOCAL_JWT_SECRET=${runtime.jwtSecret}`,
    `LOCAL_ANON_KEY=${runtime.anonKey}`,
    `LOCAL_SERVICE_ROLE_KEY=${runtime.serviceRoleKey}`,
    '',
  ].join('\n'), { mode: 0o600 })
  const template = await readFile(join(root, 'dev/local/kong.template.yml'), 'utf8')
  await writeFile(join(localDir, 'kong.yml'), template
    .replaceAll('__LOCAL_ANON_KEY__', runtime.anonKey)
    .replaceAll('__LOCAL_SERVICE_ROLE_KEY__', runtime.serviceRoleKey), { mode: 0o600 })
  await writeFile(join(localDir, 'login.json'), `${JSON.stringify({
    url: appUrl, email: adminEmail, password: runtime.adminPassword,
  }, null, 2)}\n`, { mode: 0o600 })
  return runtime
}

export function compose(args, inherit = true) {
  assertLocalDocker()
  return docker([
    'compose', '--project-name', 'oscarapp-local-db',
    '--env-file', join(localDir, 'stack.env'),
    '--file', join(root, 'dev/local/compose.yaml'), ...args,
  ], { inherit })
}

export async function request(runtime, path, { token, service = false, ...options } = {}) {
  const response = await fetch(`${apiUrl}${path}`, {
    ...options,
    signal: AbortSignal.timeout(30_000),
    headers: {
      apikey: service ? runtime.serviceRoleKey : runtime.anonKey,
      Authorization: `Bearer ${token ?? (service ? runtime.serviceRoleKey : runtime.anonKey)}`,
      'Content-Type': 'application/json',
      ...options.headers,
    },
  })
  const text = await response.text()
  let body
  try { body = JSON.parse(text) } catch { body = text }
  if (!response.ok) {
    throw new Error(`Local API ${path.split('?')[0]} returned ${response.status}: ${JSON.stringify(body)}`)
  }
  return body
}

export async function waitForAuth(runtime) {
  for (let attempt = 0; attempt < 30; attempt++) {
    try { await request(runtime, '/auth/v1/health'); return } catch {
      await new Promise((resolve) => setTimeout(resolve, 1000))
    }
  }
  throw new Error('Local Auth did not become ready. Inspect npm run local:status and Docker logs.')
}
