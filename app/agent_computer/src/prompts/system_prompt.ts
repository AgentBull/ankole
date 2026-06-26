/**
 * Builds the base system prompt for one agent run: stable model-facing
 * instructions plus agent-owned SOUL/MISSION text, runtime context, tool policy,
 * and skill catalog.
 *
 * This is a prompt-engineering artifact. Literal strings here are the contract
 * with the model; surrounding code only decides which blocks are present and in
 * what order. The ordering follows BullX's cache-friendly shape: slow-changing
 * identity/persona/mission first, then runtime facts, policies, tool routing,
 * and finally the skill index.
 */
import type { TurnStart } from '../actor_lane'
import type { AgentProfile, RuntimeSkillSummary, TurnRuntimeContext } from '../rpc_lane'
import { formatSkillsForSystemPrompt, type SkillPromptEntry } from './skills_prompt'

export type BuildAgentSystemPromptOptions = {
  workspaceRoot: string
  turnStart: TurnStart
  agentProfile?: AgentProfile
  runtimeContext?: TurnRuntimeContext
  timezone?: string
  conversationStartedAt?: Date
  currentChannel?: CurrentChannelContext
}

/**
 * Describes where the conversation originated so the prompt can tell the model
 * what kind of surface it is acting on. Scheduled-task and checkback variants
 * from BullX are intentionally not exposed in this first Ankole main-chain pass.
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
  if (!opts.runtimeContext) {
    throw new Error('runtime context is required to build the agent system prompt')
  }

  const displayName = agentDisplayName(opts)
  const soul = opts.runtimeContext.soul || fallbackSoul()
  const mission = opts.runtimeContext.mission || ''
  const skills = skillsForSystemPrompt(opts)
  const skillPrompt = formatSkillsForSystemPrompt(skills)

  return [
    `You are ${displayName}, an AI colleague powered by Ankole.`,
    soul.trim(),
    missionSection(mission),
    runtimeContextSection(opts),
    agentEnvironmentInfoPolicySection(),
    toolsSection(),
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
 * Emits per-run facts the model needs but cannot infer: exact agent/session/turn
 * identity, timezone, and optional channel/date information.
 */
function runtimeContextSection(opts: BuildAgentSystemPromptOptions): string {
  const timezone = opts.timezone ?? 'UTC'
  const lines = [
    '<runtime_context>',
    `Agent UID: ${opts.turnStart.turn.actor.agent_uid}`,
    `Agent display name: ${agentDisplayName(opts)}`,
    'Use this exact Agent UID when a tool or skill asks for the current agent identity.',
    `Session ID: ${opts.turnStart.turn.actor.session_id}`,
    `LLM turn ID: ${opts.turnStart.turn.llm_turn_id}`,
    `Current timezone: ${timezone}`
  ]
  const role = agentRole(opts)
  if (role) lines.push(`Agent role: ${role}`)

  if (opts.conversationStartedAt) {
    lines.push(`Conversation started date: ${formatZonedDate(timezone, opts.conversationStartedAt)}`)
  }
  if (opts.currentChannel) {
    lines.push(`Conversation started channel: ${formatCurrentChannel(opts.currentChannel)}`)
  }

  lines.push('</runtime_context>')
  return lines.join('\n')
}

function agentDisplayName(opts: BuildAgentSystemPromptOptions): string {
  const displayName = opts.agentProfile?.display_name?.trim()
  return displayName || opts.turnStart.turn.actor.agent_uid
}

function agentRole(opts: BuildAgentSystemPromptOptions): string | undefined {
  const role = opts.agentProfile?.role?.trim()
  return role || undefined
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

function toolsSection(): string {
  return `<tools>
<about_computer>
These tools operate on your Ankole Agent Computer: an agent-owned execution environment backed by a container. It exposes a stable /workspace view and is your place for files, commands, browser automation, skill overlays, and generated artifacts. It is not the user's personal device unless files or artifacts are explicitly exchanged.

Current worker-image baseline: Python 3.12-compatible tooling via the agent Python environment, Bun 1.3.14 for JavaScript/TypeScript work, Chromium/Xvfb for browser automation, LibreOffice/Pandoc/Poppler/QPDF for document work, and common shell/dev utilities such as jq, bash, git, rg, and tmux. Verify exact versions with a quick command when the task depends on them.

Persistence model: /workspace/user-files is durable shared filesystem storage for uploaded files, deliverables, browser artifacts, and per-agent environment/package deltas. Enabled skills are loaded only through skill_view; built-in skill files come from worker image assets, agent-installed skill files come from managed shared skill storage, and skill overlays are PG semantic state resolved through RuntimeFabric. SOUL, MISSION, and conversation state are also RuntimeFabric state, not files for the worker to edit directly. /workspace/temp is non-persistent scratch/runtime state. Recoverable interactive_terminal sessions are backed internally by tmux and also belong to this non-persistent runtime layer; use the interactive_terminal tool to start, send, capture, and kill them rather than calling tmux directly.

Use \`read_file\` for paginated text reads and \`patch\` for targeted edits.
Use \`command\` for stateless one-shot shell work.
Use \`interactive_terminal\` for TTY/TUI programs, REPLs, and long-running interactive processes.
Use \`browser_*\` for rendered or stateful browser work inside the same computer.
Use \`reply_attachment\` when a file under /workspace/user-files should be sent as a native attachment in your final external reply.
Use \`skill_view\` to load enabled skills and \`skill_append\` to replace this agent's DB-backed overlay for an enabled skill.
Treat the computer as a trusted Ankole work environment with useful isolation boundaries, not as a hardened security sandbox.
</about_computer>

<tool_routing_policy>
Do not use command to read large files; use read_file.
Do not use command to edit files; use patch.
Do not invent tools that are not present in the tool list for this run.
</tool_routing_policy>
</tools>`
}

function skillsForSystemPrompt(opts: BuildAgentSystemPromptOptions): SkillPromptEntry[] {
  return (opts.runtimeContext?.skills ?? []).map(skillPromptEntryFromRuntime).filter(isSkillPromptEntry)
}

function skillPromptEntryFromRuntime(skill: RuntimeSkillSummary): SkillPromptEntry | null {
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

function isSkillPromptEntry(skill: SkillPromptEntry | null): skill is SkillPromptEntry {
  return skill !== null
}

function formatCurrentChannel(channel: CurrentChannelContext): string {
  switch (channel.kind) {
    case 'external_dm': {
      const label = platformLabel(channel.platform, 'DM')
      return channel.name ? `${label} with ${channel.name}` : label
    }
    case 'external_group': {
      const label = platformLabel(channel.platform, 'Group Chat')
      return channel.name ? `${label} "${channel.name}"` : label
    }
    case 'external_room': {
      const label = platformLabel(channel.platform, 'Channel')
      return channel.name ? `${label} "${channel.name}"` : label
    }
  }
}

function platformLabel(platform: string | undefined, noun: string): string {
  const brand = platform === 'feishu' ? 'Feishu' : platform === 'lark' ? 'Lark' : platform
  return brand ? `${brand} ${noun}` : noun
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

function fallbackSoul(): string {
  return 'You are an Ankole AI colleague. Reply in plain text.'
}
