import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath, URL } from 'node:url'

// the console is served under a base the app chooses (NEXUS_DEBUG_PATH), so the build uses
// relative URLs and the server writes the base into index.html. `npm run dev` proxies the API to
// a running app: NEXUS_URL=http://127.0.0.1:8080 npm run dev
const app = process.env.NEXUS_URL ?? 'http://127.0.0.1:8080'

export default defineConfig(({ command }) => ({
  base: command === 'build' ? './' : '/__nexus/',
  plugins: [
    react(),
    tailwindcss(),
    {
      // in dev there is no server to write the base in
      name: 'nexus-base',
      apply: 'serve',
      transformIndexHtml: (html: string) => html.replaceAll('__NEXUS_BASE__', '/__nexus'),
    },
  ],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    chunkSizeWarningLimit: 700,
  },
  server: { proxy: { '/__nexus/api': { target: app, changeOrigin: false } } },
}))
