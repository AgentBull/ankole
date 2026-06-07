import { openapi } from '@elysiajs/openapi'
import { staticPlugin } from '@elysiajs/static'
import { Elysia } from 'elysia'
import path from 'node:path'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { consoleRoutes } from '@/console/routes'
import { externalGatewayRoutes } from '@/external-gateway'
import { sessionApiRoutes } from '@/principals/admin-auth/api-routes'
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

      const origin = request.headers.get('origin')
      if (origin && origin !== url.origin) {
        set.status = 403
        return { error: 'invalid origin' }
      }

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
    .use(externalGatewayRoutes())
    .use(
      webAppRoutes({
        devSpaHtmlRenderer:
          (options.serveStaticAssets ?? true) && AppEnv.IS_DEVELOPMENT ? renderDevSpaHtmlFromBunRoute : undefined
      })
    )
    .onError(({ code, error, set }) => {
      const status =
        typeof error === 'object' && error && 'status' in error && typeof error.status === 'number' ? error.status : 500
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

function requestHasBody(request: Request): boolean {
  const contentLength = request.headers.get('content-length')
  if (contentLength && contentLength !== '0') return true

  return request.headers.has('content-type')
}

export async function startWebServer() {
  const app = await createWebServer()
  app.listen({
    port: AppEnv.HTTP_PORT,
    idleTimeout: 0
  })
  logger.info({ port: AppEnv.HTTP_PORT }, 'BullX Web Server is listening')
}
