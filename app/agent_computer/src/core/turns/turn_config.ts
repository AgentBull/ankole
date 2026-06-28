import { ms } from '@pleisto/active-support'

export const TOOL_RESULT_MAX_CHARS = 12_000
export const TEXT_TURN_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_TURN_TIMEOUT_MS', ms('3m'))
export const COMPRESSION_TURN_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_COMPRESSION_TIMEOUT_MS', ms('90s'))
export const AMBIENT_RECOGNIZER_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_AMBIENT_RECOGNIZER_TIMEOUT_MS', ms('45s'))
export const PROMPT_SEND_AT_GAP_MS = ms('1h')
export const COMPRESSION_KEEP_RECENT_TOKENS = 20_000

function positiveIntegerEnv(name: string, fallback: number): number {
  const raw = process.env[name]
  if (!raw) return fallback

  const value = Number.parseInt(raw, 10)
  return Number.isFinite(value) && value > 0 ? value : fallback
}
