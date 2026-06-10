import type { ImageContent, TextContent } from '@earendil-works/pi-ai'
import type { AgentMessage } from '../types'

/** Result of a fallible operation. Expected failures are returned as `ok: false` instead of thrown. */
export type Result<TValue, TError> = { ok: true; value: TValue } | { ok: false; error: TError }

/** Create a successful {@link Result}. */
export function ok<TValue, TError>(value: TValue): Result<TValue, TError> {
  return { ok: true, value }
}

/** Create a failed {@link Result}. */
export function err<TValue, TError>(error: TError): Result<TValue, TError> {
  return { ok: false, error }
}

/**
 * Skill loaded from the agent library or provided by an application.
 *
 * `name`, `description`, and `filePath` are inserted into the system prompt in an XML-formatted block as
 * suggested by agentskills.io. Use `formatSkillsForSystemPrompt` (prompts/skills-prompt.ts) to generate
 * the system prompt block.
 */
export interface Skill {
  /** Stable skill name used for lookup and model-visible listings. */
  name: string
  /** Short model-visible description of when to use the skill. */
  description: string
  /** Full skill instructions. */
  content: string
  /** Absolute path to the skill file. Used for model-visible location and resolving relative references. */
  filePath: string
  /** Exclude this skill from model-visible skill lists while still allowing explicit application invocation. */
  disableModelInvocation?: boolean
}

/** Stable compaction error codes returned by compaction helpers. */
export type CompactionErrorCode = 'aborted' | 'summarization_failed' | 'invalid_session' | 'unknown'

/** Error returned by compaction helpers. */
export class CompactionError extends Error {
  /** Backend-independent error code. */
  public code: CompactionErrorCode

  constructor(code: CompactionErrorCode, message: string, cause?: Error) {
    super(message, cause === undefined ? undefined : { cause })
    this.name = 'CompactionError'
    this.code = code
  }
}

export interface SessionTreeEntryBase {
  type: string
  id: string
  parentId: string | null
  timestamp: string
}

export interface MessageEntry extends SessionTreeEntryBase {
  type: 'message'
  message: AgentMessage
}

export interface ThinkingLevelChangeEntry extends SessionTreeEntryBase {
  type: 'thinking_level_change'
  thinkingLevel: string
}

export interface ModelChangeEntry extends SessionTreeEntryBase {
  type: 'model_change'
  provider: string
  modelId: string
}

export interface ActiveToolsChangeEntry extends SessionTreeEntryBase {
  type: 'active_tools_change'
  activeToolNames: string[]
}

export interface CompactionEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'compaction'
  summary: string
  firstKeptEntryId: string
  tokensBefore: number
  details?: T
  fromHook?: boolean
}

export interface CustomEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'custom'
  customType: string
  data?: T
}

export interface CustomMessageEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'custom_message'
  customType: string
  content: string | (TextContent | ImageContent)[]
  details?: T
  display: boolean
}

export interface LabelEntry extends SessionTreeEntryBase {
  type: 'label'
  targetId: string
  label: string | undefined
}

export interface SessionInfoEntry extends SessionTreeEntryBase {
  type: 'session'
  name?: string
}

export interface LeafEntry extends SessionTreeEntryBase {
  type: 'leaf'
  targetId: string | null
}

export type SessionTreeEntry =
  | MessageEntry
  | ThinkingLevelChangeEntry
  | ModelChangeEntry
  | ActiveToolsChangeEntry
  | CompactionEntry
  | CustomEntry
  | CustomMessageEntry
  | LabelEntry
  | SessionInfoEntry
  | LeafEntry

export interface SessionContext {
  messages: AgentMessage[]
  thinkingLevel: string
  model: { provider: string; modelId: string } | null
  activeToolNames: string[] | null
}
