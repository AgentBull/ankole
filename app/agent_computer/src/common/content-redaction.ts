export const redactionMarker = '[REDACTED]'

export function redactText(value: string): string {
  return value
    .replace(/-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\n]*PRIVATE KEY-----/gi, redactionMarker)
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, `Bearer ${redactionMarker}`)
    .replace(/\bsk-[A-Za-z0-9_-]{8,}/g, redactionMarker)
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, redactionMarker)
    .replace(
      /\b(api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?token|password|passphrase|secret|secret[_-]?key|credential|authorization|cookie|private[_-]?key|signature)\b(["']?)(\s*[:=]\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;]+)/gi,
      (_match, label: string, keyQuote: string, separator: string, secret: string) => {
        const quote = secret.startsWith('"') ? '"' : secret.startsWith("'") ? "'" : ''
        return `${label}${keyQuote}${separator}${quote}${redactionMarker}${quote}`
      }
    )
}

export function sensitiveKey(value: string): boolean {
  const key = value
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/-/g, '_')
    .toLowerCase()
  return /(?:^|_)(?:authorization|proxy_authorization|apikey|api_key|token|access_token|refresh_token|id_token|auth_token|bearer_token|session_token|secret|secret_key|client_secret|password|password_hash|passphrase|cookie|set_cookie|signature|credential|credentials|private_key|private_key_pem|secret_access_key|access_key_id)$/.test(
    key
  )
}
