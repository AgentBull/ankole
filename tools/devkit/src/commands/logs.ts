import { Crust } from '@crustjs/core'
import { isRecord, type JsonObject } from '@pleisto/active-support'
import build from 'pino-pretty'

type PrettyLog = JsonObject
type PrettyOptions = NonNullable<Parameters<typeof build>[0]>

export function ankolePrettyLogOptions(): PrettyOptions {
  return {
    colorize: true,
    translateTime: 'SYS:HH:MM:ss.l',
    messageKey: 'message',
    levelKey: 'severity',
    errorLikeObjectKeys: ['error'],
    errorProps: '*',
    ignore: 'pid,hostname,event,duration_ms,labels',
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
  const activationCode = typeof log.activation_code === 'string' ? log.activation_code : undefined
  const duration = typeof log.duration_ms === 'number' ? ` ${log.duration_ms}ms` : ''
  const context = [component, event].filter(Boolean).join(' ')
  const message = typeof log[messageKey] === 'string' ? log[messageKey] : ''
  if (event?.startsWith('setup.bootstrap.activation_code_') && activationCode) {
    return [
      '    ------------------------------------------------------------',
      context ? `${context}: SETUP ACTIVATION CODE: ${activationCode}` : `SETUP ACTIVATION CODE: ${activationCode}`,
      '    ------------------------------------------------------------',
      '    Open /setup and enter this code.'
    ].join('\n')
  }

  return context ? `${context}${duration}: ${message}` : message
}

export async function runPrettyLogs(): Promise<void> {
  const transport = build(ankolePrettyLogOptions())
  process.stdin.pipe(transport)

  await new Promise<void>((resolve, reject) => {
    transport.once('close', resolve)
    transport.once('error', reject)
    process.stdin.once('error', reject)
  })
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
