import { estimateStringChars as nativeEstimateStringChars } from '@agentbull/bullx-native-addons'

/**
 * Rough characters-per-token ratio for the 4-chars/token heuristic. Used only to
 * size context budgets and decide when to compact — it is a cheap estimate, not
 * an exact tokenizer count.
 */
export const CHARS_PER_TOKEN_ESTIMATE = 4

/**
 * CJK-aware character estimate for token counting: CJK code points weigh a
 * full estimated token (4 chars) under the 4-chars/token heuristic. The scan
 * runs in the native addon — this sits on the compaction-trigger hot path.
 */
export function estimateStringChars(text: string): number {
  // Short-circuit the empty case so the hot path never pays for a native call
  // (and FFI marshalling) just to get 0 back.
  if (text.length === 0) return 0
  return nativeEstimateStringChars(text)
}

/** Converts a weighted char count to an estimated token count, rounding up. The `max(0, …)` guards against a negative input yielding a nonsense count. */
export function estimateTokensFromChars(chars: number): number {
  return Math.ceil(Math.max(0, chars) / CHARS_PER_TOKEN_ESTIMATE)
}
