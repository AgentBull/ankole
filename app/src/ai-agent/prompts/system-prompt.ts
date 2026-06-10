import { match } from '@pleisto/active-support'
import { eq } from 'drizzle-orm'
import { DB, type QueryExecutor } from '@/common/database'
import { Principals } from '@/common/db-schema'
import { loadSystemTimezone, zonedParts } from '@/config/system'
import { getMission, getSoul, skillsForSystemPrompt } from '../library/service'
import { loadDefaultMissionTemplate, loadDefaultSoulTemplate } from '../library/default-soul'
import { formatSkillsForSystemPrompt } from './skills-prompt'

export interface BuildAgentSystemPromptOptions {
  conversationStartedAt?: Date
  currentChannel?: CurrentChannelContext
}

export type CurrentChannelContext =
  | {
      bindingName?: string
      id?: string
      kind: 'external_dm' | 'external_group' | 'external_room'
      name?: string
      platform?: string
    }
  | {
      id?: string
      kind: 'scheduled_task'
      name?: string
    }
  | {
      id?: string
      kind: 'checkback'
    }

export async function buildAgentSystemPrompt(
  agentUid: string,
  executor: QueryExecutor = DB,
  options: BuildAgentSystemPromptOptions = {}
): Promise<string> {
  const displayName = await resolveAgentDisplayName(agentUid, executor)
  const soul = (await getSoul(agentUid, executor)) ?? (await loadDefaultSoulTemplate())
  const mission = (await getMission(agentUid, executor)) ?? (await loadDefaultMissionTemplate())
  const skills = await skillsForSystemPrompt(agentUid, executor)
  const skillPrompt = formatSkillsForSystemPrompt(skills)
  const runtimeContext = await runtimeContextSection(options)
  const runtimeIdentity = [
    '<runtime_identity>',
    `<uid>${agentUid}</uid>`,
    'Use this exact Agent UID when a tool or skill asks for the current agent identity.',
    '</runtime_identity>'
  ].join('\n')

  return [
    `You are ${displayName}, an AI colleague powered by BullX.`,
    soul.trim(),
    missionSection(mission),
    runtimeIdentity,
    runtimeContext,
    toolRoutingPolicySection(),
    skillPrompt.trim()
  ]
    .filter(Boolean)
    .join('\n\n')
}

async function resolveAgentDisplayName(agentUid: string, executor: QueryExecutor): Promise<string> {
  const [row] = await executor
    .select({ displayName: Principals.displayName })
    .from(Principals)
    .where(eq(Principals.uid, agentUid))
    .limit(1)
  return row?.displayName?.trim() || agentUid
}

function missionSection(mission: string): string {
  const content = mission.trim()
  if (!content) return ''

  return ['Your mission is:', '<mission>', content, '</mission>'].join('\n')
}

async function runtimeContextSection(options: BuildAgentSystemPromptOptions): Promise<string> {
  const timezone = await loadSystemTimezone()
  const lines = ['<runtime_context>', `Current timezone: ${timezone}`]
  if (options.conversationStartedAt) {
    lines.push(`Conversation started date: ${formatZonedDate(timezone, options.conversationStartedAt)}`)
  }
  if (options.currentChannel) {
    lines.push(`Current channel: ${formatCurrentChannel(options.currentChannel)}`)
  }
  lines.push('</runtime_context>')

  return lines.join('\n')
}

function formatCurrentChannel(channel: CurrentChannelContext): string {
  return match(channel)
    .with({ kind: 'scheduled_task' }, ({ name, id }) => {
      const base = name ? `scheduled task "${name}"` : 'scheduled task'
      return id ? `${base} (task id: ${id})` : base
    })
    .with({ kind: 'checkback' }, ({ id }) => `check-back wakeup${id ? ` (checkback id: ${id})` : ''}`)
    .with({ kind: 'external_dm' }, ({ name, platform }) => {
      const label = platformLabel(platform, 'DM')
      return name ? `${label} with ${name}` : label
    })
    .with({ kind: 'external_group' }, ({ name, platform }) => {
      const label = platformLabel(platform, 'group chat')
      return name ? `${label} "${name}"` : label
    })
    .with({ kind: 'external_room' }, ({ name, platform }) => {
      const label = platformLabel(platform, 'channel')
      return name ? `${label} "${name}"` : label
    })
    .exhaustive()
}

function platformLabel(platform: string | undefined, noun: string): string {
  const brand = match(platform)
    .with('feishu', () => 'Feishu')
    .with('lark', () => 'Lark')
    .otherwise(p => p)
  return brand ? `${brand} ${noun}` : noun
}

function toolRoutingPolicySection(): string {
  return [
    '<tool_routing_policy>',
    'When the user asks what was previously said, remembered, agreed, mentioned, or discussed in chat, use chat_history_search as the primary evidence tool.',
    'For chat-history recall questions, do not escalate to web_search, browser, command, terminal, or workspace file tools merely because chat_history_search finds no answer.',
    'Escalate beyond chat_history_search only when the user explicitly asks to search the web, inspect files, run commands, use a browser, or check runtime state.',
    'If focused chat-history searches do not find supporting evidence, say that the prior chat history does not contain the answer; do not guess.',
    '</tool_routing_policy>'
  ].join('\n')
}

function formatZonedDate(timezone: string, at: Date): string {
  const parts = zonedParts(timezone, at)
  const padded = {
    year: parts.year.toString().padStart(4, '0'),
    month: parts.month.toString().padStart(2, '0'),
    day: parts.day.toString().padStart(2, '0')
  }
  return `${padded.year}-${padded.month}-${padded.day}`
}
