import pino, { type DestinationStream, type Logger, type LoggerOptions } from 'pino'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { toError } from '../common/errors'

export type LogSeverity = 'DEBUG' | 'INFO' | 'NOTICE' | 'WARNING' | 'ERROR' | 'CRITICAL' | 'ALERT' | 'EMERGENCY'

export type WorkerLogFields = JSONObject

export type WorkerLoggerChildOptions = {
  component?: string
  labels?: Record<string, string | number | boolean | undefined>
  fields?: WorkerLogFields
}

export type WorkerLoggerOptions = {
  env?: Record<string, string | undefined>
  destination?: DestinationStream
}

export type WorkerLogger = {
  debug(event: string, message: string, fields?: WorkerLogFields): void
  info(event: string, message: string, fields?: WorkerLogFields): void
  notice(event: string, message: string, fields?: WorkerLogFields): void
  warning(event: string, message: string, fields?: WorkerLogFields): void
  error(event: string, message: string, fields?: WorkerLogFields): void
  critical(event: string, message: string, fields?: WorkerLogFields): void
  alert(event: string, message: string, fields?: WorkerLogFields): void
  emergency(event: string, message: string, fields?: WorkerLogFields): void
  child(options: WorkerLoggerChildOptions): WorkerLogger
}

type WorkerLoggerContext = {
  labels: Record<string, string>
}

/** Maps Pino labels and aliases to canonical Worker severities. */
const pinoLevelToSeverity: Record<string, LogSeverity> = {
  trace: 'DEBUG',
  debug: 'DEBUG',
  info: 'INFO',
  notice: 'NOTICE',
  warn: 'WARNING',
  warning: 'WARNING',
  error: 'ERROR',
  fatal: 'CRITICAL',
  critical: 'CRITICAL',
  alert: 'ALERT',
  emergency: 'EMERGENCY'
}

/** Selects the Pino method for each canonical Worker severity. */
const severityToPinoLevel: Record<LogSeverity, WorkerPinoLevel> = {
  DEBUG: 'debug',
  INFO: 'info',
  NOTICE: 'notice',
  WARNING: 'warn',
  ERROR: 'error',
  CRITICAL: 'critical',
  ALERT: 'alert',
  EMERGENCY: 'emergency'
}

/** Accepted ANKOLE_LOG_LEVEL spellings; unknown values use the fallback. */
const severityAliases: Record<string, LogSeverity> = {
  trace: 'DEBUG',
  debug: 'DEBUG',
  info: 'INFO',
  notice: 'NOTICE',
  warn: 'WARNING',
  warning: 'WARNING',
  error: 'ERROR',
  fatal: 'CRITICAL',
  critical: 'CRITICAL',
  alert: 'ALERT',
  emergency: 'EMERGENCY'
}

/** Adds syslog severities that Pino does not supply as built-in methods. */
const customLevels = {
  notice: 35,
  critical: 60,
  alert: 70,
  emergency: 80
}

/**
 * Worker severities map onto pino's built-in levels and `customLevels`. The
 * declared level type lets `writeWorkerLog` select the log method by index,
 * because pino's own type knows the custom levels.
 */
type WorkerCustomLevel = keyof typeof customLevels
type WorkerPinoLevel = WorkerCustomLevel | 'debug' | 'info' | 'warn' | 'error'
type PinoLogger = Logger<WorkerCustomLevel>
type WorkerPinoOptions = LoggerOptions<WorkerCustomLevel>

/** Log-envelope fields that caller payloads cannot replace. */
const reservedPayloadKeys = new Set(['severity', 'level', 'severity_text', 'severity_number', 'message', 'time'])

/** Process root logger; child loggers add component or execution context. */
export const workerLogger = createWorkerLogger()

/**
 * Keeps the public provider message in the durable Turn error but removes it
 * from Worker logs. The structured log fields retain the failure class,
 * status, and error code needed for operations.
 */
export function turnFailureLogError(error: unknown): Error {
  const normalized = toError(error)
  if (normalized.name !== 'LLMProviderTerminalError') return normalized

  const safe = new Error('LLM provider returned an error')
  safe.name = normalized.name
  safe.stack = undefined
  return safe
}

export function createWorkerLogger(bindings: WorkerLogFields = {}, options: WorkerLoggerOptions = {}): WorkerLogger {
  const env = options.env ?? Bun.env
  const pinoLogger = createPinoLogger(env, options.destination).child(normalizeFields(bindings))
  return wrapPinoLogger(pinoLogger, { labels: defaultLabels(env) })
}

export function createWorkerPinoOptions(env: Record<string, string | undefined> = Bun.env): WorkerPinoOptions {
  const options: WorkerPinoOptions = {
    level: pinoLevelForSeverity(resolveLogSeverity(env.ANKOLE_LOG_LEVEL, 'INFO')),
    customLevels,
    useOnlyCustomLevels: false,
    messageKey: 'message',
    errorKey: 'error',
    serializers: {
      error(value) {
        return value instanceof Error ? serializeError(value) : value
      }
    },
    timestamp: pino.stdTimeFunctions.isoTime,
    base: null,
    formatters: {
      level(label) {
        return { severity: severityForPinoLevel(label) }
      }
    }
  }

  return options
}

export function resolveLogSeverity(value: string | undefined, fallback: LogSeverity): LogSeverity {
  if (!value) return fallback
  return severityAliases[value.trim().toLowerCase()] ?? fallback
}

export function pinoLevelForSeverity(severity: LogSeverity): WorkerPinoLevel {
  return severityToPinoLevel[severity]
}

export function severityForPinoLevel(label: string): LogSeverity {
  return pinoLevelToSeverity[label] ?? 'INFO'
}

function createPinoLogger(env: Record<string, string | undefined>, destination?: DestinationStream): PinoLogger {
  const options = createWorkerPinoOptions(env)
  return destination ? pino(options, destination) : pino(options)
}

function wrapPinoLogger(logger: PinoLogger, context: WorkerLoggerContext): WorkerLogger {
  return {
    debug: (event, message, fields) => writeWorkerLog(logger, context, 'DEBUG', event, message, fields),
    info: (event, message, fields) => writeWorkerLog(logger, context, 'INFO', event, message, fields),
    notice: (event, message, fields) => writeWorkerLog(logger, context, 'NOTICE', event, message, fields),
    warning: (event, message, fields) => writeWorkerLog(logger, context, 'WARNING', event, message, fields),
    error: (event, message, fields) => writeWorkerLog(logger, context, 'ERROR', event, message, fields),
    critical: (event, message, fields) => writeWorkerLog(logger, context, 'CRITICAL', event, message, fields),
    alert: (event, message, fields) => writeWorkerLog(logger, context, 'ALERT', event, message, fields),
    emergency: (event, message, fields) => writeWorkerLog(logger, context, 'EMERGENCY', event, message, fields),
    child(options) {
      const childLabels = compactLabels({
        ...context.labels,
        component: options.component ?? context.labels.component,
        ...options.labels
      })
      return wrapPinoLogger(logger.child(normalizeFields(options.fields ?? {})), { labels: childLabels })
    }
  }
}

function writeWorkerLog(
  logger: PinoLogger,
  context: WorkerLoggerContext,
  severity: LogSeverity,
  event: string,
  message: string,
  fields: WorkerLogFields = {}
): void {
  const payload = normalizeFields({ ...fields, event })
  const existingLabels = labelField(payload.labels)
  payload.labels = compactLabels({
    ...context.labels,
    ...existingLabels
  })

  logger[pinoLevelForSeverity(severity)](payload, message)
}

function defaultLabels(env: Record<string, string | undefined>): Record<string, string> {
  return compactLabels({
    service: 'ankole-worker',
    component: 'agent-computer',
    runtime: 'bun',
    environment: env.ANKOLE_ENV || env.NODE_ENV,
    version: env.ANKOLE_VERSION
  })
}

function labelField(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  return compactLabels(value as Record<string, string | number | boolean | undefined>)
}

/** Removes reserved fields so call sites cannot replace log envelope metadata. */
function normalizeFields(fields: WorkerLogFields): WorkerLogFields {
  const normalized: WorkerLogFields = {}
  for (const [key, value] of Object.entries(fields)) {
    if (reservedPayloadKey(key)) continue
    if (value === undefined) continue
    normalized[key] = value instanceof Error ? serializeError(value) : value
  }
  return normalized
}

function reservedPayloadKey(key: string): boolean {
  return reservedPayloadKeys.has(key) || key.startsWith('logging.googleapis.com/')
}

function serializeError(error: Error): WorkerLogFields {
  const serialized: WorkerLogFields = {
    type: error.name,
    message: error.message,
    stack: error.stack
  }
  const record = error as Error & { code?: unknown; status?: unknown; details?: unknown }

  if (typeof record.code === 'string') serialized.code = record.code
  if (typeof record.status === 'number') serialized.status = record.status
  if (jsonObjectValue(record.details)) serialized.details = record.details

  return serialized
}

function jsonObjectValue(value: unknown): value is JSONObject {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}

function compactLabels(labels: Record<string, string | number | boolean | undefined>): Record<string, string> {
  const compacted: Record<string, string> = {}
  for (const [key, value] of Object.entries(labels)) {
    if (value === undefined || value === '') continue
    compacted[key] = String(value)
  }
  return compacted
}
