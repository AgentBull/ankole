import type { ImageContent, TextContent } from '@/llm'
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

  // First pass: resolve the settings that were in effect at the leaf. These are "last write wins" along
  // the path, so a later entry silently overrides an earlier one. An assistant message counts as a model
  // signal too — replaying a path pins the model that actually produced each reply, not just explicit
  // model_change markers. Only the LAST compaction is remembered; if the path was compacted more than
  // once, earlier checkpoints are already folded inside the latest summary.
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
  // Only `message` and `custom_message` entries carry model-visible content. Every other entry type
  // (label, leaf, the *_change markers, plain `custom` bookkeeping) is metadata and is dropped here.
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

  // Second pass: assemble the message list. When the path is compacted, the summary stands in for the
  // dropped prefix. The order matters and is the whole point of compaction:
  //   [summary] -> [entries from firstKeptEntryId .. just before the compaction marker] -> [entries after it]
  // The summary goes first so the model reads it as background before the surviving turns. Entries before
  // firstKeptEntryId are intentionally NOT appended — they are the history that was folded into the
  // summary, and re-adding them would defeat the token savings.
  if (compaction) {
    messages.push(createCompactionSummaryMessage(compaction.summary, compaction.tokensBefore, compaction.timestamp))
    const compactionIdx = pathEntries.findIndex(e => e.type === 'compaction' && e.id === compaction.id)
    // Keep the tail of the pre-marker region: skip everything until firstKeptEntryId is seen, then append
    // the rest. firstKeptEntryId is guaranteed to sit before the marker because compaction only ever folds
    // older history.
    let foundFirstKept = false
    for (let i = 0; i < compactionIdx; i++) {
      const entry = pathEntries[i]!
      if (entry.id === compaction.firstKeptEntryId) foundFirstKept = true
      if (foundFirstKept) appendMessage(entry)
    }
    // Everything appended after the marker is post-compaction work and is always kept in full.
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
