import pino from 'pino'
import { AppEnv } from '@/config/env'
import { redactLogArg } from '@/security/redact'

/**
 * The single shared pino logger.
 *
 * Defaults differ by environment: in Kubernetes it runs at `info` and reshapes
 * level into a GCP-style `severity` field for log ingestion; locally it runs at
 * `debug` with pino's default shape for readable dev output. An explicit
 * `BULLX_LOG_LEVEL` overrides either default.
 */
export const logger = pino({
  timestamp: pino.stdTimeFunctions.isoTime,
  level: AppEnv.BULLX_LOG_LEVEL ?? (AppEnv.IS_KUBERNETES ? 'info' : 'debug'),
  errorKey: 'error',
  messageKey: 'message',
  // Defense-in-depth against leaking credentials into logs. Paths cover the
  // common containers (top-level, one level deep via `*`, and nested request
  // `headers`) for auth/cookie material, token/key fields, and request params
  // that frequently carry secrets. Pair this with the `logMethod` hook below,
  // which runs structured redaction the static path list cannot express.
  redact: {
    paths: [
      'authorization',
      'Authorization',
      '*.authorization',
      '*.Authorization',
      '*.headers.authorization',
      '*.headers.Authorization',
      'cookie',
      'Cookie',
      '*.cookie',
      '*.Cookie',
      '*.headers.cookie',
      '*.headers.Cookie',
      '*.password',
      '*.secret',
      '*.token',
      '*.access_token',
      '*.refresh_token',
      '*.id_token',
      '*.api_key',
      '*.apiKey',
      '*.encrypted_api_key',
      '*.encryptedApiKey',
      '*.params',
      'params',
      'queryParams',
      '*.queryParams'
    ],
    censor: '[Redacted]'
  },
  // In Kubernetes, emit the level as a `severity` label so log collectors
  // (Stackdriver/GCP-style) classify entries correctly; locally, keep pino's
  // numeric level for its pretty-printer.
  formatters: AppEnv.IS_KUBERNETES
    ? {
        level(label) {
          return { severity: label }
        }
      }
    : undefined,
  // Runs on every log call before formatting. `redactLogArg` scrubs each argument
  // structurally — catching secrets nested in shapes (e.g. Error objects, deep
  // values) that the static `redact.paths` list above cannot match by key.
  hooks: {
    logMethod(inputArgs, method) {
      method.apply(this, inputArgs.map(redactLogArg) as Parameters<typeof method>)
    }
  }
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
