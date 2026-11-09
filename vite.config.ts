import { fileURLToPath, URL } from 'node:url'

import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv } from 'vite'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  if (mode === 'docker') {
    const env = { ...loadEnv(mode, process.cwd(), 'VITE_'), ...process.env }
    const url = env.VITE_SUPABASE_URL
    if (env.VITE_APP_ENV !== 'local' || url !== 'http://127.0.0.1:54321' || !env.VITE_SUPABASE_ANON_KEY) {
      throw new Error('Docker mode requires the local-only settings from npm run dev:local. Refusing to use a hosted database.')
    }
  }

  return {
    plugins: [react(), tailwindcss()],
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url)),
      },
    },
  }
})
