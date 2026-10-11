import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { dedupe: ['react', 'react-dom'] },
  // Concurrent e2e servers (E2E_PORT) keep separate dependency caches.
  cacheDir: process.env.E2E_PORT ? `node_modules/.vite-e2e-${process.env.E2E_PORT}` : undefined,
  optimizeDeps: { entries: ['index.html'] },
  server: { port: 3046, strictPort: true, watch: { ignored: ['**/output/**'] } },
  build: {
    rolldownOptions: { input: { playground: 'index.html', embedded: 'playground/embedded.html' } },
    target: ['chrome126', 'firefox153', 'safari17'],
    cssTarget: ['chrome126', 'firefox153', 'safari17'],
    chunkSizeWarningLimit: 1000
  }
})
