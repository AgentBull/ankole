import type { AssistantMessage, ImageContent, Message, Model, SimpleStreamOptions, TextContent, Usage } from '@/llm'
import { generateBullXText } from '@/llm'
import type { AgentMessage, ThinkingLevel } from '../../types'
import { convertToLlm, createCompactionSummaryMessage, createCustomMessage } from '../messages'
import { buildSessionContext } from '../session/session'
import { type CompactionEntry, CompactionError, err, ok, type Result, type SessionTreeEntry } from '../types'
import {
  computeFileLists,
  createFileOps,
  extractFileOpsFromMessage,
  type FileOperations,
  formatFileOperations,
  serializeConversation
} from './utils'
import {
  SUMMARIZATION_SYSTEM_PROMPT,
  buildCompactionHistoryUserPrompt,
  buildTurnPrefixSummarizationUserPrompt
} from '../../../prompts/compression-prompt'

// Compaction is the heavyweight tier of the context-window defense. When the running history nears the
// model's limit, it replaces an OLD prefix of the transcript with an LLM-written summary, freeing tokens
// for new work. The tradeoff is explicit: detail in the dropped turns is lost forever (the persisted PG
// trajectory still has it, but the model-bound context does not), in exchange for not overflowing the
// window. What is protected from folding — recent turns within a token budget, and the system prompt,
// which lives outside this list — is chosen so the model keeps the context it most likely still needs.
// (The cheaper, no-LLM tier that merely clears re-derivable tool results is `microcompact.ts`.)

export { SUMMARIZATION_SYSTEM_PROMPT } from '../../../prompts/compression-prompt'

/** File-operation details stored on generated compaction entries. */
export interface CompactionDetails {
  /** Files read in the compacted history. */
  readFiles: string[]
  /** Files modified in the compacted history. */
  modifiedFiles: string[]
}
// Tool arguments may hold values JSON cannot represent; a marker keeps token estimation total rather
// than throwing while measuring a transcript.
function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? 'undefined'
  } catch {
    return '[unserializable]'
  }
}

/**
 * Collects the file paths touched in the range being compacted, seeded with the files the PREVIOUS
 * compaction already recorded.
 *
 * Carrying the prior list forward keeps the running file inventory complete across repeated
 * compactions — otherwise each new summary would forget every file touched before the last checkpoint.
 * Hook-generated checkpoints are skipped because their `details` are not produced by this extractor and
 * cannot be trusted to hold a readFiles/modifiedFiles shape. The `Array.isArray` guards defend against
 * older persisted entries whose `details` predate this format.
 */
function extractFileOperations(
  messages: AgentMessage[],
  entries: SessionTreeEntry[],
  prevCompactionIndex: number
): FileOperations {
  const fileOps = createFileOps()
  if (prevCompactionIndex >= 0) {
    const prevCompaction = entries[prevCompactionIndex] as CompactionEntry
    if (!prevCompaction.fromHook && prevCompaction.details) {
      const details = prevCompaction.details as CompactionDetails
      if (Array.isArray(details.readFiles)) {
        for (const f of details.readFiles) fileOps.read.add(f)
      }
      if (Array.isArray(details.modifiedFiles)) {
        for (const f of details.modifiedFiles) fileOps.edited.add(f)
      }
    }
  }
  for (const msg of messages) {
    extractFileOpsFromMessage(msg, fileOps)
  }

  return fileOps
}
/** Projects a single session entry to its message form, mirroring `buildSessionContext` for one entry. */
function getMessageFromEntry(entry: SessionTreeEntry): AgentMessage | undefined {
  if (entry.type === 'message') {
    return entry.message as AgentMessage
  }
  if (entry.type === 'custom_message') {
    return createCustomMessage(
      entry.customType,
      entry.content as string | (TextContent | ImageContent)[],
      entry.display,
      entry.details,
      entry.timestamp
    )
  }
  if (entry.type === 'compaction') {
    return createCompactionSummaryMessage(entry.summary, entry.tokensBefore, entry.timestamp)
  }
  return undefined
}

/**
 * Like {@link getMessageFromEntry}, but drops any compaction entry found inside the range being
 * summarized. A prior summary in the middle of the to-be-folded history would otherwise be re-summarized
 * into the new one, stacking summary-of-summary noise; the previous summary is instead threaded in
 * separately as `previousSummary`.
 */
function getMessageFromEntryForCompaction(entry: SessionTreeEntry): AgentMessage | undefined {
  if (entry.type === 'compaction') {
    return undefined
  }
  return getMessageFromEntry(entry)
}

/** Generated compaction data ready to be persisted as a compaction entry. */
export interface CompactionResult<T = unknown> {
  /** Summary text that replaces compacted history in future context. */
  summary: string
  /** Entry id where retained history starts. */
  firstKeptEntryId: string
  /** Estimated context tokens before compaction. */
  tokensBefore: number
  /** Optional implementation-specific details stored with the compaction entry. */
  details?: T
}

/** Compaction thresholds and retention settings. */
export interface CompactionSettings {
  /** Enable automatic compaction decisions. */
  enabled: boolean
  /**
   * Headroom below the context window. Compaction fires once usage crosses `contextWindow -
   * reserveTokens`, leaving this many tokens free for the next request and for the summarizer's own
   * prompt + output. Set it too low and a turn can overflow before compaction catches up; too high and
   * compaction runs more often than needed.
   */
  reserveTokens: number
  /**
   * Token budget of recent history to keep verbatim after compaction. The cut point is chosen so roughly
   * this many tokens of the newest turns survive; everything older is summarized. This is the core
   * detail-vs-window tradeoff dial.
   */
  keepRecentTokens: number
}

/** Default compaction settings used by the harness. */
export const DEFAULT_COMPACTION_SETTINGS: CompactionSettings = {
  enabled: true,
  reserveTokens: 16384,
  keepRecentTokens: 20000
}

/**
 * Total context tokens from a provider usage block. Prefers the provider's own `totalTokens`; only when
 * that is missing/zero does it sum the parts — cache reads and writes included, because cached prefix
 * tokens still occupy the context window even though they are billed differently.
 */
export function calculateContextTokens(usage: Usage): number {
  return usage.totalTokens || usage.input + usage.output + usage.cacheRead + usage.cacheWrite
}
// Returns an assistant message's usage only when it represents a real, completed turn. Aborted and
// errored turns are skipped: their usage is partial or absent and would understate the true context size,
// which could delay a needed compaction.
function getAssistantUsage(msg: AgentMessage): Usage | undefined {
  if (msg.role === 'assistant' && 'usage' in msg) {
    const assistantMsg = msg as AssistantMessage
    if (assistantMsg.stopReason !== 'aborted' && assistantMsg.stopReason !== 'error' && assistantMsg.usage) {
      return assistantMsg.usage
    }
  }
  return undefined
}

/**
 * Breakdown of a context-size estimate. Splits the figure into the provider-reported anchor
 * (`usageTokens`) and the heuristic tail measured past it (`trailingTokens`), with `tokens` their sum.
 * The split is exposed (not just the total) so callers can see how much of the number is trusted vs
 * estimated.
 */
export interface ContextUsageEstimate {
  /** Estimated total context tokens. */
  tokens: number
  /** Tokens reported by the most recent assistant usage block. */
  usageTokens: number
  /** Estimated tokens after the most recent assistant usage block. */
  trailingTokens: number
  /** Index of the message that provided usage, or null when none exists. */
  lastUsageIndex: number | null
}

// Walks backward to the most recent real assistant usage. That block is the provider's authoritative
// count of everything up to and including that turn, so it is the anchor for the whole estimate.
function getLastAssistantUsageInfo(messages: AgentMessage[]): { usage: Usage; index: number } | undefined {
  for (let i = messages.length - 1; i >= 0; i--) {
    const usage = getAssistantUsage(messages[i])
    if (usage) return { usage, index: i }
  }
  return undefined
}

/**
 * Estimates current context size, trusting the provider's last usage block and only guessing past it.
 *
 * The newest assistant usage gives an exact count up to that point; the cheaper char heuristic is applied
 * only to the messages AFTER it (the user message and tool results sent since, which have no usage of
 * their own yet). This hybrid avoids re-estimating the entire transcript by hand — which would drift from
 * the provider's real tokenization — while still accounting for what was added since the last reply. With
 * no usage at all (a fresh or all-failed history) it falls back to estimating every message.
 */
export function estimateContextTokens(messages: AgentMessage[]): ContextUsageEstimate {
  const usageInfo = getLastAssistantUsageInfo(messages)

  if (!usageInfo) {
    let estimated = 0
    for (const message of messages) {
      estimated += estimateTokens(message)
    }
    return {
      tokens: estimated,
      usageTokens: 0,
      trailingTokens: estimated,
      lastUsageIndex: null
    }
  }

  const usageTokens = calculateContextTokens(usageInfo.usage)
  let trailingTokens = 0
  for (let i = usageInfo.index + 1; i < messages.length; i++) {
    trailingTokens += estimateTokens(messages[i])
  }

  return {
    tokens: usageTokens + trailingTokens,
    usageTokens,
    trailingTokens,
    lastUsageIndex: usageInfo.index
  }
}

/** Whether usage has crossed the trigger line: the window minus the reserved headroom. */
export function shouldCompact(contextTokens: number, contextWindow: number, settings: CompactionSettings): boolean {
  if (!settings.enabled) return false
  return contextTokens > contextWindow - settings.reserveTokens
}

// Flat per-image char budget folded into the char→token heuristic. Image tokenization varies by provider
// and resolution, so a fixed stand-in is used instead of trying to compute it; it only needs to be in the
// right ballpark for the estimate.
const ESTIMATED_IMAGE_CHARS = 4800

function estimateTextAndImageContentChars(content: string | Array<{ type: string; text?: string }>): number {
  if (typeof content === 'string') {
    return content.length
  }

  let chars = 0
  for (const block of content) {
    if (block.type === 'text' && block.text) {
      chars += block.text.length
    } else if (block.type === 'image') {
      chars += ESTIMATED_IMAGE_CHARS
    }
  }
  return chars
}

/**
 * Rough token count for one message via the standard ~4-chars-per-token rule of thumb.
 *
 * Used only for messages with no provider usage (see {@link estimateContextTokens}); exactness is not the
 * goal, a safe ballpark is. Notable choices: assistant `thinking` blocks are NOT counted — they are
 * dropped before the next request and so do not occupy the outgoing context window — while tool-call
 * names and serialized arguments ARE counted, since they are sent. Images contribute the flat
 * {@link ESTIMATED_IMAGE_CHARS} budget.
 */
export function estimateTokens(message: AgentMessage): number {
  let chars = 0

  switch (message.role) {
    case 'user': {
      chars = estimateTextAndImageContentChars(
        (message as { content: string | Array<{ type: string; text?: string }> }).content
      )
      return Math.ceil(chars / 4)
    }
    case 'assistant': {
      const assistant = message as AssistantMessage
      for (const block of assistant.content) {
        if (block.type === 'text') {
          chars += block.text.length
        } else if (block.type === 'thinking') {
          continue
        } else if (block.type === 'toolCall') {
          chars += block.name.length + safeJsonStringify(block.arguments).length
        }
      }
      return Math.ceil(chars / 4)
    }
    case 'custom':
    case 'toolResult': {
      chars = estimateTextAndImageContentChars(message.content)
      return Math.ceil(chars / 4)
    }
    case 'compactionSummary': {
      chars = message.summary.length
      return Math.ceil(chars / 4)
    }
  }

  return 0
}
/**
 * Lists indices where the history may be split without orphaning a tool call.
 *
 * The hard rule: a `toolResult` is never a valid cut point. An assistant message can carry a tool call
 * whose result is the very next message, and providers reject a tool call with no matching result (or a
 * result with no call). Cutting just before a `toolResult` would keep the result while folding away its
 * call, so those positions are excluded; user/assistant/custom/summary boundaries are safe.
 */
function findValidCutPoints(entries: SessionTreeEntry[], startIndex: number, endIndex: number): number[] {
  const cutPoints: number[] = []
  for (let i = startIndex; i < endIndex; i++) {
    const entry = entries[i]
    switch (entry.type) {
      case 'message': {
        const role = entry.message.role
        switch (role) {
          case 'custom':
          case 'compactionSummary':
          case 'user':
          case 'assistant':
            cutPoints.push(i)
            break
          case 'toolResult':
            break
        }
        break
      }
      case 'thinking_level_change':
      case 'model_change':
      case 'active_tools_change':
      case 'compaction':
      case 'custom':
      case 'custom_message':
      case 'label':
      case 'session':
      case 'leaf':
        break
    }
    if (entry.type === 'custom_message') {
      cutPoints.push(i)
    }
  }
  return cutPoints
}

/**
 * Walks back from an entry to the user message (or injected custom message) that opened its turn.
 *
 * A "turn" begins at the user's message and runs through the assistant replies and tool exchanges it
 * triggered. When a cut lands in the middle of a turn, this finds that turn's start so the prefix before
 * the cut can be summarized separately (see split-turn handling in {@link findCutPoint}). Returns -1 when
 * no turn start exists in range.
 */
export function findTurnStartIndex(entries: SessionTreeEntry[], entryIndex: number, startIndex: number): number {
  for (let i = entryIndex; i >= startIndex; i--) {
    const entry = entries[i]
    if (entry.type === 'custom_message') {
      return i
    }
    if (entry.type === 'message') {
      const role = entry.message.role
      if (role === 'user') {
        return i
      }
    }
  }
  return -1
}

/** Cut point selected for compaction. */
export interface CutPointResult {
  /** Index of the first entry retained after compaction. */
  firstKeptEntryIndex: number
  /** Index of the turn-start entry when the cut splits a turn, otherwise -1. */
  turnStartIndex: number
  /** Whether the selected cut point splits an in-progress turn. */
  isSplitTurn: boolean
}

/**
 * Picks where to split history so roughly `keepRecentTokens` of the newest turns survive verbatim.
 *
 * Strategy, in order:
 *  1. Accumulate token cost from the newest entry backward. The first point where the running total
 *     reaches the budget marks how far back the "recent" window must extend.
 *  2. Snap that position forward to the nearest VALID cut (a user/assistant/custom/summary boundary, per
 *     {@link findValidCutPoints}), so the cut never lands mid tool-call/result pair.
 *  3. Snap backward over non-message markers (model_change, label, etc.) so the kept region starts on a
 *     real message or a prior compaction, never on a bookkeeping entry. Stops at a `compaction` or
 *     `message` boundary.
 *
 * Split-turn case: if the chosen start is not itself a user message, the cut fell in the middle of a turn
 * (e.g. between an assistant message and its tool result is impossible, but after several tool exchanges
 * is common). The turn's prefix is then summarized on its own so the surviving suffix still has its
 * opening context. With no valid cut points at all, it keeps everything from `startIndex` and reports no
 * split.
 */
export function findCutPoint(
  entries: SessionTreeEntry[],
  startIndex: number,
  endIndex: number,
  keepRecentTokens: number
): CutPointResult {
  const cutPoints = findValidCutPoints(entries, startIndex, endIndex)

  if (cutPoints.length === 0) {
    return { firstKeptEntryIndex: startIndex, turnStartIndex: -1, isSplitTurn: false }
  }
  let accumulatedTokens = 0
  let cutIndex = cutPoints[0]

  // Step 1+2: grow the kept window from the tail until it holds the recent-token budget, then take the
  // first valid cut at or after that depth. Only `message` entries carry tokens; markers are free.
  for (let i = endIndex - 1; i >= startIndex; i--) {
    const entry = entries[i]
    if (entry.type !== 'message') continue
    const messageTokens = estimateTokens(entry.message as AgentMessage)
    accumulatedTokens += messageTokens
    if (accumulatedTokens >= keepRecentTokens) {
      for (let c = 0; c < cutPoints.length; c++) {
        if (cutPoints[c] >= i) {
          cutIndex = cutPoints[c]
          break
        }
      }
      break
    }
  }
  // Step 3: pull the cut back past any leading non-message markers so the kept region opens on real
  // content (or a previous summary), not on a thinking_level_change / label / leaf entry.
  while (cutIndex > startIndex) {
    const prevEntry = entries[cutIndex - 1]
    if (prevEntry.type === 'compaction') {
      break
    }
    if (prevEntry.type === 'message') {
      break
    }
    cutIndex--
  }
  // A cut that starts exactly on a user message is a clean turn boundary — no prefix to rescue. Otherwise
  // the kept region starts mid-turn and the opening of that turn must be summarized separately.
  const cutEntry = entries[cutIndex]
  const isUserMessage = cutEntry.type === 'message' && cutEntry.message.role === 'user'
  const turnStartIndex = isUserMessage ? -1 : findTurnStartIndex(entries, cutIndex, startIndex)

  return {
    firstKeptEntryIndex: cutIndex,
    turnStartIndex,
    isSplitTurn: !isUserMessage && turnStartIndex !== -1
  }
}

/** Describes one summarization LLM call, handed to a {@link CompactionLlmCallRunner} for observation. */
export interface CompactionLlmCallContext {
  /** Whether this call summarizes the dropped history or just a split turn's prefix. */
  kind: 'history' | 'turn_prefix'
  maxTokens: number
  /** The prompt messages actually sent to the summarizer. */
  messages: Message[]
  previousSummary?: string
  /** The agent messages this summary is derived from, before serialization; used to record provenance. */
  sourceMessages: AgentMessage[]
  systemPrompt: string
}

/**
 * Hook that wraps each summarization call. The runner receives the call context and a `complete` thunk;
 * it may record telemetry, persist an llm_turn, etc., then must call `complete()` and return its result.
 * Keeping the LLM invocation behind a thunk lets the caller (compression.ts) bracket every summarizer
 * call with its own start/finish bookkeeping without this module knowing about the database.
 */
export type CompactionLlmCallRunner = (
  context: CompactionLlmCallContext,
  complete: () => Promise<AssistantMessage>
) => Promise<AssistantMessage>

/**
 * Runs the summarizer over the to-be-folded history and returns its text.
 *
 * When `previousSummary` is supplied the prompt switches to update mode — the model revises the existing
 * summary with the new messages instead of writing one from scratch, which is how iterative compaction
 * accumulates context across checkpoints. Aborted and errored completions are returned as typed
 * {@link CompactionError}s rather than thrown, so the caller can fall back (e.g. try the primary model,
 * then a deterministic excerpt) instead of losing the turn.
 */
export async function generateSummary(
  currentMessages: AgentMessage[],
  model: Model<any>,
  reserveTokens: number,
  options: SimpleStreamOptions = {},
  signal?: AbortSignal,
  customInstructions?: string,
  previousSummary?: string,
  thinkingLevel?: ThinkingLevel,
  callRunner?: CompactionLlmCallRunner
): Promise<Result<string, CompactionError>> {
  // Cap the summary output at 80% of the reserved headroom — the summary has to fit inside the freed
  // space alongside the next request, so it cannot consume the whole reserve. Clamped again by the
  // model's own max output when it declares one.
  const maxTokens = Math.min(
    Math.floor(0.8 * reserveTokens),
    model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY
  )
  const llmMessages = convertToLlm(currentMessages)
  const conversationText = serializeConversation(llmMessages)
  const promptText = buildCompactionHistoryUserPrompt({ conversationText, customInstructions, previousSummary })

  const summarizationMessages: Message[] = [
    {
      role: 'user' as const,
      content: [{ type: 'text' as const, text: promptText }],
      timestamp: Date.now()
    }
  ]

  const context: CompactionLlmCallContext = {
    kind: 'history',
    maxTokens,
    messages: summarizationMessages,
    previousSummary,
    sourceMessages: currentMessages,
    systemPrompt: SUMMARIZATION_SYSTEM_PROMPT
  }
  // `complete` is the bare LLM call; the runner (when present) wraps it with persistence/telemetry and is
  // responsible for invoking it. When absent, call it directly — this keeps the harness usable without
  // the database layer wired in (e.g. in tests).
  const complete = () =>
    generateBullXText(
      model,
      { systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: summarizationMessages },
      summarizationOptions(model, maxTokens, options, signal, thinkingLevel)
    )
  const response = callRunner ? await callRunner(context, complete) : await complete()
  if (response.stopReason === 'aborted') {
    return err(new CompactionError('aborted', response.errorMessage || 'Summarization aborted'))
  }
  if (response.stopReason === 'error') {
    return err(
      new CompactionError('summarization_failed', `Summarization failed: ${response.errorMessage || 'Unknown error'}`)
    )
  }

  const textContent = response.content
    .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
    .map(c => c.text)
    .join('\n')

  return ok(textContent)
}

/** Prepared inputs for a compaction run. */
export interface CompactionPreparation {
  /** Entry id where retained history starts. */
  firstKeptEntryId: string
  /** Messages summarized into the history summary. */
  messagesToSummarize: AgentMessage[]
  /** Prefix messages summarized separately when compaction splits a turn. */
  turnPrefixMessages: AgentMessage[]
  /** Whether compaction splits a turn. */
  isSplitTurn: boolean
  /** Estimated context tokens before compaction. */
  tokensBefore: number
  /** Previous compaction summary used for iterative updates. */
  previousSummary?: string
  /** File operations extracted from summarized history. */
  fileOps: FileOperations
  /** Settings used to prepare compaction. */
  settings: CompactionSettings
}

/**
 * Plans a compaction over a path: finds the boundary, gathers the messages to summarize, and detects a
 * split turn. Returns `undefined` (not an error) when there is nothing to do.
 *
 * No-op cases that return `undefined`: an empty path, or a path whose last entry is already a compaction
 * (the freshest possible state — re-compacting would summarize a single summary). Otherwise it scopes the
 * work to the region AFTER the previous compaction so already-folded history is never re-read, threads
 * that prior summary through as `previousSummary` for update-mode summarization, and asks
 * {@link findCutPoint} where to draw the line.
 */
export function prepareCompaction(
  pathEntries: SessionTreeEntry[],
  settings: CompactionSettings
): Result<CompactionPreparation | undefined, CompactionError> {
  if (pathEntries.length === 0 || pathEntries[pathEntries.length - 1].type === 'compaction') {
    return ok(undefined)
  }

  // Find the most recent prior compaction; everything before its kept-boundary is already summarized and
  // out of scope for this pass.
  let prevCompactionIndex = -1
  for (let i = pathEntries.length - 1; i >= 0; i--) {
    if (pathEntries[i].type === 'compaction') {
      prevCompactionIndex = i
      break
    }
  }

  let previousSummary: string | undefined
  let boundaryStart = 0
  if (prevCompactionIndex >= 0) {
    const prevCompaction = pathEntries[prevCompactionIndex] as CompactionEntry
    previousSummary = prevCompaction.summary
    // New work starts where the last compaction said it kept history from. If that id can't be located
    // (a repaired/edited tree), fall back to just after the compaction marker so the scope stays valid.
    const firstKeptEntryIndex = pathEntries.findIndex(entry => entry.id === prevCompaction.firstKeptEntryId)
    boundaryStart = firstKeptEntryIndex >= 0 ? firstKeptEntryIndex : prevCompactionIndex + 1
  }
  const boundaryEnd = pathEntries.length

  // tokensBefore measures the WHOLE projected context (so the saving is reported honestly), even though
  // only the post-boundary region is eligible to be folded.
  const tokensBefore = estimateContextTokens(buildSessionContext(pathEntries).messages).tokens

  const cutPoint = findCutPoint(pathEntries, boundaryStart, boundaryEnd, settings.keepRecentTokens)
  const firstKeptEntry = pathEntries[cutPoint.firstKeptEntryIndex]
  // The kept boundary must be addressable by id, because that id is persisted on the new compaction entry
  // and used to reconstruct the path later. A legacy entry without an id cannot be referenced and forces
  // a migration rather than a silent, unreplayable compaction.
  if (!firstKeptEntry?.id) {
    return err(new CompactionError('invalid_session', 'First kept entry has no UUID - session may need migration'))
  }
  const firstKeptEntryId = firstKeptEntry.id

  // On a split turn the main history stops at the TURN start (not the cut point), and the gap between the
  // turn start and the cut becomes the separately-summarized prefix. On a clean cut the two coincide and
  // there is no prefix.
  const historyEnd = cutPoint.isSplitTurn ? cutPoint.turnStartIndex : cutPoint.firstKeptEntryIndex
  const messagesToSummarize: AgentMessage[] = []
  for (let i = boundaryStart; i < historyEnd; i++) {
    const msg = getMessageFromEntryForCompaction(pathEntries[i])
    if (msg) messagesToSummarize.push(msg)
  }
  const turnPrefixMessages: AgentMessage[] = []
  if (cutPoint.isSplitTurn) {
    for (let i = cutPoint.turnStartIndex; i < cutPoint.firstKeptEntryIndex; i++) {
      const msg = getMessageFromEntryForCompaction(pathEntries[i])
      if (msg) turnPrefixMessages.push(msg)
    }
  }
  // File inventory must cover both the folded history AND the split-turn prefix, since both are being
  // removed from verbatim context and their touched files would otherwise be forgotten.
  const fileOps = extractFileOperations(messagesToSummarize, pathEntries, prevCompactionIndex)
  if (cutPoint.isSplitTurn) {
    for (const msg of turnPrefixMessages) {
      extractFileOpsFromMessage(msg, fileOps)
    }
  }

  return ok({
    firstKeptEntryId,
    messagesToSummarize,
    turnPrefixMessages,
    isSplitTurn: cutPoint.isSplitTurn,
    tokensBefore,
    previousSummary,
    fileOps,
    settings
  })
}

export { serializeConversation } from './utils'

/**
 * Turns a {@link CompactionPreparation} into the final summary payload to persist.
 *
 * On a split turn it summarizes the folded history and the orphaned turn-prefix in PARALLEL (two
 * independent LLM calls) and stitches them under a labeled divider, so the surviving suffix gets both its
 * long-range background and the immediate setup of its own turn. The file-operation tags are appended to
 * the summary text last, after either path, so they always ride along with the checkpoint.
 */
export async function compact(
  preparation: CompactionPreparation,
  model: Model<any>,
  options: SimpleStreamOptions = {},
  customInstructions?: string,
  signal?: AbortSignal,
  thinkingLevel?: ThinkingLevel,
  callRunner?: CompactionLlmCallRunner
): Promise<Result<CompactionResult, CompactionError>> {
  const {
    firstKeptEntryId,
    messagesToSummarize,
    turnPrefixMessages,
    isSplitTurn,
    tokensBefore,
    previousSummary,
    fileOps,
    settings
  } = preparation

  if (!firstKeptEntryId) {
    return err(new CompactionError('invalid_session', 'First kept entry has no UUID - session may need migration'))
  }

  let summary: string

  if (isSplitTurn && turnPrefixMessages.length > 0) {
    const [historyResult, turnPrefixResult] = await Promise.all([
      // When the split turn IS the very first content (nothing older to fold), skip the history call and
      // use a placeholder instead of paying for a summary of nothing.
      messagesToSummarize.length > 0
        ? generateSummary(
            messagesToSummarize,
            model,
            settings.reserveTokens,
            options,
            signal,
            customInstructions,
            previousSummary,
            thinkingLevel,
            callRunner
          )
        : Promise.resolve(ok<string, CompactionError>('No prior history.')),
      generateTurnPrefixSummary(
        turnPrefixMessages,
        model,
        settings.reserveTokens,
        options,
        signal,
        thinkingLevel,
        callRunner
      )
    ])
    if (!historyResult.ok) return err(historyResult.error)
    if (!turnPrefixResult.ok) return err(turnPrefixResult.error)
    summary = `${historyResult.value}\n\n---\n\n**Turn Context (split turn):**\n\n${turnPrefixResult.value}`
  } else {
    const summaryResult = await generateSummary(
      messagesToSummarize,
      model,
      settings.reserveTokens,
      options,
      signal,
      customInstructions,
      previousSummary,
      thinkingLevel,
      callRunner
    )
    if (!summaryResult.ok) return err(summaryResult.error)
    summary = summaryResult.value
  }

  // Append the read/modified file tags to the prose, and also stash them in `details` so the NEXT
  // compaction can carry this inventory forward (see extractFileOperations).
  const { readFiles, modifiedFiles } = computeFileLists(fileOps)
  summary += formatFileOperations(readFiles, modifiedFiles)

  return ok({
    summary,
    firstKeptEntryId,
    tokensBefore,
    details: { readFiles, modifiedFiles } as CompactionDetails
  })
}

/**
 * Builds the stream options for a summarization call. Enables reasoning only when the model supports it
 * AND a non-off level was asked for; otherwise the key is deleted so a model that rejects an explicit
 * `reasoning: 'off'` does not error. The caller's abort signal takes precedence over any on `options`.
 */
function summarizationOptions(
  model: Model<any>,
  maxTokens: number,
  options: SimpleStreamOptions,
  signal?: AbortSignal,
  thinkingLevel?: ThinkingLevel
): SimpleStreamOptions {
  const completionOptions: SimpleStreamOptions = {
    ...options,
    maxTokens,
    signal: signal ?? options.signal
  }
  const requestedReasoning = thinkingLevel ?? options.reasoning
  if (model.reasoning && requestedReasoning && requestedReasoning !== 'off') {
    completionOptions.reasoning = requestedReasoning
  } else {
    delete completionOptions.reasoning
  }
  return completionOptions
}

/**
 * Summarizes just the prefix of a turn that the cut split. Mirrors {@link generateSummary} but with a
 * tighter output budget (half the reserve, vs 80%) — a single turn's opening needs far less room than the
 * whole history summary, and the two run in parallel so they must share the reserved headroom.
 */
async function generateTurnPrefixSummary(
  messages: AgentMessage[],
  model: Model<any>,
  reserveTokens: number,
  options: SimpleStreamOptions = {},
  signal?: AbortSignal,
  thinkingLevel?: ThinkingLevel,
  callRunner?: CompactionLlmCallRunner
): Promise<Result<string, CompactionError>> {
  const maxTokens = Math.min(
    Math.floor(0.5 * reserveTokens),
    model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY
  )
  const llmMessages = convertToLlm(messages)
  const conversationText = serializeConversation(llmMessages)
  const promptText = buildTurnPrefixSummarizationUserPrompt(conversationText)
  const summarizationMessages: Message[] = [
    {
      role: 'user' as const,
      content: [{ type: 'text' as const, text: promptText }],
      timestamp: Date.now()
    }
  ]

  const context: CompactionLlmCallContext = {
    kind: 'turn_prefix',
    maxTokens,
    messages: summarizationMessages,
    sourceMessages: messages,
    systemPrompt: SUMMARIZATION_SYSTEM_PROMPT
  }
  const complete = () =>
    generateBullXText(
      model,
      { systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: summarizationMessages },
      summarizationOptions(model, maxTokens, options, signal, thinkingLevel)
    )
  const response = callRunner ? await callRunner(context, complete) : await complete()
  if (response.stopReason === 'aborted') {
    return err(new CompactionError('aborted', response.errorMessage || 'Turn prefix summarization aborted'))
  }
  if (response.stopReason === 'error') {
    return err(
      new CompactionError(
        'summarization_failed',
        `Turn prefix summarization failed: ${response.errorMessage || 'Unknown error'}`
      )
    )
  }

  return ok(
    response.content
      .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
      .map(c => c.text)
      .join('\n')
  )
}
