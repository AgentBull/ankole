import { openapi } from '@elysiajs/openapi'
import { staticPlugin } from '@elysiajs/static'
import { Elysia } from 'elysia'
import path from 'node:path'
import { statusFromError } from '@/common/errors'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { consoleRoutes } from '@/console/routes'
import { reasoningTraceRoutes } from '@/ai-agent/reasoning-trace-routes'
import { externalGatewayRoutes } from '@/external-gateway'
import { sessionApiRoutes } from '@/principals/admin-auth/api-routes'
import { computerRoutes } from '@/computer/routes'
import { schedulerRoutes } from '@/scheduler/routes'
import { setupRoutes } from '@/setup/routes'
import { webAppRoutes } from './web-routes'
import type { SpaName } from './spa-html'

const DEV_SPA_PREFIX = '/__bullx_spa'

export interface CreateWebServerOptions {
  serveStaticAssets?: boolean
}

/**
 * Builds the HTTP server with the same API and SPA controller routes.
 *
 * Tests can disable static asset serving because they exercise the API guard and
 * route wiring, not Bun/Elysia's file-server path. Normal process startup keeps
 * static assets enabled so the server owns both HTML and bundled SPA assets.
 */
export async function createWebServer(options: CreateWebServerOptions = {}) {
  const app = new Elysia({
    serve: AppEnv.IS_DEVELOPMENT
      ? {
          development: {
            console: true,
            hmr: true
          }
        }
      : undefined
  })

  if (options.serveStaticAssets ?? true) {
    if (AppEnv.IS_DEVELOPMENT) {
      app.use(
        await staticPlugin({
          assets: path.resolve(import.meta.dir, '../../webui/src/entries'),
          bunFullstack: true,
          prefix: DEV_SPA_PREFIX
        })
      )
    } else {
      app.use(
        await staticPlugin({
          assets: path.resolve(import.meta.dir, '../../public/assets'),
          // The production build can exceed @elysiajs/static's 1024-file always-static limit
          // once Shiki/UI chunks are emitted. Use the dynamic file route so /assets/* never vanishes.
          alwaysStatic: false,
          prefix: '/assets'
        })
      )
    }
  }

  return app
    .use(
      openapi({
        provider: 'scalar'
      })
    )
    .onBeforeHandle(({ request, set }) => {
      const url = new URL(request.url)
      if (!url.pathname.startsWith('/api/')) return
      if (!unsafeMethod(request.method)) return

      if (requestHasBody(request)) {
        const contentType = request.headers.get('content-type') ?? ''
        if (!contentType.toLowerCase().startsWith('application/json')) {
          set.status = 415
          return { error: 'expected application/json' }
        }
      }
    })
    .use(setupRoutes())
    .use(sessionApiRoutes())
    .use(consoleRoutes())
    .use(computerRoutes())
    .use(externalGatewayRoutes())
    .use(
      reasoningTraceRoutes({
        devSpaHtmlRenderer:
          (options.serveStaticAssets ?? true) && AppEnv.IS_DEVELOPMENT ? renderDevSpaHtmlFromBunRoute : undefined
      })
    )
    .use(schedulerRoutes())
    .use(
      webAppRoutes({
        devSpaHtmlRenderer:
          (options.serveStaticAssets ?? true) && AppEnv.IS_DEVELOPMENT ? renderDevSpaHtmlFromBunRoute : undefined
      })
    )
    .onError(({ code, error, set }) => {
      const status = statusFromError(error)
      const isInternalServerError = status >= 500
      isInternalServerError
        ? logger.error({ error, code }, 'Internal Server Error')
        : logger.warn({ error, code }, 'Client Error')
      set.status = status
      return {
        error: {
          code: status,
          status: code,
          message:
            AppEnv.IS_PRODUCTION && isInternalServerError
              ? 'Internal Server Error'
              : error instanceof Error
                ? error.message
                : String(error)
        }
      }
    })
}

async function renderDevSpaHtmlFromBunRoute(app: SpaName, request: Request): Promise<Response> {
  const url = new URL(`${DEV_SPA_PREFIX}/${app}.html`, request.url)
  return fetch(url)
}

export type WebServer = Awaited<ReturnType<typeof createWebServer>>

/**
 * Minimal ingress contract the composition root listens on. The real value is
 * the Elysia app from createWebServer(); tests inject a fake so startup wiring
 * can be asserted without binding a port.
 */
export interface WebServerHandle {
  listen(options: { idleTimeout: number; port: number }): unknown
}

function unsafeMethod(method: string): boolean {
  return !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase())
}

/**
 * Detects whether a request is trying to send a body to the JSON-only API guard.
 *
 * Some clients omit `content-length` for streaming bodies, so `content-type` is
 * also treated as evidence of a body. That gives bad form posts a clear 415
 * instead of letting them fall into route-specific parser errors.
 */
function requestHasBody(request: Request): boolean {
  const contentLength = request.headers.get('content-length')
  if (contentLength && contentLength !== '0') return true

  return request.headers.has('content-type')
}

/**
 * Starts the production/development HTTP server on the configured port.
 */
export async function startWebServer() {
  const app = await createWebServer()
  app.listen({
    port: AppEnv.HTTP_PORT,
    idleTimeout: 0
  })
  logger.info({ port: AppEnv.HTTP_PORT }, 'BullX Web Server is listening')
}
