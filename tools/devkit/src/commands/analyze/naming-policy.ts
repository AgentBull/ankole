export const CANONICAL_INITIALISMS = [
  'AI',
  'ALPN',
  'API',
  'AWS',
  'CDP',
  'CLI',
  'DB',
  'HTML',
  'HTTP',
  'HTTPS',
  'ID',
  'IM',
  'IP',
  'JSON',
  'JWT',
  'LLM',
  'MCP',
  'NAPI',
  'NIF',
  'OIDC',
  'OTP',
  'RPC',
  'SDK',
  'SQL',
  'SSE',
  'TCP',
  'TLS',
  'UID',
  'URI',
  'URL',
  'UTF8',
  'UUID',
  'VFS',
  'XML',
  'ZMQ'
] as const

type ReplacementRule = readonly [source: string, target: string]

const titleCaseInitialisms = new Set(
  CANONICAL_INITIALISMS.map(initialism => `${initialism[0]}${initialism.slice(1).toLowerCase()}`)
)

const initialismRules: ReplacementRule[] = CANONICAL_INITIALISMS.flatMap(initialism => {
  const titleCase = `${initialism[0]}${initialism.slice(1).toLowerCase()}`
  const singular: ReplacementRule = [titleCase, initialism]
  const pluralSource = `${titleCase}s`
  const plural: ReplacementRule = [pluralSource, `${initialism}s`]
  return titleCaseInitialisms.has(pluralSource) ? [singular] : [plural, singular]
})

const specialRules: ReplacementRule[] = [
  ['Openai', 'OpenAI'],
  ['Oauth', 'OAuth'],
  ['Postgres', 'PostgreSQL'],
  ['Websocket', 'WebSocket'],
  ['Ws', 'WebSocket']
]

const replacementRules = [...initialismRules, ...specialRules].toSorted(([left], [right]) => right.length - left.length)

function replaceIdentifierSegment(value: string, source: string, target: string): string {
  const pattern = new RegExp(`(^|[A-Za-z0-9])${source}(?=[A-Z0-9]|$)`, 'g')
  return value.replace(pattern, (_match, prefix: string) => `${prefix}${target}`)
}

export function canonicalPascalIdentifier(value: string): string {
  return replacementRules.reduce(
    (canonical, [source, target]) => replaceIdentifierSegment(canonical, source, target),
    value
  )
}

export function canonicalCamelIdentifier(value: string): string {
  const canonical = canonicalPascalIdentifier(value)
  if (!/^[A-Z]/.test(canonical)) return canonical
  if (/^[A-Z]+$/.test(canonical)) return canonical.toLowerCase()

  const leadingInitialism = canonical.match(/^[A-Z]+(?=[A-Z][a-z])/u)?.[0]
  if (leadingInitialism) {
    return `${leadingInitialism.toLowerCase()}${canonical.slice(leadingInitialism.length)}`
  }

  return `${canonical[0]!.toLowerCase()}${canonical.slice(1)}`
}

export function canonicalSourcePath(value: string): string {
  return value.replace(/(^|[/_-])aigateway(?=([._/-]|$))/g, '$1ai_gateway')
}
