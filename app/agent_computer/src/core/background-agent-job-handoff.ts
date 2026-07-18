import { utf8ByteLength } from '../common/text-sanitize'

export const BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATHS = 32
export const BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATH_BYTES = 8_192

export type BackgroundAgentJobPathHandoff = {
  total_count: number
  paths: string[]
  truncated: boolean
}

export function emptyBackgroundAgentJobPathHandoff(): BackgroundAgentJobPathHandoff {
  return { total_count: 0, paths: [], truncated: false }
}

export function boundedBackgroundAgentJobPaths(
  values: Iterable<unknown>,
  declared: { totalCount?: unknown; truncated?: unknown } = {}
): BackgroundAgentJobPathHandoff {
  let observedCount = 0
  let invalidCount = 0
  let serializedBytes = 2
  const paths: string[] = []
  const selectedPaths = new Set<string>()

  for (const value of values) {
    if (typeof value !== 'string' || value.length === 0) {
      invalidCount += 1
      continue
    }

    observedCount += 1
    if (selectedPaths.has(value)) continue
    if (paths.length >= BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATHS) continue

    const encoded = JSON.stringify(value)
    const addedBytes = utf8ByteLength(encoded) + (paths.length === 0 ? 0 : 1)
    if (serializedBytes + addedBytes > BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATH_BYTES) continue

    paths.push(value)
    selectedPaths.add(value)
    serializedBytes += addedBytes
  }

  const declaredTotal = nonnegativeSafeInteger(declared.totalCount)
  const totalCount = Math.max(observedCount + invalidCount, declaredTotal ?? 0)
  return {
    total_count: totalCount,
    paths,
    truncated: declared.truncated === true || invalidCount > 0 || paths.length < totalCount
  }
}

export function mergeBackgroundAgentJobPathHandoffs(
  left: BackgroundAgentJobPathHandoff,
  right: BackgroundAgentJobPathHandoff
): BackgroundAgentJobPathHandoff {
  return boundedBackgroundAgentJobPaths([...left.paths, ...right.paths], {
    totalCount: left.total_count + right.total_count,
    truncated: left.truncated || right.truncated
  })
}

export function backgroundAgentJobPathHandoff(value: unknown): BackgroundAgentJobPathHandoff | undefined {
  if (Array.isArray(value)) return boundedBackgroundAgentJobPaths(value)
  if (!value || typeof value !== 'object') return undefined

  const handoff = value as Record<string, unknown>
  if (!Array.isArray(handoff.paths)) return undefined
  return boundedBackgroundAgentJobPaths(handoff.paths, {
    totalCount: handoff.total_count,
    truncated: handoff.truncated
  })
}

function nonnegativeSafeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}
