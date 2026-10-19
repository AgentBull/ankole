import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { defineConfig, type ViteDevServer } from 'vite'
import productionConfig from '../vite.config.ts'

export default defineConfig(async env => {
  const config = typeof productionConfig === 'function' ? await productionConfig(env) : productionConfig
  return {
    ...config,
    plugins: [
      ...(config.plugins ?? []).filter(
        plugin => plugin && !('name' in plugin && plugin.name === 'ankole-phoenix-shell')
      ),
      {
        name: 'browser-test-shell',
        configureServer(server: ViteDevServer) {
          server.middlewares.use(async (request, response, next) => {
            if (
              !request.headers.accept?.includes('text/html') ||
              (!/^\/(\?|$|pages\/|conversations\/|content\/)/.test(request.url ?? '') &&
                !request.url?.startsWith('/providers') &&
                !request.url?.startsWith('/brain') &&
                !/^\/(settings|tenants|webhooks|files|schedules|library|worker-env|worker-providers)(\/|\?|$)/.test(
                  request.url ?? ''
                ) &&
                !request.url?.startsWith('/console-home') &&
                !/^\/(setup-repair|login-repair)(\/|\?|$)/.test(request.url ?? ''))
            ) {
              return next()
            }
            const html = await readFile(path.join(import.meta.dirname, 'index.html'), 'utf8')
            response.setHeader('Content-Type', 'text/html')
            response.end(await server.transformIndexHtml(request.url ?? '/', html))
          })
        }
      }
    ],
    server: { host: '127.0.0.1', port: 3198, strictPort: true }
  }
})
