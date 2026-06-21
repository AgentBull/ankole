import type { Message } from '@/llm'
import type { AgentMessage } from '../../types'

/**
 * File paths touched over a compaction range, split by how they were touched.
 *
 * The three sets are kept apart so the summary can distinguish files the agent only looked at from files
 * it changed: `read` ∖ (`written` ∪ `edited`) is genuinely read-only, while `written` (whole-file) and
 * `edited` (in-place) together form the "modified" list. Recording these in the summary lets a
 * post-compaction turn know which paths were already in play without re-reading the dropped history.
 */
export interface FileOperations {
  /** Files read but not necessarily modified. */
  read: Set<string>
  /** Files written by full-file write operations. */
  written: Set<string>
  /** Files modified by edit operations. */
  edited: Set<string>
}

/** Create an empty file-operation accumulator. */
export function createFileOps(): FileOperations {
  return {
    read: new Set(),
    written: new Set(),
    edited: new Set()
  }
}

/**
 * Scans one assistant message for `read`/`write`/`edit` tool calls and records the paths they touched.
 *
 * Reads the intent from the tool CALL, not the tool result: the call is where the path argument lives,
 * and the call is enough to know a file was involved even if its result was later cleared by
 * microcompaction. The chain of defensive guards tolerates loosely-typed / legacy persisted content —
 * non-object blocks, missing `arguments`, or a non-string `path` are skipped instead of throwing, so one
 * malformed historical message cannot break a whole compaction.
 */
export function extractFileOpsFromMessage(message: AgentMessage, fileOps: FileOperations): void {
  if (message.role !== 'assistant') return
  if (!('content' in message) || !Array.isArray(message.content)) return

  for (const block of message.content) {
    if (typeof block !== 'object' || block === null) continue
    if (!('type' in block) || block.type !== 'toolCall') continue
    if (!('arguments' in block) || !('name' in block)) continue

    const args = block.arguments as Record<string, unknown> | undefined
    if (!args) continue

    const path = typeof args.path === 'string' ? args.path : undefined
    if (!path) continue

    switch (block.name) {
      case 'read':
        fileOps.read.add(path)
        break
      case 'write':
        fileOps.written.add(path)
        break
      case 'edit':
        fileOps.edited.add(path)
        break
    }
  }
}

/**
 * Collapses the three operation sets into two sorted lists for the summary: modified (written ∪ edited)
 * and read-only (read minus anything modified). A file that was both read and later changed counts only
 * as modified, so it is not double-listed. Sorting makes the summary text deterministic.
 */
export function computeFileLists(fileOps: FileOperations): { readFiles: string[]; modifiedFiles: string[] } {
  const modified = new Set([...fileOps.edited, ...fileOps.written])
  const readOnly = [...fileOps.read].filter(f => !modified.has(f)).sort()
  const modifiedFiles = [...modified].sort()
  return { readFiles: readOnly, modifiedFiles }
}

/** Format file lists as summary metadata tags. */
export function formatFileOperations(readFiles: string[], modifiedFiles: string[]): string {
  const sections: string[] = []
  if (readFiles.length > 0) {
    sections.push(`<read-files>\n${readFiles.join('\n')}\n</read-files>`)
  }
  if (modifiedFiles.length > 0) {
    sections.push(`<modified-files>\n${modifiedFiles.join('\n')}\n</modified-files>`)
  }
  if (sections.length === 0) return ''
  return `\n\n${sections.join('\n\n')}`
}

// Tool results are the bulkiest part of a transcript (file dumps, search output). Capping each one keeps
// the serialized text — which is itself fed to the summarizer LLM — from blowing that model's own input
// budget. A few thousand chars is enough for the summarizer to grasp what a result was; the full payload
// is not needed to write a summary.
const TOOL_RESULT_MAX_CHARS = 2000

// Tool arguments can contain values that do not round-trip through JSON (cycles, bigint, etc.). Falling
// back to a marker keeps serialization total instead of throwing mid-transcript.
function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? 'undefined'
  } catch {
    return '[unserializable]'
  }
}

/** Trims overlong text and appends a note of how many characters were dropped, so the cut is visible. */
function truncateForSummary(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  const truncatedChars = text.length - maxChars
  return `${text.slice(0, maxChars)}\n\n[... ${truncatedChars} more characters truncated]`
}

/**
 * Flattens an LLM message list into a single plain-text transcript for the summarizer prompt.
 *
 * The model that writes the summary reads this text, not the structured messages, so each block is
 * rendered with a readable `[Role]:` tag. Thinking, visible text, and tool calls from one assistant
 * message are split into separate tagged lines so the summarizer can tell reasoning apart from output.
 * Tool results are truncated (see {@link TOOL_RESULT_MAX_CHARS}); empty blocks are skipped to avoid
 * noise.
 */
export function serializeConversation(messages: Message[]): string {
  const parts: string[] = []

  for (const msg of messages) {
    if (msg.role === 'user') {
      const content =
        typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
              .map(c => c.text)
              .join('')
      if (content) parts.push(`[User]: ${content}`)
    } else if (msg.role === 'assistant') {
      const textParts: string[] = []
      const thinkingParts: string[] = []
      const toolCalls: string[] = []

      for (const block of msg.content) {
        if (block.type === 'text') {
          textParts.push(block.text)
        } else if (block.type === 'thinking') {
          thinkingParts.push(block.thinking)
        } else if (block.type === 'toolCall') {
          const args = block.arguments as Record<string, unknown>
          const argsStr = Object.entries(args)
            .map(([k, v]) => `${k}=${safeJsonStringify(v)}`)
            .join(', ')
          toolCalls.push(`${block.name}(${argsStr})`)
        }
      }

      if (thinkingParts.length > 0) {
        parts.push(`[Assistant thinking]: ${thinkingParts.join('\n')}`)
      }
      if (textParts.length > 0) {
        parts.push(`[Assistant]: ${textParts.join('\n')}`)
      }
      if (toolCalls.length > 0) {
        parts.push(`[Assistant tool calls]: ${toolCalls.join('; ')}`)
      }
    } else if (msg.role === 'toolResult') {
      const content = msg.content
        .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
        .map(c => c.text)
        .join('')
      if (content) {
        parts.push(`[Tool result]: ${truncateForSummary(content, TOOL_RESULT_MAX_CHARS)}`)
      }
    }
  }

  return parts.join('\n\n')
}
