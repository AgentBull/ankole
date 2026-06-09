import type { JsonValue } from '@/common/db-schema'

const MIN_TOKEN_LENGTH = 18
const KEEP_START = 6
const KEEP_END = 4
const PREFILTER =
  /(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|COOKIE|SIGNATURE|PRIVATE KEY|\bBearer\s+|sk-|ghp_|github_pat_|xox[baprs]-|xapp-|gsk_|AIza|ya29\.|1\/\/0|eyJ|pplx-|npm_|AKID|LTAI|hf_|r8_|\bbot\d{6,}:|\b\d{6,}:[A-Za-z0-9_-]{20,})/i

const PATTERNS: RegExp[] = [
  /\b[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)\b\s*[=:]\s*(["']?)([^\s"'\\]+)\1/g,
  /[?&](?:access[-_]?token|auth[-_]?token|hook[-_]?token|refresh[-_]?token|api[-_]?key|client[-_]?secret|token|key|secret|password|pass|passwd|auth|signature)=([^&\s"'<>]+)/gi,
  /"(?:apiKey|token|secret|password|passwd|accessToken|refreshToken)"\s*:\s*"([^"]+)"/g,
  /(^|[\s,{])["']?(?:api[-_]key|access[-_]token|refresh[-_]token|authToken|auth[-_]token|clientSecret|client[-_]secret|appSecret|app[-_]secret)["']?\s*[:=]\s*(["'])([^"'\r\n]+)\2/gi,
  /(^|[\s,{])["']?(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token)["']?\s*[:=]\s*(["'])([^"'\r\n]+)\2/gi,
  /--(?:api[-_]?key|hook[-_]?token|token|secret|password|passwd)\s+(["']?)([^\s"']+)\1/gi,
  /Authorization\s*[:=]\s*Bearer\s+([A-Za-z0-9._\-+=]+)/gi,
  /Authorization\s*[:=]\s*Basic\s+([A-Za-z0-9+/=]+)/gi,
  /\bBearer\s+([A-Za-z0-9._\-+=]{18,})\b/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----/g,
  /\b(sk-[A-Za-z0-9_-]{8,})\b/g,
  /(ghp_[A-Za-z0-9]{20,})/g,
  /(github_pat_[A-Za-z0-9_]{20,})/g,
  /(xox[baprs]-[A-Za-z0-9-]{10,})/g,
  /(xapp-[A-Za-z0-9-]{10,})/g,
  /(gsk_[A-Za-z0-9_-]{10,})/g,
  /(AIza[0-9A-Za-z\-_]{20,})/g,
  /(ya29\.[0-9A-Za-z_\-./+=]{10,})/g,
  /(1\/\/0[0-9A-Za-z_\-./+=]{10,})/g,
  /(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/g,
  /(pplx-[A-Za-z0-9_-]{10,})/g,
  /(npm_[A-Za-z0-9]{10,})/g,
  /(AKID[A-Za-z0-9]{10,})/g,
  /(LTAI[A-Za-z0-9]{10,})/g,
  /(hf_[A-Za-z0-9]{10,})/g,
  /(r8_[A-Za-z0-9]{10,})/g,
  /\bbot(\d{6,}:[A-Za-z0-9_-]{20,})\b/g,
  /\b(\d{6,}:[A-Za-z0-9_-]{20,})\b/g
]

const SENSITIVE_KEY_RE =
  /^(?:api[-_]?key|apiKey|token|secret|password|passwd|access[-_]?token|accessToken|refresh[-_]?token|refreshToken|id[-_]?token|idToken|auth[-_]?token|authToken|client[-_]?secret|clientSecret|app[-_]?secret|appSecret|authorization|cookie|set-cookie)$/i

export function redactSensitiveText(text: string): string {
  if (!text || !PREFILTER.test(text)) return text
  let output = text
  for (const pattern of PATTERNS) {
    output = output.replace(pattern, (...args: string[]) => {
      const match = args[0]!
      if (match.includes('PRIVATE KEY-----')) return redactPemBlock(match)
      const groups = args.slice(1, -2).filter(Boolean)
      const token = groups.at(-1) ?? match
      const masked = maskToken(token)
      return token === match ? masked : match.replace(token, masked)
    })
  }
  return output
}

export function redactJsonValue(value: unknown, depth = 0, seen = new WeakSet<object>()): JsonValue {
  if (value === null || value === undefined) return null
  if (typeof value === 'string') return redactSensitiveText(value)
  if (typeof value === 'number' || typeof value === 'boolean') return value
  if (typeof value !== 'object') return redactSensitiveText(String(value))
  if (seen.has(value)) return '[Circular]'
  if (depth >= 20) return '[MaxDepth]'
  seen.add(value)
  if (Array.isArray(value)) return value.map(item => redactJsonValue(item, depth + 1, seen))
  const out: Record<string, JsonValue> = {}
  for (const [key, child] of Object.entries(value)) {
    if (typeof child === 'string' && SENSITIVE_KEY_RE.test(key)) {
      out[key] = maskToken(child)
    } else {
      out[key] = redactJsonValue(child, depth + 1, seen)
    }
  }
  return out
}

export function redactLogArg(value: unknown): unknown {
  if (typeof value === 'string') return redactSensitiveText(value)
  if (!value || typeof value !== 'object') return value
  return redactJsonValue(value)
}

function maskToken(token: string): string {
  if (token.length < MIN_TOKEN_LENGTH) return '***'
  return `${token.slice(0, KEEP_START)}...${token.slice(-KEEP_END)}`
}

function redactPemBlock(block: string): string {
  const lines = block.split(/\r?\n/).filter(Boolean)
  if (lines.length < 2) return '***'
  return `${lines[0]}\n...redacted...\n${lines.at(-1)}`
}
