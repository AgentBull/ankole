import build from 'pino-pretty'

type PrettyLog = Record<string, unknown>

export default function createPrettyTransport() {
  return build({
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
    messageFormat(log: PrettyLog, messageKey: string) {
      const component = label(log, 'labels', 'component')
      const event = typeof log.event === 'string' ? log.event : undefined
      const duration = typeof log.duration_ms === 'number' ? ` ${log.duration_ms}ms` : ''
      const context = [component, event].filter(Boolean).join(' ')
      const message = typeof log[messageKey] === 'string' ? log[messageKey] : ''
      return context ? `${context}${duration}: ${message}` : message
    }
  })
}

function label(log: PrettyLog, key: string, labelKey: string): string | undefined {
  const labels = log[key]
  if (!labels || typeof labels !== 'object' || Array.isArray(labels)) return undefined
  const value = (labels as Record<string, unknown>)[labelKey]
  return typeof value === 'string' ? value : undefined
}
