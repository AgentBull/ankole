import type { ImageContent, TextContent } from '@/llm'
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
 * `name`, `description`, and optional `category` are inserted into the system prompt skill index.
 * Use `formatSkillsForSystemPrompt` (prompts/skills-prompt.ts) to generate the system prompt block.
 */
export interface Skill {
  /** Stable skill name used for lookup and model-visible listings. */
  name: string
  /** Short model-visible description of when to use the skill. */
  description: string
  /** Optional model-visible category used to group the skill index. */
  category?: string
  /** Full skill instructions. */
  content: string
  /** Absolute path to the skill file. Used for resolving relative references after the skill is loaded. */
  filePath: string
  /** Exclude this skill from model-visible skill lists while still allowing explicit application invocation. */
  disableModelInvocation?: boolean
}

/**
 * Stable compaction error codes returned by compaction helpers.
 *
 * Kept backend-independent on purpose: callers branch on the code, not on the message text, so the
 * wording can change without breaking error handling.
 *  - `aborted` — the summarization LLM call was cancelled (e.g. the run was stopped mid-compaction).
 *  - `summarization_failed` — the summarizer returned an error stop reason.
 *  - `invalid_session` — the chosen cut point has no entry id; the persisted session predates ids and
 *    needs migration before it can be compacted.
 */
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

/**
 * The transcript is stored as a tree, not a flat list: every entry points at its `parentId`, so a
 * conversation can branch (edit-and-retry, alternative replies) and a single root-to-leaf path is the
 * "current" history. These entries are the projection of the Postgres rows (see conversation-service.ts);
 * the harness only ever reads them, never writes them here.
 */
export interface SessionTreeEntryBase {
  type: string
  id: string
  /** Parent entry on the path; `null` only for the session root. */
  parentId: string | null
  /** ISO timestamp string as persisted; converted to epoch ms when projected into a message. */
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

/**
 * Marks a compaction checkpoint on the path. Everything between the previous boundary and
 * `firstKeptEntryId` is folded into `summary`; entries from `firstKeptEntryId` onward survive verbatim.
 * When projecting the path, the summary is injected as a reference-only user message and the folded
 * entries are skipped (see session.ts `buildSessionContext`).
 */
export interface CompactionEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'compaction'
  /** Replacement text for the folded history. */
  summary: string
  /** First surviving entry; everything before it on the path is represented only by `summary`. */
  firstKeptEntryId: string
  /** Estimated context tokens at the moment of compaction; kept for telemetry, not used to re-expand. */
  tokensBefore: number
  details?: T
  /**
   * True when the checkpoint came from an external hook rather than the built-in summarizer. Such
   * entries carry no trusted file-operation `details`, so the file-list carry-forward skips them (see
   * compaction.ts `extractFileOperations`).
   */
  fromHook?: boolean
}

/**
 * Application-defined bookkeeping that lives on the path but is NOT shown to the model: it carries
 * `data`, not message `content`. Contrast with {@link CustomMessageEntry}, which becomes a real user
 * message in the projected context.
 */
export interface CustomEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'custom'
  customType: string
  data?: T
}

/**
 * Application-injected content that DOES enter the model context as a synthetic user message (projected
 * via `createCustomMessage`). `display` controls whether the UI also renders it; the model sees it
 * regardless. Used for things like injected notices or out-of-band context the model should read.
 */
export interface CustomMessageEntry<T = unknown> extends SessionTreeEntryBase {
  type: 'custom_message'
  customType: string
  content: string | (TextContent | ImageContent)[]
  details?: T
  display: boolean
}

/** Renames/annotates another entry by id. Metadata only; never enters the model context. */
export interface LabelEntry extends SessionTreeEntryBase {
  type: 'label'
  targetId: string
  label: string | undefined
}

export interface SessionInfoEntry extends SessionTreeEntryBase {
  type: 'session'
  name?: string
}

/** Pointer marking which branch tip is the active leaf; lets the tree record the "current" path. */
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

/**
 * Flattened view of one path, ready to drive an LLM call. `buildSessionContext` walks the path and
 * folds the scattered `*_change` entries into a single resolved state: the message list plus the
 * thinking level, model, and active tool set that were in effect at the leaf. `null` fields mean the
 * path never set that dimension, so the caller's defaults apply.
 */
export interface SessionContext {
  messages: AgentMessage[]
  thinkingLevel: string
  model: { provider: string; modelId: string } | null
  activeToolNames: string[] | null
}
