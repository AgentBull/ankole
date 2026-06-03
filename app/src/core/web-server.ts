import { openapi } from '@elysiajs/openapi'
import { Elysia } from 'elysia'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { chatGatewayRoutes } from '@/chat-gateway'

export const webServer = new Elysia()
  .use(
    openapi({
      provider: 'scalar'
    })
  )
  .use(chatGatewayRoutes())
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

export type WebServer = typeof webServer
