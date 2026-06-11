/**
 * Extra summarization focus appended to the base compaction prompt: a brief
 * chronological `<analysis>` scratchpad, plus verbatim identifier preservation
 * so the post-compaction turn resumes without drift.
 */
export const COMPACTION_FOCUS_INSTRUCTIONS =
  "First, in an <analysis> block, walk the conversation chronologically and note each step's intent, decisions, and any errors and their fixes (this block is scratch work and will be discarded). Then write the summary. Preserve verbatim — never paraphrase — file paths, function and identifier names, error messages, command lines, and IDs/UUIDs; when the latest task is unfinished, quote its exact instruction so work resumes without drift."

export const SUMMARIZATION_SYSTEM_PROMPT = `You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.`

export const SUMMARIZATION_PROMPT = `The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use as reference background.

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

export const UPDATE_SUMMARIZATION_PROMPT = `The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
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

export const TURN_PREFIX_SUMMARIZATION_PROMPT = `This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix.`

export function buildCompactionHistoryUserPrompt(input: {
  conversationText: string
  customInstructions?: string
  previousSummary?: string
}): string {
  const basePrompt = withCompactionFocus(
    input.previousSummary ? UPDATE_SUMMARIZATION_PROMPT : SUMMARIZATION_PROMPT,
    input.customInstructions
  )
  const sections = [`<conversation>\n${input.conversationText}\n</conversation>`]
  if (input.previousSummary) sections.push(`<previous-summary>\n${input.previousSummary}\n</previous-summary>`)
  sections.push(basePrompt)
  return sections.join('\n\n')
}

export function buildTurnPrefixSummarizationUserPrompt(conversationText: string): string {
  return `<conversation>\n${conversationText}\n</conversation>\n\n${TURN_PREFIX_SUMMARIZATION_PROMPT}`
}

function withCompactionFocus(basePrompt: string, customInstructions?: string): string {
  return customInstructions ? `${basePrompt}\n\nAdditional focus: ${customInstructions}` : basePrompt
}
