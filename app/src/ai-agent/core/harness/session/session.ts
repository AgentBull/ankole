import type { ImageContent, TextContent } from '@earendil-works/pi-ai'
import type { AgentMessage } from '../../types'
import { createCompactionSummaryMessage, createCustomMessage } from '../messages'
import type { CompactionEntry, SessionContext, SessionTreeEntry } from '../types'

/**
 * Project a root-to-leaf path of session-tree entries into the message list visible to the model.
 *
 * BullX keeps the transcript in Postgres and projects rows into `SessionTreeEntry[]` (see
 * conversation-service.ts), so only this pure projection is vendored. Upstream's `Session` class and its
 * JSONL/in-memory storage backends were dropped.
 */
export function buildSessionContext(pathEntries: SessionTreeEntry[]): SessionContext {
  let thinkingLevel = 'off'
  let model: { provider: string; modelId: string } | null = null
  let activeToolNames: string[] | null = null
  let compaction: CompactionEntry | null = null

  for (const entry of pathEntries) {
    if (entry.type === 'thinking_level_change') {
      thinkingLevel = entry.thinkingLevel
    } else if (entry.type === 'model_change') {
      model = { provider: entry.provider, modelId: entry.modelId }
    } else if (entry.type === 'message' && entry.message.role === 'assistant') {
      model = { provider: entry.message.provider, modelId: entry.message.model }
    } else if (entry.type === 'active_tools_change') {
      activeToolNames = [...entry.activeToolNames]
    } else if (entry.type === 'compaction') {
      compaction = entry
    }
  }

  const messages: AgentMessage[] = []
  const appendMessage = (entry: SessionTreeEntry) => {
    if (entry.type === 'message') {
      messages.push(entry.message as AgentMessage)
    } else if (entry.type === 'custom_message') {
      messages.push(
        createCustomMessage(
          entry.customType,
          entry.content as string | (TextContent | ImageContent)[],
          entry.display,
          entry.details,
          entry.timestamp
        )
      )
    }
  }

  if (compaction) {
    messages.push(createCompactionSummaryMessage(compaction.summary, compaction.tokensBefore, compaction.timestamp))
    const compactionIdx = pathEntries.findIndex(e => e.type === 'compaction' && e.id === compaction.id)
    let foundFirstKept = false
    for (let i = 0; i < compactionIdx; i++) {
      const entry = pathEntries[i]!
      if (entry.id === compaction.firstKeptEntryId) foundFirstKept = true
      if (foundFirstKept) appendMessage(entry)
    }
    for (let i = compactionIdx + 1; i < pathEntries.length; i++) {
      appendMessage(pathEntries[i]!)
    }
  } else {
    for (const entry of pathEntries) {
      appendMessage(entry)
    }
  }

  return { messages, thinkingLevel, model, activeToolNames }
}
