// Last-line secret scrubber for anything that leaves the agent computer toward a human or a log: tool
// output, error text, request/response payloads, logger arguments. It is best-effort pattern matching,
// not a guarantee — the goal is to keep API keys, bearer tokens, cookies, and private keys out of logs
// and UI echoes, accepting that a secret in a novel format may slip through. The whole module leans
// deliberately toward over-masking: hiding a suspicious-looking token fragment from diagnostics is far
// cheaper than leaking a live credential.
import type { JsonValue } from '@/common/db-schema'

// A masked token keeps its first 6 and last 4 chars (enough to recognise *which* key it was when
// debugging) and hides the middle. Anything shorter than 18 chars is replaced wholesale with `***`,
// because keeping head+tail of a short secret would reveal most of it.
const MIN_TOKEN_LENGTH = 18
const KEEP_START = 6
const KEEP_END = 4
// Cheap gate run on every string before the expensive pattern list below: if none of these tell-tale
// substrings are present, the text cannot contain a secret we recognise and is returned untouched, which
// keeps ordinary log lines fast. The list is the union of generic secret words and the distinctive fixed
// prefixes of common token formats — OpenAI `sk-`, GitHub `ghp_`/`github_pat_`, Slack `xox*`/`xapp-`,
// Groq `gsk_`, Google `AIza`/`ya29.`/`1//0`, JWT `eyJ`, Perplexity `pplx-`, npm `npm_`, AWS `AKID`,
// Alibaba `LTAI`, HuggingFace `hf_`, Replicate `r8_`, and Telegram bot tokens.
const PREFILTER =
  /(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|COOKIE|SIGNATURE|PRIVATE KEY|\bBearer\s+|sk-|ghp_|github_pat_|xox[baprs]-|xapp-|gsk_|AIza|ya29\.|1\/\/0|eyJ|pplx-|npm_|AKID|LTAI|hf_|r8_|\bbot\d{6,}:|\b\d{6,}:[A-Za-z0-9_-]{20,})/i

// The actual scrub patterns, applied in order. They fall into two families. The first group is
// CONTEXTUAL — a secret-ish key paired with a value (`KEY=...`, `?token=...`, `"apiKey":"..."`,
// `Authorization: Bearer ...`, CLI `--token ...`); these capture the value in a group so only the value
// is masked, not the surrounding key/syntax. The second group is FORMAT-SHAPED — values recognisable on
// their own by a known prefix and length (the same vendor token formats the PREFILTER lists, plus PEM
// private-key blocks). Order matters only loosely: each pattern masks its own matches, and the value
// group is always the LAST capture group (see how redactSensitiveText picks `groups.at(-1)`).
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

// Names of object keys whose string value is masked outright by redactJsonValue, regardless of what the
// value looks like. This complements the text patterns above: a secret stored under an obvious key
// (`{ token: "abc" }`) may not match any value-shape pattern, but the KEY itself betrays it. Anchored
// (`^...$`) so it matches the whole key, not a substring like `tokenCount`.
const SENSITIVE_KEY_RE =
  /^(?:api[-_]?key|apiKey|token|secret|password|passwd|access[-_]?token|accessToken|refresh[-_]?token|refreshToken|id[-_]?token|idToken|auth[-_]?token|authToken|client[-_]?secret|clientSecret|app[-_]?secret|appSecret|authorization|cookie|set-cookie)$/i

/**
 * Masks likely secrets in free-form text before it reaches logs or UI echoes.
 *
 * The cheap prefilter keeps normal log lines fast. The regex list is purposely
 * broad and may over-mask; leaking a credential is more expensive than hiding a
 * suspicious-looking token fragment from diagnostics.
 */
export function redactSensitiveText(text: string): string {
  if (!text || !PREFILTER.test(text)) return text
  let output = text
  for (const pattern of PATTERNS) {
    output = output.replace(pattern, (...args: string[]) => {
      const match = args[0]!
      // PEM blocks span many lines; mask the body but keep the BEGIN/END markers so the text stays legible.
      if (match.includes('PRIVATE KEY-----')) return redactPemBlock(match)
      // String.replace passes (fullMatch, ...captureGroups, offset, fullString); slicing off the first
      // (the match) and the last two (offset + full string) leaves just the capture groups. By
      // convention every pattern puts the secret VALUE in its last group, so `groups.at(-1)` is the token
      // to mask; falling back to the whole match covers format-shaped patterns with no inner group.
      const groups = args.slice(1, -2).filter(Boolean)
      const token = groups.at(-1) ?? match
      const masked = maskToken(token)
      // When the token is the whole match, replace it directly; otherwise splice the masked value back
      // into the match so the surrounding key/quotes/`=` are preserved and only the secret is hidden.
      return token === match ? masked : match.replace(token, masked)
    })
  }
  return output
}

/**
 * Recursively redacts JSON-like data while preserving a serializable shape.
 *
 * Depth and circular-reference guards keep logging safe even when callers pass
 * rich runtime objects instead of plain request bodies.
 */
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

/**
 * Redacts one logger argument without forcing primitive values through JSON.
 */
export function redactLogArg(value: unknown): unknown {
  if (typeof value === 'string') return redactSensitiveText(value)
  if (!value || typeof value !== 'object') return value
  return redactJsonValue(value)
}

function maskToken(token: string): string {
  if (token.length < MIN_TOKEN_LENGTH) return '***'
  return `${token.slice(0, KEEP_START)}...${token.slice(-KEEP_END)}`
}

// Collapses a multi-line PEM private key into its first and last lines (the `-----BEGIN/END-----`
// markers) with the key material between them replaced. A degenerate block with fewer than two lines has
// no safe markers to keep, so it is masked entirely.
function redactPemBlock(block: string): string {
  const lines = block.split(/\r?\n/).filter(Boolean)
  if (lines.length < 2) return '***'
  return `${lines[0]}\n...redacted...\n${lines.at(-1)}`
}
