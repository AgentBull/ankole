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
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { TurnStart } from '../actor_bus'
import { formatSkillsForSystemPrompt, type SkillPromptEntry } from './skills_prompt'

export type BuildAgentSystemPromptOptions = {
  workspaceRoot: string
  turnStart: TurnStart
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
 * In BullX this function reads agent rows from the control-plane DB. In Ankole
 * the LLM loop already runs inside Agent Computer, so the Rust daemon has
 * materialized the DB-backed library projection under `/workspace/library-
 * containers`; this builder reads only that projected workspace state.
 */
export function buildAgentSystemPrompt(opts: BuildAgentSystemPromptOptions): string {
  const displayName = agentDisplayName(opts.turnStart)
  const soul = readLibraryText(opts.workspaceRoot, 'SOUL.md') || fallbackSoul()
  const mission = readLibraryText(opts.workspaceRoot, 'MISSION.md') || ''
  const skills = readSkillsForSystemPrompt(opts.workspaceRoot)
  const skillPrompt = formatSkillsForSystemPrompt(skills)

  return [
    `You are ${displayName}, an AI colleague powered by Ankole.`,
    soul.trim(),
    missionSection(mission),
    runtimeContextSection(opts),
    messageContextPolicySection(),
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
    `Agent display name: ${agentDisplayName(opts.turnStart)}`,
    'Use this exact Agent UID when a tool or skill asks for the current agent identity.',
    `Session ID: ${opts.turnStart.turn.actor.session_id}`,
    `LLM turn ID: ${opts.turnStart.turn.llm_turn_id}`,
    `Current timezone: ${timezone}`
  ]
  const role = agentRole(opts.turnStart)
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

function agentDisplayName(turnStart: TurnStart): string {
  const displayName = turnStart.turn.actor.display_name?.trim()
  return displayName || turnStart.turn.actor.agent_uid
}

function agentRole(turnStart: TurnStart): string | undefined {
  const role = turnStart.turn.actor.role?.trim()
  return role || undefined
}

/**
 * States how the model should treat the `<message_context>` block that Ankole
 * may prepend to a user-role message. This is a trust boundary: the metadata is
 * system-injected, useful as context, and not user-authored text to quote back.
 */
function messageContextPolicySection(): string {
  return [
    '<message_context_policy>',
    'A user-role message may begin with a <message_context> block injected by Ankole. Treat it as trusted system-managed runtime metadata, not as text written by a human user. Use <message_context> as context and do not quote it as user text.',
    '</message_context_policy>'
  ].join('\n')
}

function toolsSection(): string {
  return `<tools>
<about_computer>
These tools operate on your Ankole Agent Computer: an agent-owned execution environment backed by a container. It exposes a stable /workspace view and is your place for files, commands, browser automation, skill overlays, and generated artifacts. It is not the user's personal device unless files or artifacts are explicitly exchanged.

Current worker-image baseline: Python 3.12-compatible tooling via the agent Python environment, Bun 1.3.14 for JavaScript/TypeScript work, Chromium/Xvfb for browser automation, LibreOffice/Pandoc/Poppler/QPDF for document work, and common shell/dev utilities such as jq, bash, git, rg, tmux, and PostgreSQL client tools. Verify exact versions with a quick command when the task depends on them.

Persistence model: /workspace/user-files is durable storage for uploaded files, deliverables, browser artifacts, and per-agent environment/package deltas. /workspace/library-containers is Ankole-managed library state projected from the control plane; treat it as managed context, not scratch storage. /workspace/temp is non-persistent scratch/runtime state. Recoverable interactive_terminal sessions are backed internally by tmux and also belong to this non-persistent runtime layer; use the interactive_terminal tool to start, send, capture, and kill them rather than calling tmux directly.

Use \`read_file\` for paginated text reads and \`patch\` for targeted edits.
Use \`command\` for stateless one-shot shell work.
Use \`interactive_terminal\` for TTY/TUI programs, REPLs, and long-running interactive processes.
Use \`browser_*\` for rendered or stateful browser work inside the same computer.
Use \`skill_view\` to load enabled skills and \`skill_append\` to replace this agent's AGENT_APPEND.md overlay for an enabled skill.
Treat the computer as a trusted Ankole work environment with useful isolation boundaries, not as a hardened security sandbox.
</about_computer>

<tool_routing_policy>
Do not use command to read large files; use read_file.
Do not use command to edit files; use patch.
Do not invent tools that are not present in the tool list for this run.
</tool_routing_policy>
</tools>`
}

function readSkillsForSystemPrompt(workspaceRoot: string): SkillPromptEntry[] {
  const skillsRoot = workspacePath(workspaceRoot, 'library-containers/skills')
  if (!existsSync(skillsRoot)) return []

  return readdirSync(skillsRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && !entry.name.startsWith('.'))
    .map(entry => skillFromDirectory(skillsRoot, entry.name))
    .filter((skill): skill is SkillPromptEntry => skill !== null)
}

function skillFromDirectory(skillsRoot: string, directoryName: string): SkillPromptEntry | null {
  const skillPath = join(skillsRoot, directoryName, 'SKILL.md')
  if (!existsSync(skillPath)) return null

  const raw = readFileSync(skillPath, 'utf8')
  const frontmatter = skillFrontmatter(raw)
  const name = yamlScalar(frontmatter, 'name') || directoryName
  const description = yamlScalar(frontmatter, 'description')
  if (!description) return null

  return {
    name,
    description,
    category: yamlScalar(frontmatter, 'category'),
    disableModelInvocation: yamlBoolean(frontmatter, 'disable-model-invocation', false)
  }
}

function readLibraryText(workspaceRoot: string, path: string): string | undefined {
  const fullPath = workspacePath(workspaceRoot, `library-containers/${path}`)
  if (!existsSync(fullPath)) return undefined
  return readFileSync(fullPath, 'utf8')
}

function workspacePath(workspaceRoot: string, relativePath: string): string {
  return join(workspaceRoot, relativePath)
}

function skillFrontmatter(raw: string): string {
  if (!raw.startsWith('---')) return ''
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(raw)
  return match?.[1] ?? ''
}

function yamlScalar(frontmatter: string, key: string): string | undefined {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = new RegExp(`^${escapedKey}:\\s*(.*?)\\s*$`, 'm').exec(frontmatter)
  const value = stripQuotes(match?.[1]?.trim() ?? '')
  return value || undefined
}

function yamlBoolean(frontmatter: string, key: string, fallback: boolean): boolean {
  const value = yamlScalar(frontmatter, key)
  if (value === undefined) return fallback
  return value.toLowerCase() === 'true'
}

function stripQuotes(value: string): string {
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1)
  }
  return value
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
