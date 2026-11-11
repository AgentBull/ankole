import { isEncryptedValueMask } from '../common/encrypted-value-input'
import i18n from '../common/i18n'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode, requestErrorMessage } from '../common/request-errors'

export const ENV_VAR_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/
export const ENV_VAR_NAME_PATTERN = '^[A-Za-z_][A-Za-z0-9_]*$'
const RESERVED_ENV_VAR_NAMES = new Set([
  'PATH',
  'HOME',
  'SHELL',
  'TERM',
  'LANG',
  'BASH_ENV',
  'ENV',
  'WORKER_ID',
  'DATABASE_URL',
  'CODEX_UNSAFE_ALLOW_NO_SANDBOX'
])

export function isReservedEnvVarName(name: string): boolean {
  return name.startsWith('ANKOLE_') || RESERVED_ENV_VAR_NAMES.has(name)
}

export function formatPodEnvVarError(error: unknown): string {
  const payload = error instanceof InternalAPIError ? error.payload : error
  const code = requestErrorCode(payload)
  const known = code ? `pod.errors.${code}` : ''
  if (known && i18n.exists(known)) {
    return i18n.t(known)
  }
  if (error instanceof InternalAPIError && error.status === 401) {
    return i18n.t('pod.errors.unauthenticated')
  }
  return requestErrorMessage(error)
}

export type EnvVarSource = 'applet' | 'default' | 'pod' | 'site' | 'tenant' | 'global' | 'missing'

export type EnvVarEntry = {
  name: string
  secret: boolean
  required?: boolean
  declared?: boolean
  description?: string | null
  present: boolean
  source: EnvVarSource
  inherited_source?: 'default' | 'pod' | 'site' | 'global' | null
  value?: string | null
}

export type EnvVarSaveInput = {
  name: string
  value?: string
  secret: boolean
  description?: string | null
}

export type ParsedDotEnvItem = {
  name: string
  value: string
}

export type EnvVarImportFailure = {
  name: string
  value: string
  message: string
}

export type EnvVarImportOutcome = {
  saved: string[]
  failures: EnvVarImportFailure[]
}

export function formatDotEnvEntries(entries: readonly ParsedDotEnvItem[]): string {
  return entries
    .map(({ name, value }) => {
      if (value === '') return `${name}=`
      if (!/[\r\n\t"'\\$#]/.test(value) && value.trim() === value) {
        return `${name}=${value}`
      }
      const escaped = value
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\$/g, '\\$')
        .replace(/\r/g, '\\r')
        .replace(/\n/g, '\\n')
        .replace(/\t/g, '\\t')
      return `${name}="${escaped}"`
    })
    .join('\n')
}

export async function executeEnvVarBatchImport({
  entries,
  secret,
  putVar,
  refresh,
  onAllSaved
}: {
  entries: readonly ParsedDotEnvItem[]
  secret: boolean
  putVar: (input: EnvVarSaveInput) => Promise<unknown>
  refresh: () => Promise<unknown>
  onAllSaved?: (savedNames: string[]) => void
}): Promise<EnvVarImportOutcome> {
  const saved: string[] = []
  const failures: EnvVarImportFailure[] = []
  for (const entry of entries) {
    try {
      await putVar({
        name: entry.name,
        value: entry.value,
        secret,
        description: null
      })
      saved.push(entry.name)
    } catch (error) {
      failures.push({
        name: entry.name,
        value: entry.value,
        message: formatPodEnvVarError(error)
      })
    }
  }
  if (saved.length > 0) {
    await refresh()
  }
  if (failures.length === 0 && saved.length > 0) {
    onAllSaved?.(saved)
  }
  return { saved, failures }
}

export function formatImportOutcomeError(
  translate: (key: string, options: Record<string, unknown>) => string,
  outcome: EnvVarImportOutcome
): string | null {
  if (outcome.failures.length === 0) return null
  const failedDetails = outcome.failures.map(item => `${item.name} (${item.message})`).join(', ')
  if (outcome.saved.length > 0) {
    return translate('pod.env_vars.import_partial_failure', {
      savedNames: outcome.saved.join(', '),
      failedDetails
    })
  }
  return translate('pod.env_vars.import_failed', { failedDetails })
}

export type DotEnvParseDiagnostic = {
  line: number
  reason: 'invalid_syntax' | 'unclosed_quote' | 'invalid_name' | 'reserved_name'
  name?: string
}

export function inspectDotEnv(raw: string): {
  items: ParsedDotEnvItem[]
  errors: DotEnvParseDiagnostic[]
} {
  const src = raw.replace(/\r\n?/g, '\n')
  const entries = new Map<string, string>()
  const errors: DotEnvParseDiagnostic[] = []
  let pos = 0
  let line = 1

  const skipHorizontal = () => {
    while (pos < src.length && (src[pos] === ' ' || src[pos] === '\t')) pos++
  }

  const skipToLineEnd = () => {
    while (pos < src.length && src[pos] !== '\n') pos++
    if (pos < src.length && src[pos] === '\n') {
      pos++
      line++
    }
  }

  while (pos < src.length) {
    skipHorizontal()
    if (pos >= src.length) break
    if (src[pos] === '\n') {
      pos++
      line++
      continue
    }
    if (src[pos] === '#') {
      skipToLineEnd()
      continue
    }

    const entryLine = line
    const exportMatch = /^export[ \t]+/.exec(src.slice(pos))
    if (exportMatch) {
      pos += exportMatch[0].length
    }

    let eqPos = pos
    while (eqPos < src.length && src[eqPos] !== '=' && src[eqPos] !== '\n') eqPos++
    if (eqPos >= src.length || src[eqPos] !== '=') {
      errors.push({ line: entryLine, reason: 'invalid_syntax' })
      skipToLineEnd()
      continue
    }

    const name = src.slice(pos, eqPos).trim()
    pos = eqPos + 1
    skipHorizontal()

    let value = ''
    let syntaxFailed = false

    if (pos < src.length && (src[pos] === '"' || src[pos] === "'")) {
      const quote = src[pos]!
      pos++
      let closed = false
      while (pos < src.length) {
        const ch = src[pos]!
        if (quote === '"' && ch === '\\') {
          if (pos + 1 >= src.length) break
          const next = src[pos + 1]!
          pos += 2
          if (next === 'n') value += '\n'
          else if (next === 'r') value += '\r'
          else if (next === 't') value += '\t'
          else if (next === '"') value += '"'
          else if (next === '\\') value += '\\'
          else if (next === '$') value += '$'
          else if (next === '\n') {
            line++
            value += '\n'
          } else {
            value += `\\${next}`
          }
          continue
        }
        if (ch === quote) {
          pos++
          closed = true
          break
        }
        if (ch === '\n') line++
        value += ch
        pos++
      }

      if (!closed) {
        errors.push({ line: entryLine, reason: 'unclosed_quote', name })
        break
      }

      skipHorizontal()
      if (pos < src.length && src[pos] === '#') {
        skipToLineEnd()
      } else if (pos < src.length && src[pos] !== '\n') {
        errors.push({ line: entryLine, reason: 'invalid_syntax', name })
        skipToLineEnd()
        syntaxFailed = true
      } else if (pos < src.length && src[pos] === '\n') {
        pos++
        line++
      }
    } else {
      const valStart = pos
      while (pos < src.length && src[pos] !== '\n') pos++
      const rawValue = src.slice(valStart, pos)
      if (pos < src.length && src[pos] === '\n') {
        pos++
        line++
      }
      let commentIdx = -1
      for (let idx = 0; idx < rawValue.length; idx++) {
        if (rawValue[idx] === '#' && (idx === 0 || rawValue[idx - 1] === ' ' || rawValue[idx - 1] === '\t')) {
          commentIdx = idx
          break
        }
      }
      value = (commentIdx >= 0 ? rawValue.slice(0, commentIdx) : rawValue).trim()
    }

    if (syntaxFailed) continue
    if (!ENV_VAR_NAME_FORMAT.test(name)) {
      errors.push({ line: entryLine, reason: 'invalid_name', name })
      continue
    }
    if (isReservedEnvVarName(name)) {
      errors.push({ line: entryLine, reason: 'reserved_name', name })
      continue
    }
    entries.set(name, value)
  }

  return {
    items: [...entries.entries()].map(([name, value]) => ({ name, value })),
    errors
  }
}

export function shouldApplyDecryptedDraftValue({
  wasEditingTarget,
  requestEpoch,
  currentEpoch,
  currentEditingName,
  targetName,
  currentValue
}: {
  wasEditingTarget: boolean
  requestEpoch: number
  currentEpoch: number
  currentEditingName: string | null
  targetName: string
  currentValue: string
}): boolean {
  return (
    wasEditingTarget &&
    requestEpoch === currentEpoch &&
    currentEditingName === targetName &&
    isEncryptedValueMask(currentValue)
  )
}

export function resolveImportDraftCompletion({
  requestEpoch,
  currentEpoch,
  requestModeEpoch = 0,
  currentModeEpoch = requestModeEpoch,
  currentImportText,
  currentImportOpen,
  outcome
}: {
  requestEpoch: number
  currentEpoch: number
  requestModeEpoch?: number
  currentModeEpoch?: number
  currentImportText: string
  currentImportOpen: boolean
  outcome: EnvVarImportOutcome
}): { importText: string; importOpen: boolean } {
  if (requestEpoch !== currentEpoch) {
    return { importText: currentImportText, importOpen: currentImportOpen }
  }
  const modeUnchanged = requestModeEpoch === currentModeEpoch
  if (outcome.failures.length === 0) {
    return {
      importText: '',
      importOpen: modeUnchanged ? false : currentImportOpen
    }
  }
  return {
    importText: formatDotEnvEntries(outcome.failures),
    importOpen: modeUnchanged ? true : currentImportOpen
  }
}
