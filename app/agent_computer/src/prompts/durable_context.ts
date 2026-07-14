import type { RuntimeBrainSnapshot, RuntimeBrainSnapshotEntry } from '../lanes/rpc_lane'

/** Renders saved resident context for a tool-capable agent run. */
export function formatAgentDurableContext(snapshot: RuntimeBrainSnapshot | undefined): string {
  return formatDurableContext(
    snapshot,
    'This is saved durable context for the current agent and channel. Apply it directly.',
    'Some saved context was omitted for length. Retrieve current memory before relying on omitted details.'
  )
}

/** Renders saved resident context for the tool-free ambient intervention decision. */
export function formatAmbientDurableContext(snapshot: RuntimeBrainSnapshot | undefined): string {
  return formatDurableContext(
    snapshot,
    'Use this saved context only to decide whether to speak. You cannot retrieve memory; stay silent if missing or newer context could change the decision.',
    'Some saved context was omitted for length. Stay silent when the omitted context could affect the decision.'
  )
}

function formatDurableContext(
  snapshot: RuntimeBrainSnapshot | undefined,
  guidance: string,
  incompleteGuidance: string
): string {
  const entries = [
    durableEntry('agent_context', snapshot?.pinned_memo),
    durableEntry('group_context', snapshot?.channel_entry)
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
  entry: RuntimeBrainSnapshotEntry | null | undefined
): RenderedDurableEntry | undefined {
  if (!entry) return undefined
  const content = entry.resident_text.trim()
  if (!content) return undefined

  return {
    incomplete: entry.truncated === true,
    text: [`<${tag}>`, content, `</${tag}>`].join('\n')
  }
}
