import pino from 'pino'
import { AppEnv } from '@/config/env'

export const logger = pino({
  timestamp: pino.stdTimeFunctions.isoTime,
  level: AppEnv.IS_KUBERNETES ? 'info' : 'debug',
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
