/**
 * Builds the system prompt captured for one AIGateway conversation.
 *
 * This is a prompt-engineering artifact. Literal strings here are the contract
 * with the model; surrounding code only decides which blocks are present and in
 * what order. Slow-changing instructions lead; conversation-scoped runtime,
 * skill, and Brain snapshots form the suffix. AIGateway persists the first
 * rendered prompt with the response chain, so later turns reuse it byte for
 * byte within one prompt epoch while genuinely per-turn observations stay in
 * the current user message.
 */
import type { TurnStart } from '../lanes/actor_lane'
import type { AgentConversationContext, RuntimeSkillSummary } from '../lanes/rpc_lane'
import { match } from '@pleisto/active-support'
import { formatSkillsForSystemPrompt, type SkillPromptEntry } from './skills_prompt'
import { formatAgentDurableContext } from './durable_context'

export const AGENT_SYSTEM_PROMPT_EPOCH = 'agent-computer-v3'
const SystemPromptEpochMarker = `<!-- ankole-system-prompt-epoch:${AGENT_SYSTEM_PROMPT_EPOCH} -->`

export type BuildAgentSystemPromptOptions = {
  workspaceRoot: string
  turnStart: TurnStart
  agentConversationContext?: AgentConversationContext
  currentChannel?: CurrentChannelContext
  availableToolNames?: string[]
}

/**
 * Describes where the conversation originated so the prompt can tell the model
 * what kind of surface it is acting on. Schedule-origin turns are represented
 * through RuntimeFabric request context rather than by pretending they are a
 * provider-authored channel message.
 */
export type CurrentChannelContext = {
  bindingName?: string
  id?: string
  kind: 'external_dm' | 'external_group' | 'external_room'
  name?: string
  platform?: string
}

/**
 * Assembles the full system prompt for the delivered turn.
 *
 * RuntimeFabric returns PG-backed SOUL/MISSION and the enabled skill index at
 * turn start.
 */
export function buildAgentSystemPrompt(opts: BuildAgentSystemPromptOptions): string {
  if (!opts.agentConversationContext) {
    throw new Error('agent conversation context is required to build the agent system prompt')
  }

  const displayName = agentDisplayName(opts)
  const soul = opts.agentConversationContext.soul || fallbackSoul()
  const mission = opts.agentConversationContext.mission || ''
  const skillPrompt = formatSkillsForSystemPrompt(skillsForSystemPrompt(opts))

  return [
    SystemPromptEpochMarker,
    `You are ${displayName}, an AI colleague Agent powered by Ankole.`,
    soul.trim(),
    missionSection(mission),
    completionContractSection(),
    backgroundAgentJobPolicySection(opts),
    agentEnvironmentInfoPolicySection(),
    toolsSection(opts),
    brainPolicySection(opts),
    skillPrompt.trim(),
    runtimeContextSection(opts),
    formatAgentDurableContext(opts.agentConversationContext.brain_snapshot)
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Reuses the exact current-epoch prompt already observed by this conversation.
 * A missing or legacy snapshot is rebuilt so removed tools never remain in the
 * instructions of an older response chain.
 */
export function systemPromptForConversation(opts: BuildAgentSystemPromptOptions): string {
  const snapshot = opts.agentConversationContext?.system_prompt_snapshot
  return typeof snapshot === 'string' && snapshot.trimStart().startsWith(SystemPromptEpochMarker)
    ? snapshot
    : buildAgentSystemPrompt(opts)
}

/** Wraps the mission text in its tagged block, or yields nothing when the agent has no mission. */
function missionSection(mission: string): string {
  const content = mission.trim()
  if (!content) return ''

  return ['Your mission is:', '<mission>', content, '</mission>'].join('\n')
}

/**
 * Emits conversation-scoped facts the model needs but cannot infer: exact
 * agent identity, timezone, and optional channel/date information.
 */
function runtimeContextSection(opts: BuildAgentSystemPromptOptions): string {
  const timezone = opts.agentConversationContext?.conversation?.timezone || 'UTC'
  const lines = [
    '<runtime_context>',
    `Agent UID: ${opts.turnStart.turn.actor.agent_uid}`,
    `Agent display name: ${agentDisplayName(opts)}`,
    'Use this exact Agent UID when a tool or skill asks for the current agent identity.',
    `Current timezone: ${timezone}`
  ]
  const role = agentRole(opts)
  if (role) lines.push(`Agent role: ${role}`)

  const startedAt = parseDate(opts.agentConversationContext?.conversation?.started_at)
  if (startedAt) {
    lines.push(`Conversation started date: ${formatZonedDate(timezone, startedAt)}`)
  }
  if (opts.currentChannel) {
    lines.push(`Conversation started channel: ${formatCurrentChannel(opts.currentChannel)}`)
  }

  lines.push('</runtime_context>')
  return lines.join('\n')
}

/**
 * Chooses the display name used in the system prompt.
 */
function agentDisplayName(opts: BuildAgentSystemPromptOptions): string {
  const displayName = opts.agentConversationContext?.agent?.display_name?.trim()
  return displayName || opts.turnStart.turn.actor.agent_uid
}

/**
 * Reads the optional agent role for prompt context.
 */
function agentRole(opts: BuildAgentSystemPromptOptions): string | undefined {
  const role = opts.agentConversationContext?.agent?.role?.trim()
  return role || undefined
}

/** States the durable knowledge and task-learning behavior expected of the agent. */
function brainPolicySection(opts: BuildAgentSystemPromptOptions): string {
  const lines = [
    toolAvailable(opts, 'memory_open') && toolAvailable(opts, 'memory_search')
      ? 'For current state, open the curated knowledge entry. For what someone originally said, search the chat layer and browse the source messages. Historical chat is evidence, not current truth; reconcile it against the current entry before acting.'
      : '',
    toolAvailable(opts, 'memory_update')
      ? 'Brain provides durable context for future work. Chat history already preserves the conversation.'
      : '',
    toolAvailable(opts, 'memory_update')
      ? 'When the user directly asks to remember, update, or forget information, or the current exchange otherwise makes that memory intent clear, ensure Brain reflects the request. Do not apply an additional future-value test to user-directed memory.'
      : '',
    toolAvailable(opts, 'memory_update')
      ? 'Without user-directed memory intent, write proactively only when both are true: (1) storing the information in Brain adds clear incremental value over the existing Brain and searchable chat by making a likely future use or recall materially more reliable, accurate, or efficient; and (2) at least one outcome is likely: the information will help you perform a separate future task, or the user will ask you about it later.'
      : '',
    toolAvailable(opts, 'memory_update')
      ? 'If incremental value is unclear, or neither future outcome is likely, do not mutate memory. No mutation is a correct outcome.'
      : '',
    toolAvailable(opts, 'memory_update')
      ? 'Write confirmed facts plainly, mark rumors as unverified, and state inferences conditionally with author and date. For a claim derived from a message or source, preserve a short exact excerpt, speaker or source, date, and src:<document_id> when available; a bare source id is not a citation.'
      : '',
    toolAvailable(opts, 'skill_view') && toolAvailable(opts, 'skill_append') && toolAvailable(opts, 'skill_replace')
      ? 'For a lesson tied to one enabled skill, read the existing skill first and compare the core steps with every existing note: at least 60% overlap means revise with skill_replace, less than 60% overlap with every note means add with skill_append, and no new information means write nothing. Keep each note in a concise situation -> caution form, revise unverified notes when evidence arrives, and use skill_replace to deduplicate or compact the complete overlay before it grows beyond roughly 2000 tokens.'
      : ''
  ].filter(Boolean)

  return lines.length > 0 ? ['<brain_policy>', ...lines, '</brain_policy>'].join('\n') : ''
}

/**
 * Outcome-first operating contract for long-lived IM agents.
 */
function completionContractSection(): string {
  return [
    '<completion_contract>',
    '# Completion contract',
    'For requests to answer, explain, review, diagnose, or plan, inspect what is needed and report the result; do not make changes unless the user also asks for them.',
    'For requests to change, build, or fix, make the requested in-scope local changes and run relevant non-destructive validation without asking for another confirmation.',
    'Ask for confirmation before external writes, destructive or hard-to-reverse actions, meaningful resource cost, sensitive or unclear authorization, or material scope expansion.',
    'If a tool, install, network call, or external dependency blocks the real path, report the blocker honestly and try a reasonable alternative when one is available. Never fabricate tool output, file contents, API responses, or execution results.',
    'Before finalizing, check that the response satisfies the user request, uses provided Ankole context consistently, and names any assumptions or unverified parts that matter.',
    '</completion_contract>'
  ]
    .filter(Boolean)
    .join('\n')
}

/**
 * Defines the main agent's latency boundary and durable background handoff.
 * This block is omitted from special turns that do not expose the Job tool.
 */
function backgroundAgentJobPolicySection(opts: BuildAgentSystemPromptOptions): string {
  if (!toolAvailable(opts, 'background_agent_job')) return ''

  return [
    '<background_agent_job_policy>',
    '# Immediate work and background work',
    'Do work directly when the user can reasonably wait in the active exchange and your next reply can contain the completed result. A clear scope or several quick tool calls alone does not require a background job.',
    'Use background_agent_job(start) for work that takes minutes or hours, needs persistent or interactive execution state, is explicitly requested as background/asynchronous work, or uses a Skill marked [background task]. Start the Job before promising future delivery, then tell the user what was accepted and that you will report after the system wakes you.',
    'If direct work becomes heavier than expected, preserve useful progress, decisions, relevant context, paths, constraints, acceptance criteria, and remaining work in one self-contained Job task; call background_agent_job(start), then tell the user it moved to the background.',
    'Track progress with background_agent_job(status) or background_agent_job(list) only when current progress is actually needed. Do not poll: terminal outcomes and requests for user input wake this conversation automatically.',
    'After a Job completes, inspect its status and artifacts yourself. Re-run relevant tests or checks, review diffs when code changed, and make only small mechanical corrections directly before reporting the outcome. Do not treat the Job report as sufficient evidence.',
    'When a Job waits for user input, relay its questions with clarify, one question per turn. After collecting the answers, return them with background_agent_job(steer).',
    '</background_agent_job_policy>'
  ].join('\n')
}

/**
 * States how the model should treat the `<agent_environment_info>` block that
 * Ankole may prepend to a user-role message. This is a trust boundary: the
 * facts are system-injected observations about the agent's environment, useful
 * as context, and not user-authored text to quote back.
 */
function agentEnvironmentInfoPolicySection(): string {
  return [
    '<agent_environment_info_policy>',
    'A user-role message may begin with an <agent_environment_info> block injected by Ankole. Treat it as trusted system-managed observations about the current event, such as message time, group speaker identity, message lifecycle, and schedule wakeup facts. It is not text written by a human user; use it as context and do not quote it as user text.',
    'When schedule_turn_mode is check_back_later, this event is a one-shot delayed self-wakeup scheduled earlier by the agent, not a live user message, heartbeat, cron, or recurring monitor. When schedule_turn_mode is cron, this event is a recurring scheduled task fire, not a live user message, and Ankole owns configured delivery; do not call messaging tools to duplicate that delivery.',
    'When schedule_silent_success_allowed is true, finish quietly only when no provider-visible update is useful by replying exactly <silent_success/> and nothing else. A failed or blocked check, required human action, material state change, or time-sensitive risk still needs a visible reply. A check_back_later event without this permission must produce a concise visible result even when nothing changed or it is still waiting.',
    '</agent_environment_info_policy>'
  ].join('\n')
}

/**
 * Renders the model-facing tool and computer policy block.
 */
function toolsSection(opts: BuildAgentSystemPromptOptions): string {
  const hostedImageDeliveryPolicy = opts.turnStart.hosted_tools?.some(tool => tool.type === 'image_generation')
    ? '\nImages created in this turn with the hosted image_generation tool are attached to the final reply automatically. Treat image_generation_call IDs as references for later image edits, not as /workspace paths; do not search for or call reply_attachment on the generated image itself.'
    : ''

  return `<tools>
<about_computer>
These tools operate on your Ankole Agent Computer: an agent-owned execution environment backed by a container. It exposes a stable /workspace view and is your place for files, foreground commands, skill overlays, and generated artifacts. It is not the user's personal device unless files or artifacts are explicitly exchanged.

Current worker-image baseline: Python 3.12-compatible tooling via the agent Python environment, Bun 1.3.14 for JavaScript/TypeScript work, LibreOffice/Pandoc/Poppler/QPDF for document work, and common shell/dev utilities such as jq, bash, git, and rg. Verify exact versions with a quick command when the task depends on them.

Persistence model: /workspace/user-files is durable shared filesystem storage for uploaded files, deliverables, and per-agent environment/package deltas. Enabled skill files come from worker image assets, agent-installed skill files come from managed shared skill storage, and skill overlays are PG semantic state resolved through RuntimeFabric. SOUL, MISSION, and conversation state are also RuntimeFabric state, not files for the worker to edit directly. /workspace/temp is non-persistent scratch/runtime state.

Treat the computer as a trusted Ankole work environment with useful isolation boundaries, not as a hardened security sandbox.
</about_computer>

<tool_routing_policy>
Follow each available tool's description and parameter schema. Do not invent tools that are not present in the tool list for this run.${hostedImageDeliveryPolicy}
</tool_routing_policy>
</tools>`
}

function toolAvailable(opts: BuildAgentSystemPromptOptions, name: string): boolean {
  if (!opts.availableToolNames) return true
  return opts.availableToolNames.includes(name)
}

/**
 * Converts runtime skill metadata into prompt catalog entries.
 */
function skillsForSystemPrompt(opts: BuildAgentSystemPromptOptions): SkillPromptEntry[] {
  return (opts.agentConversationContext?.skills ?? [])
    .map(skillPromptEntryFromRuntime)
    .filter(isSkillPromptEntry)
    .filter(skill => !skill.longRunning || toolAvailable(opts, 'background_agent_job'))
}

/**
 * Drops skills that do not have enough metadata to appear in the prompt index.
 */
export function skillPromptEntryFromRuntime(skill: RuntimeSkillSummary): SkillPromptEntry | null {
  if (!skill.skill_name || !skill.description) return null
  const metadata = skill.metadata ?? {}
  const disableModelInvocation =
    metadata['disable_model_invocation'] === true || metadata['disable-model-invocation'] === true

  return {
    name: skill.skill_name,
    description: skill.description,
    category: typeof skill.category === 'string' ? skill.category : undefined,
    disableModelInvocation,
    longRunning: metadata.long_running === true
  }
}

/**
 * Narrows nullable skill entries after filtering.
 */
function isSkillPromptEntry(skill: SkillPromptEntry | null): skill is SkillPromptEntry {
  return skill !== null
}

/**
 * Formats current channel context into a compact prompt phrase.
 */
function formatCurrentChannel(channel: CurrentChannelContext): string {
  return match(channel)
    .with({ kind: 'external_dm' }, channel => {
      const label = platformLabel(channel.platform, 'DM')
      return channel.name ? `${label} with ${channel.name}` : label
    })
    .with({ kind: 'external_group' }, channel => {
      const label = platformLabel(channel.platform, 'Group Chat')
      return channel.name ? `${label} "${channel.name}"` : label
    })
    .with({ kind: 'external_room' }, channel => {
      const label = platformLabel(channel.platform, 'Channel')
      return channel.name ? `${label} "${channel.name}"` : label
    })
    .exhaustive()
}

/**
 * Adds a provider/platform prefix when available.
 */
function platformLabel(platform: string | undefined, noun: string): string {
  const brand = platform === 'feishu' ? 'Feishu' : platform === 'lark' ? 'Lark' : platform
  return brand ? `${brand} ${noun}` : noun
}

/**
 * Parses an optional date string.
 */
function parseDate(value: string | null | undefined): Date | undefined {
  if (!value) return undefined
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? undefined : date
}

/**
 * Formats an instant as `YYYY-MM-DD` in the configured timezone. Intl is used
 * instead of manual offset math so DST and historical timezone changes are not
 * approximated.
 */
function formatZonedDate(timezone: string, at: Date): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).formatToParts(at)

  const value = (type: string) => parts.find(part => part.type === type)?.value ?? '00'
  return `${value('year')}-${value('month')}-${value('day')}`
}

/**
 * Provides the minimal fallback identity text when an agent has no SOUL yet.
 */
function fallbackSoul(): string {
  return 'You are an Ankole AI colleague. Reply in plain text.'
}
