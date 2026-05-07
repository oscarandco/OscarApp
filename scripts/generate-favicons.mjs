/**
 * Generates favicon PNGs and favicon.ico from the best available square source in /public.
 * Run: npm run generate-favicons
 */
import { existsSync } from 'node:fs'
import { writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

import sharp from 'sharp'

const require = createRequire(import.meta.url)
const toIco = require('to-ico')

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const publicDir = path.join(__dirname, '..', 'public')

/** Prefer highest-resolution square assets first. */
const SOURCE_CANDIDATES = ['icon-512.png', 'apple-touch-icon.png', 'oscar-icon.png']

function resolveSourcePath() {
  for (const name of SOURCE_CANDIDATES) {
    const p = path.join(publicDir, name)
    if (existsSync(p)) return { path: p, name }
  }
  return null
}

/** Contain-fit on transparent canvas keeps proportions; centred by default. */
const resizeOpts = {
  fit: 'contain',
  position: 'centre',
  background: { r: 0, g: 0, b: 0, alpha: 0 },
}

async function main() {
  const resolved = resolveSourcePath()
  if (!resolved) {
    throw new Error(
      `No source icon found in public/. Tried: ${SOURCE_CANDIDATES.join(', ')}`,
    )
  }

  const { path: sourcePath, name: sourceName } = resolved
  console.info(`Using source: public/${sourceName}`)

  const base = sharp(sourcePath).ensureAlpha()

  const png32 = await base
    .clone()
    .resize(32, 32, resizeOpts)
    .png({ compressionLevel: 9 })
    .toBuffer()

  const png16 = await sharp(sourcePath)
    .ensureAlpha()
    .resize(16, 16, resizeOpts)
    .png({ compressionLevel: 9 })
    .toBuffer()

  await writeFile(path.join(publicDir, 'favicon-32x32.png'), png32)
  await writeFile(path.join(publicDir, 'favicon-16x16.png'), png16)
  console.info('Wrote favicon-32x32.png, favicon-16x16.png')

  const icoBuffer = await toIco([png16, png32])
  await writeFile(path.join(publicDir, 'favicon.ico'), icoBuffer)
  console.info('Wrote favicon.ico (16 + 32)')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
