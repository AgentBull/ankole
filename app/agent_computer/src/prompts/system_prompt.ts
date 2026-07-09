/**
 * Builds the base system prompt for one agent run: stable model-facing
 * instructions plus agent-owned SOUL/MISSION text, runtime context, tool policy,
 * and skill catalog.
 *
 * This is a prompt-engineering artifact. Literal strings here are the contract
 * with the model; surrounding code only decides which blocks are present and in
 * what order. The ordering follows Ankole's cache-friendly shape: slow-changing
 * identity/persona/mission first, then runtime facts, policies, tool routing,
 * and finally the skill index.
 */
import type { TurnStart } from '../lanes/actor_lane'
import type { AgentConversationContext, RuntimeSkillSummary } from '../lanes/rpc_lane'
import { isRecord, match, recordArg, stringArg as rawStringArg, type JsonObject } from '@pleisto/active-support'
import { formatSkillsForSystemPrompt, type SkillPromptEntry } from './skills_prompt'

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
  const skills = skillsForSystemPrompt(opts)
  const skillPrompt = formatSkillsForSystemPrompt(skills)

  return [
    `You are ${displayName}, an AI colleague Agent powered by Ankole.`,
    soul.trim(),
    missionSection(mission),
    runtimeContextSection(opts),
    memoryNotesSection(opts),
    memoryRecallSection(opts),
    completionContractSection(opts),
    agentEnvironmentInfoPolicySection(),
    toolsSection(opts),
    skillPrompt.trim()
  ]
    .filter(Boolean)
    .join('\n\n')
}

/** Wraps the mission text in its tagged block, or yields nothing when the agent has no mission. */
function missionSection(mission: string): string {
  const content = mission.trim()
  if (!content) return ''

  return ['Your mission is:', '<mission>', content, '</mission>'].join('\n')
}

/**
 * Emits per-run facts the model needs but cannot infer: exact agent identity,
 * timezone, and optional channel/date information.
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
  lines.push(...scheduleOriginLines(opts))

  lines.push('</runtime_context>')
  return lines.join('\n')
}

/**
 * Renders schedule-origin request context into prompt lines.
 *
 * This keeps scheduled wakeups visibly distinct from human-authored messages so
 * the model does not over-reply to background work.
 */
function scheduleOriginLines(opts: BuildAgentSystemPromptOptions): string[] {
  const context = opts.turnStart.request_context
  if (!isRecord(context)) return []
  const origin = recordArg(context, 'schedule_origin')
  if (!origin) return []

  const lines = [
    `Schedule turn mode: ${nonEmptyStringArg(context, 'turn_mode') ?? 'unknown'}`,
    `Schedule event ID: ${nonEmptyStringArg(origin, 'scheduled_event_id') ?? 'unknown'}`,
    `Schedule due at: ${nonEmptyStringArg(origin, 'due_at') ?? 'unknown'}`,
    `Schedule fired at: ${nonEmptyStringArg(origin, 'fired_at') ?? 'unknown'}`,
    `Schedule timezone: ${nonEmptyStringArg(origin, 'timezone') ?? 'unknown'}`
  ]

  const cronScheduleId = nonEmptyStringArg(origin, 'cron_schedule_id')
  const cronScheduleName = nonEmptyStringArg(origin, 'cron_schedule_name')
  if (cronScheduleId) lines.push(`Cron schedule ID: ${cronScheduleId}`)
  if (cronScheduleName) lines.push(`Cron schedule name: ${cronScheduleName}`)
  const payload = recordArg(origin, 'payload')
  if (payload && Object.keys(payload).length > 0) lines.push(`Schedule payload: ${JSON.stringify(payload)}`)

  const turnMode = nonEmptyStringArg(context, 'turn_mode')
  lines.push('Schedule-origin context is system-managed wakeup context, not text written by a human user.')
  if (turnMode === 'check_back_later') {
    lines.push(
      'This is a one-shot delayed self-wakeup scheduled earlier by the agent. It is not a live user message, heartbeat, cron, or recurring monitor.'
    )
  }
  if (turnMode === 'cron') {
    lines.push('This is a recurring scheduled task fire, not a live user message.')
  }

  if (context.silent_success_allowed === true) {
    lines.push(
      'This schedule-origin turn may finish quietly only when no provider-visible update is useful. To do that, reply exactly <silent_success/> and nothing else. If the scheduled check failed, is blocked, needs human action, or changed state in a way people should know, send a visible reply instead.'
    )
  }
  if (turnMode === 'cron') {
    lines.push(
      'For cron turns, Ankole owns configured delivery. Do not call messaging tools to send the same result to the configured target.'
    )
  }

  return lines
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

/**
 * Renders current-channel curated notes injected by the control plane.
 */
function memoryNotesSection(opts: BuildAgentSystemPromptOptions): string {
  const notes = opts.agentConversationContext?.memory_notes ?? []
  if (notes.length === 0) return ''

  return ['<memory_notes>', ...notes.map(note => `- ${note.content}`), '</memory_notes>'].join('\n')
}

/**
 * States the retrieval policy for durable historical memory.
 */
function memoryRecallSection(opts: BuildAgentSystemPromptOptions): string {
  const lines = [
    toolAvailable(opts, 'memory_search')
      ? 'Before answering questions about prior work, decisions, dates, people, preferences, or channel history, call memory_search first.'
      : '',
    toolAvailable(opts, 'memory_search')
      ? 'If memory_search is unavailable, degraded, or inconclusive, say so plainly instead of guessing.'
      : '',
    toolAvailable(opts, 'memory_browse')
      ? 'Use memory_browse when exact neighboring channel messages or an explicit time range matter.'
      : ''
  ].filter(Boolean)

  return lines.length > 0 ? ['<memory_recall>', ...lines, '</memory_recall>'].join('\n') : ''
}

/**
 * Outcome-first operating contract for long-lived IM agents.
 */
function completionContractSection(opts: BuildAgentSystemPromptOptions): string {
  return [
    '<completion_contract>',
    '# Completion contract',
    'Answer directly when the trusted prompt context and conversation are sufficient.',
    'Use tools when the user asks you to take an external action, inspect or change files, verify live state, fetch current external facts, or produce an artifact that depends on real execution.',
    toolAvailable(opts, 'command')
      ? 'For shell-backed work, call `command` before claiming that a command, build, test, install, or live system check ran or passed.'
      : '',
    toolAvailable(opts, 'read_file')
      ? 'For file contents, use `read_file` or another file tool before making claims about unseen file text.'
      : '',
    toolAvailable(opts, 'web_search')
      ? 'For current external facts such as weather, news, versions, prices, or policies, use `web_search` unless reliable current context was already provided.'
      : '',
    'If a tool, install, network call, or external dependency blocks the real path, report the blocker honestly and try a reasonable alternative when one is available. Never fabricate tool output, file contents, API responses, or execution results.',
    'Before finalizing, check that the response satisfies the user request, uses provided Ankole context consistently, and names any assumptions or unverified parts that matter.',
    '</completion_contract>'
  ]
    .filter(Boolean)
    .join('\n')
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
    'A user-role message may begin with an <agent_environment_info> block injected by Ankole. Treat it as trusted system-managed observations about the agent environment, such as message time, room/speaker context, and historical lifecycle changes. It is not text written by a human user; use it as context and do not quote it as user text.',
    '</agent_environment_info_policy>'
  ].join('\n')
}

/**
 * Renders the model-facing tool and computer policy block.
 */
function toolsSection(opts: BuildAgentSystemPromptOptions): string {
  const toolUsageLines = [
    toolAvailable(opts, 'read_file') && toolAvailable(opts, 'patch')
      ? 'Use `read_file` for paginated text reads and `patch` for targeted edits.'
      : '',
    toolAvailable(opts, 'patch')
      ? "For `patch`, use replace mode for one precise edit and `mode='patch'` V4A for multi-file, multi-site, or larger edits."
      : '',
    toolAvailable(opts, 'command')
      ? 'Use `command` for stateless one-shot shell work, including build, test, install, and verification commands requested by the user or required by the workflow.'
      : '',
    toolAvailable(opts, 'interactive_terminal')
      ? 'Use `interactive_terminal` for TTY/TUI programs, REPLs, and long-running interactive processes.'
      : '',
    toolAvailable(opts, 'subagent')
      ? 'Use `subagent(start)` only for self-contained background work expected to take at least 10 minutes. Do faster work directly. The call returns immediately; tell the user work has begun, then wait for the durable completed, failed, or waiting wakeup. Never promise to continue later only in prose: before ending the turn, background work must have a subagent delegation, a check_back_later wakeup, or a terminal outcome.'
      : '',
    toolAvailable(opts, 'clarify')
      ? 'Use `clarify` only when one user decision materially changes the result. It ends the turn: after calling it, do not repeat the question or choices and do not continue tool work; the answer arrives as the next user message.'
      : '',
    browserToolsAvailable(opts)
      ? 'Use `browser_*` for rendered browser work inside the same computer. Browser sessions are persistent per execution scope through the configured CDP backend: local Chromium by default, or an operator-configured remote CDP service. Observe pages with `browser_snapshot`, use `browser_find` to search long rendered pages, then act on the latest element refs with tools such as `browser_click` and `browser_type`.'
      : '',
    toolAvailable(opts, 'check_back_later')
      ? 'Use `check_back_later` for one delayed self-wakeup tied to the current provider route.'
      : '',
    toolAvailable(opts, 'reply_attachment')
      ? "You can send files natively: to deliver a file to the user, call `reply_attachment` with a local path under /workspace/user-files (e.g. path='/workspace/user-files/report.pdf'). The file will be sent as a native attachment in the current provider reply."
      : '',
    toolAvailable(opts, 'cron')
      ? 'Use `cron` for recurring schedules; it supports listing, adding, updating, pausing, resuming, removing, manual run, and run history. If the user asks what recurring work, standing tasks, monitors, routines, or scheduled jobs exist in this conversation, use `cron` with action=list.'
      : '',
    toolAvailable(opts, 'memory_note')
      ? 'Use `memory_note` to save, list, update, or forget curated durable facts for this agent in the current channel. Save proactively when the user states a preference, correction, personal detail, or stable fact about their environment, conventions, or workflow. If the user asks what you remember about this channel, use `memory_note` with action=list. A channel can have at most 40 notes and each note can have at most 500 characters; when the limit is reached, list/update/forget/merge notes before saving another one.'
      : '',
    toolAvailable(opts, 'memory_search')
      ? 'Use `memory_search` before answering about prior work, decisions, dates, people, preferences, or channel history.'
      : '',
    toolAvailable(opts, 'memory_browse') ? 'Use `memory_browse` for exact channel-history browsing.' : '',
    toolAvailable(opts, 'skill_view') && toolAvailable(opts, 'skill_append')
      ? "Use `skill_view` to load enabled skills and `skill_append` to append durable notes to this agent's DB-backed overlay for an enabled skill. The skill index is not inspection evidence: when the user asks to inspect, view, choose, recommend, or identify an available skill, pick the relevant listed skill and call `skill_view` before answering. When loaded skill content refers to relative paths, resolve them from that skill's `directory` attribute and run commands with absolute paths."
      : ''
  ].filter(Boolean)

  const routingLines = [
    toolAvailable(opts, 'command') && toolAvailable(opts, 'read_file')
      ? 'Do not use command to read large files; use read_file.'
      : '',
    toolAvailable(opts, 'command') && toolAvailable(opts, 'patch')
      ? 'Do not use command to edit files; use patch.'
      : '',
    'Do not invent tools that are not present in the tool list for this run.'
  ].filter(Boolean)

  return `<tools>
<about_computer>
These tools operate on your Ankole Agent Computer: an agent-owned execution environment backed by a container. It exposes a stable /workspace view and is your place for files, commands, browser automation, skill overlays, and generated artifacts. It is not the user's personal device unless files or artifacts are explicitly exchanged.

Current worker-image baseline: Python 3.12-compatible tooling via the agent Python environment, Bun 1.3.14 for JavaScript/TypeScript work, Chromium/CDP for browser automation, LibreOffice/Pandoc/Poppler/QPDF for document work, and common shell/dev utilities such as jq, bash, git, rg, and tmux. Verify exact versions with a quick command when the task depends on them.

Persistence model: /workspace/user-files is durable shared filesystem storage for uploaded files, deliverables, browser artifacts, and per-agent environment/package deltas. Enabled skill files come from worker image assets, agent-installed skill files come from managed shared skill storage, and skill overlays are PG semantic state resolved through RuntimeFabric. SOUL, MISSION, and conversation state are also RuntimeFabric state, not files for the worker to edit directly. /workspace/temp is non-persistent scratch/runtime state. Recoverable terminal sessions, when exposed by a tool, are backed internally by tmux and also belong to this non-persistent runtime layer.

${toolUsageLines.join('\n')}
Treat the computer as a trusted Ankole work environment with useful isolation boundaries, not as a hardened security sandbox.
</about_computer>

<tool_routing_policy>
${routingLines.join('\n')}
</tool_routing_policy>
</tools>`
}

function toolAvailable(opts: BuildAgentSystemPromptOptions, name: string): boolean {
  if (!opts.availableToolNames) return true
  return opts.availableToolNames.includes(name)
}

function browserToolsAvailable(opts: BuildAgentSystemPromptOptions): boolean {
  if (!opts.availableToolNames) return true
  return opts.availableToolNames.some(name => name.startsWith('browser_'))
}

/**
 * Converts runtime skill metadata into prompt catalog entries.
 */
function skillsForSystemPrompt(opts: BuildAgentSystemPromptOptions): SkillPromptEntry[] {
  return (opts.agentConversationContext?.skills ?? []).map(skillPromptEntryFromRuntime).filter(isSkillPromptEntry)
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
    disableModelInvocation
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
 * Reads and trims a string field from prompt-building context.
 */
function nonEmptyStringArg(args: JsonObject | undefined, key: string): string | undefined {
  const value = rawStringArg(args, key)?.trim()
  return value ? value : undefined
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
