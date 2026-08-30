import { truncateUtf16Safe, utf8ByteLength } from '../common/text-sanitize'

const TOOL_RESULT_MAX_BYTES = 8_000

export function fitToolResultTextWindow<T extends object>(
  outputWindow: string,
  build: (outputText: string, truncatedForLimit: boolean) => T
): T | null {
  const complete = build(outputWindow, false)
  if (serializedBytes(complete) <= TOOL_RESULT_MAX_BYTES) return complete

  let low = 1
  let high = outputWindow.length - 1
  let result: T | null = null

  while (low <= high) {
    const middle = Math.floor((low + high) / 2)
    const candidate = truncateUtf16Safe(outputWindow, middle)
    const candidateResult = build(candidate, true)
    if (serializedBytes(candidateResult) <= TOOL_RESULT_MAX_BYTES) {
      if (candidate !== '') result = candidateResult
      low = middle + 1
    } else {
      high = middle - 1
    }
  }

  return result
}

function serializedBytes(value: object): number {
  return utf8ByteLength(JSON.stringify(value))
}
