import type { BrainSnapshot, BrainSnapshotEntry } from '../lanes/rpc_lane'

/** Renders saved resident context for a tool-capable agent run. */
export function formatAgentDurableContext(snapshot: BrainSnapshot | undefined): string {
  return formatDurableContext(
    snapshot,
    'This is saved durable context for the current agent and channel. Use an item only if it remains valid, is supported with sufficient confidence, and is directly relevant to the current topic; otherwise ignore it.',
    'Some saved context was omitted for length. Retrieve current memory before relying on omitted details.'
  )
}

/** Renders saved resident context for the tool-free ambient intervention decision. */
export function formatAmbientDurableContext(snapshot: BrainSnapshot | undefined): string {
  return formatDurableContext(
    snapshot,
    'Use this saved context only to decide whether to speak. You cannot retrieve memory; stay silent if missing or newer context could change the decision.',
    'Some saved context was omitted for length. Stay silent when the omitted context could affect the decision.'
  )
}

function formatDurableContext(
  snapshot: BrainSnapshot | undefined,
  guidance: string,
  incompleteGuidance: string
): string {
  const entries = [
    durableEntry('agent_context', snapshot?.pinnedMemo),
    durableEntry('group_context', snapshot?.channelEntry)
  ].filter((entry): entry is RenderedDurableEntry => entry !== undefined)
  if (entries.length === 0) return ''

  return [
    '<durable_context>',
    guidance,
    ...entries.map(entry => entry.text),
    entries.some(entry => entry.incomplete) ? incompleteGuidance : '',
    '</durable_context>'
  ]
    .filter(Boolean)
    .join('\n')
}

type RenderedDurableEntry = {
  incomplete: boolean
  text: string
}

function durableEntry(
  tag: 'agent_context' | 'group_context',
  entry: BrainSnapshotEntry | undefined
): RenderedDurableEntry | undefined {
  if (!entry) return undefined
  const content = entry.residentText.trim()
  if (!content) return undefined

  return {
    incomplete: entry.truncated === true,
    text: [`<${tag}>`, content, `</${tag}>`].join('\n')
  }
}
