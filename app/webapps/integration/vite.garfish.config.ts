import path from 'node:path'
import { defineConfig } from 'vite'
import productionConfig from '../vite.config.ts'

/** Reuse the host build plugins and serve the Bun output through Vite's static public directory. */
export default defineConfig(async env => {
  const config = typeof productionConfig === 'function' ? await productionConfig(env) : productionConfig
  return {
    ...config,
    publicDir: path.join(import.meta.dirname, 'garfish/public'),
    plugins: (config.plugins ?? []).filter(
      plugin => plugin && !('name' in plugin && plugin.name === 'ankole-phoenix-shell')
    ),
    server: { host: '127.0.0.1', port: 3199, strictPort: true }
  }
})
