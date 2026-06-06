import pino from 'pino'
import { AppEnv } from '@/config/env'

export const logger = pino({
  timestamp: pino.stdTimeFunctions.isoTime,
  level: AppEnv.BULLX_LOG_LEVEL ?? (AppEnv.IS_KUBERNETES ? 'info' : 'debug'),
  errorKey: 'error',
  messageKey: 'message',
  formatters: AppEnv.IS_KUBERNETES
    ? {
        level(label) {
          return { severity: label }
        }
      }
    : undefined
})

/**
 * Minimal structured-logging seam consumed by the composition root. The pino
 * `logger` above satisfies it; tests inject a fake to capture startup output.
 */
export interface Logger {
  child?(bindings: Record<string, unknown>): Logger
  debug?(data: unknown, message: string): void
  error(data: unknown, message: string): void
  info(data: unknown, message: string): void
  warn?(data: unknown, message: string): void
}
