import { estimateStringChars as nativeEstimateStringChars } from '@agentbull/bullx-native-addons'

export const CHARS_PER_TOKEN_ESTIMATE = 4

/**
 * CJK-aware character estimate for token counting: CJK code points weigh a
 * full estimated token (4 chars) under the 4-chars/token heuristic. The scan
 * runs in the native addon — this sits on the compaction-trigger hot path.
 */
export function estimateStringChars(text: string): number {
  if (text.length === 0) return 0
  return nativeEstimateStringChars(text)
}

export function estimateTokensFromChars(chars: number): number {
  return Math.ceil(Math.max(0, chars) / CHARS_PER_TOKEN_ESTIMATE)
}
