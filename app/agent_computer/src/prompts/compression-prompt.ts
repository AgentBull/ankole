/**
 * Prompts that drive history compaction: when a conversation grows past the model's
 * context budget, the harness asks an LLM to summarize older turns into a compact
 * previous-chat-history replacement that later turns read as background.
 *
 * The hard constraint these prompts impose is that a summary is *reference state*,
 * not a command to resume old work — the latest user message after the compressed
 * history decides what happens next, and reverse signals (stop/undo/never mind)
 * must mark stale work cancelled rather than carry it forward. The rigid section
 * format and the "preserve verbatim" rules exist so identifiers, paths, and
 * unfinished instructions survive the lossy summarization without drift.
 */

/**
 * Extra summarization focus appended to the base compaction prompt: a brief
 * chronological `<analysis>` scratchpad, plus verbatim identifier preservation
 * so the post-compaction turn resumes without drift.
 */
export const COMPACTION_FOCUS_INSTRUCTIONS =
  "First, in an <analysis> block, walk the conversation chronologically and note each step's intent, decisions, and any errors and their fixes (this block is scratch work and will be discarded). Then write the summary. Preserve verbatim — never paraphrase — file paths, function and identifier names, error messages, command lines, and IDs/UUIDs; when the latest task is unfinished, quote its exact instruction so work resumes without drift."

/**
 * System prompt for the summarizer model. The explicit "do NOT continue the
 * conversation / do NOT answer questions" guard exists because the summarizer is
 * fed a real transcript that often ends mid-task; without it the model tends to
 * keep working instead of only emitting the compressed history replacement.
 */
export const SUMMARIZATION_SYSTEM_PROMPT = `You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.`

/**
 * First-time summarization prompt: used when there is no prior compressed history to build
 * on. Defines the exact section layout the downstream consumer parses and reiterates
 * that the summary is background, not a standing instruction to resume.
 */
export const SUMMARIZATION_PROMPT = `The messages above are a conversation to summarize. Create a structured compressed previous chat history summary that another LLM will use as reference background.

The summary is not an instruction to continue old work by itself. The latest user message after the summary decides what to do now. If later messages include reverse signals such as stop, undo, rollback, never mind, just verify, or a topic change, mark the stale work as cancelled or superseded instead of preserving it as active.

Use this EXACT format:

## Active Task
[The current task, or "(none)" if no task remains active.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Completed Actions
- [x] [Completed tasks/changes]
- [Or "(none)" if no meaningful actions were completed]

## Active State
- [Current files, processes, tools, data, environment, or UI state needed to resume]
- [Or "(none)" if not applicable]

## In Progress
- [ ] [Current work]
- [Or "(none)" if no work is in progress]

## Blocked
- [Issues preventing progress, if any]
- [Or "(none)" if not blocked]

## Key Decisions
- **[Decision]**: [Brief rationale]
- [Or "(none)" if none were made]

## Resolved Questions
- [Questions that were answered or choices that were settled]
- [Or "(none)" if none]

## Pending User Asks
- [Explicit requests from the user that still need response/action]
- [Or "(none)" if none]

## Remaining Work
1. [What remains to complete the active task]
2. [Or "(none)" if nothing remains]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.`

/**
 * Incremental summarization prompt: used when compressed history already exists and only
 * the newer messages need folding in. Re-summarizing the whole history every time
 * would be wasteful and risks dropping detail, so this variant preserves the prior
 * summary and merges deltas (advancing the progress sections, dropping resolved
 * blockers) using the same fixed format as the first-time prompt.
 */
export const UPDATE_SUMMARIZATION_PROMPT = `The messages above are NEW conversation messages to incorporate into the existing compressed previous chat history provided in <previous_chat_history> tags.

Update the existing structured compressed previous chat history with new information. RULES:
- PRESERVE all existing information from the previous compressed history
- ADD new progress, decisions, and context from the new messages
- UPDATE "Completed Actions", "In Progress", and "Remaining Work" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it
- If the new messages include reverse signals such as stop, undo, rollback, never mind, just verify, or a topic change, mark stale work as cancelled or superseded instead of preserving it as active

Use this EXACT format:

## Active Task
[Preserve or update the current task, or "(none)" if no task remains active.]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Completed Actions
- [x] [Include previously done items AND newly completed items]
- [Or "(none)" if no meaningful actions were completed]

## Active State
- [Preserve/update current files, processes, tools, data, environment, or UI state]
- [Or "(none)" if not applicable]

## In Progress
- [ ] [Current work - update based on progress]
- [Or "(none)" if no work is in progress]

## Blocked
- [Current blockers - remove if resolved]
- [Or "(none)" if not blocked]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)
- [Or "(none)" if none were made]

## Resolved Questions
- [Preserve/add questions that were answered or choices that were settled]
- [Or "(none)" if none]

## Pending User Asks
- [Explicit requests from the user that still need response/action]
- [Or "(none)" if none]

## Remaining Work
1. [Update based on current state]
2. [Or "(none)" if nothing remains]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.`

/**
 * Summarizes the *prefix* of a single oversized turn whose recent tail (the suffix)
 * is kept verbatim. This is a finer-grained compaction than the whole-history one
 * above: it triggers when one turn alone is too big to retain, so only its early
 * part is summarized for context while the latest work stays intact. The output is
 * lighter (three sections) because its only job is to make the kept suffix readable.
 */
export const TURN_PREFIX_SUMMARIZATION_PROMPT = `This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix.`

/**
 * Assembles the user turn for whole-history compaction.
 *
 * Picks the update prompt when `previousChatHistory` is supplied and the first-time
 * prompt otherwise, then lays out the transcript, the prior compressed history (if any), and
 * the instructions in that order. The instructions are placed *last*, after the
 * data, so the model reads the material before the formatting rules — a common
 * recency trick that improves adherence to the required section layout.
 */
export function buildCompactionHistoryUserPrompt(input: {
  conversationText: string
  customInstructions?: string
  previousChatHistory?: string
}): string {
  const basePrompt = withCompactionFocus(
    input.previousChatHistory ? UPDATE_SUMMARIZATION_PROMPT : SUMMARIZATION_PROMPT,
    input.customInstructions
  )
  const sections = [`<conversation>\n${input.conversationText}\n</conversation>`]
  if (input.previousChatHistory) {
    sections.push(`<previous_chat_history>\n${input.previousChatHistory}\n</previous_chat_history>`)
  }
  sections.push(basePrompt)
  return sections.join('\n\n')
}

/** Assembles the user turn for the single-turn prefix summarization variant. */
export function buildTurnPrefixSummarizationUserPrompt(conversationText: string): string {
  return `<conversation>\n${conversationText}\n</conversation>\n\n${TURN_PREFIX_SUMMARIZATION_PROMPT}`
}

/** Appends caller-supplied focus (e.g. {@link COMPACTION_FOCUS_INSTRUCTIONS}) to the base prompt, when present. */
function withCompactionFocus(basePrompt: string, customInstructions?: string): string {
  return customInstructions ? `${basePrompt}\n\nAdditional focus: ${customInstructions}` : basePrompt
}
