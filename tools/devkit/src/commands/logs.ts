import { Crust } from '@crustjs/core'
import { isRecord, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Transform } from 'node:stream'
import build from 'pino-pretty'

type PrettyLog = JSONObject
type PrettyOptions = NonNullable<Parameters<typeof build>[0]>

export function ankolePrettyLogOptions(): PrettyOptions {
  return {
    colorize: true,
    translateTime: 'SYS:HH:MM:ss.l',
    messageKey: 'message',
    levelKey: 'severity',
    errorLikeObjectKeys: ['error'],
    errorProps: '*',
    ignore: 'pid,hostname,event,duration_ms,labels,error_logger',
    singleLine: false,
    customPrettifiers: {
      level: value => String(value),
      duration_ms: value => `${value}ms`
    },
    messageFormat: formatPrettyLogMessage
  }
}

export function formatPrettyLogMessage(log: PrettyLog, messageKey: string): string {
  const component = label(log, 'labels', 'component')
  const event = typeof log.event === 'string' ? log.event : undefined
  const duration = typeof log.duration_ms === 'number' ? ` ${log.duration_ms}ms` : ''
  const context = [component, event].filter(Boolean).join(' ')
  const message = typeof log[messageKey] === 'string' ? log[messageKey] : ''
  if (event?.startsWith('setup.bootstrap.activation_code_')) {
    return [
      '    ------------------------------------------------------------',
      context ? `${context}: ${message}` : message,
      '    ------------------------------------------------------------',
      '    Open /setup and enter this code.'
    ].join('\n')
  }

  return context ? `${context}${duration}: ${message}` : message
}

export async function runPrettyLogs(): Promise<void> {
  const transport = build(ankolePrettyLogOptions())
  const inputFilter = createPrettyLogInputFilter()
  process.stdin.pipe(inputFilter).pipe(transport)

  await new Promise<void>((resolve, reject) => {
    transport.once('close', resolve)
    transport.once('error', reject)
    process.stdin.once('error', reject)
    inputFilter.once('error', reject)
  })
}

export function isRoutineOTPApplicationStop(log: PrettyLog): boolean {
  const errorLogger = log.error_logger
  const message = log.message

  return (
    log.severity === 'NOTICE' &&
    log.event === 'logger.message' &&
    typeof message === 'string' &&
    /^Application \S+ exited: :?stopped$/.test(message) &&
    isRecord(errorLogger) &&
    errorLogger.report_cb === '&:application_controller.format_log/1'
  )
}

export function logsCommand(): Crust {
  return new Crust('logs')
    .meta({
      aliases: ['log'],
      description: 'Format Ankole structured logs for local development.'
    })
    .command('pretty', cmd =>
      cmd.meta({ description: 'Pretty-print Ankole JSON log lines from stdin.' }).run(() => runPrettyLogs())
    )
}

function label(log: PrettyLog, key: string, labelKey: string): string | undefined {
  const labels = log[key]
  if (!isRecord(labels)) return undefined
  const value = labels[labelKey]
  return typeof value === 'string' ? value : undefined
}

function createPrettyLogInputFilter(): Transform {
  let pending = ''

  return new Transform({
    transform(chunk, _encoding, callback) {
      pending += chunk.toString()
      const lines = pending.split('\n')
      pending = lines.pop() ?? ''

      for (const line of lines) {
        if (shouldDisplayPrettyLogLine(line)) this.push(`${line}\n`)
      }

      callback()
    },
    flush(callback) {
      if (pending && shouldDisplayPrettyLogLine(pending)) this.push(pending)
      callback()
    }
  })
}

function shouldDisplayPrettyLogLine(line: string): boolean {
  try {
    const log: unknown = JSON.parse(line)
    return !isRecord(log) || !isRoutineOTPApplicationStop(log)
  } catch {
    return true
  }
}
