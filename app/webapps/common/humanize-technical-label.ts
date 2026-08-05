const TECHNICAL_TERMS = new Map([
  ['ai', 'AI'],
  ['api', 'API'],
  ['gl', 'GL'],
  ['hl', 'HL'],
  ['http', 'HTTP'],
  ['id', 'ID'],
  ['json', 'JSON'],
  ['ldap', 'LDAP'],
  ['oauth', 'OAuth'],
  ['oidc', 'OIDC'],
  ['serp', 'SERP'],
  ['sso', 'SSO'],
  ['url', 'URL']
])

/** Turns an identifier into a readable label while preserving approved technical terms. */
export function humanizeTechnicalLabel(value: string): string {
  const words = value
    .replace(/([a-z\d])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[\s_-]+/)
    .filter(Boolean)
    .map(word => {
      const normalized = word.toLowerCase()
      return TECHNICAL_TERMS.get(normalized) ?? normalized
    })
  const joined = words.join(' ')
  return joined.charAt(0).toUpperCase() + joined.slice(1)
}
