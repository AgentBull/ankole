/**
 * Prompt builders for the ambient recognizer: the cheap pre-step that decides
 * whether the agent should proactively speak in an IM room where it was not
 * directly addressed. The response schema is owned by `recognizeAmbientIntervention`,
 * so this module stays focused on policy text.
 */

import type { RuntimeBrainSnapshot } from '../lanes/rpc_lane'
import { formatAmbientDurableContext } from './durable_context'

export type AmbientRecognizerSystemPromptInput = {
  currentTime: string
  displayName: string
  groupName?: string
  brainSnapshot?: RuntimeBrainSnapshot
  mission?: string
  platform?: string
  soul: string
  timezone: string
}

/**
 * Builds the system prompt for the recognizer model.
 *
 * It uses the agent's real identity, soul, and mission so the decision is made
 * as that teammate. The intervention policy is intentionally conservative: a
 * wrong proactive reply in a shared room is more costly than staying quiet.
 */
export function buildAmbientRecognizerSystemPrompt(input: AmbientRecognizerSystemPromptInput): string {
  return [
    `${input.displayName} is an AI colleague Agent and a member of the ${platformGroupLabel(input.platform, input.groupName)}.`,
    '',
    aboutSection(input),
    situationSection(input.displayName, input.groupName),
    contextSection(input),
    interventionPolicySection(input.displayName)
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Builds the user-turn prompt carrying the room transcript to judge.
 */
export function buildAmbientRecognizerUserPrompt(input: { agentName: string; conversationHistory: string }): string {
  return [
    'Conversation History:',
    input.conversationHistory.trim() || '- No visible group messages were provided.',
    '',
    'Current decision point:',
    `Should ${input.agentName} proactively say something in the group after seeing this conversation?`
  ].join('\n')
}

function situationSection(agentName: string, groupName: string | undefined): string {
  const group = groupName ? `"${groupName}"` : 'the group'
  return [
    '## Situation',
    '',
    `As a group member, ${agentName} has observed people discussing topics in ${group}.`,
    `No one directly mentioned ${agentName}, so ${agentName} is unsure whether it should proactively join the conversation.`,
    '',
    `Your task is to act as an intent recognizer. Based on the <about> section, memory, runtime context, and group conversation, decide whether ${agentName} should speak now in the group.`
  ].join('\n')
}

function interventionPolicySection(agentName: string): string {
  return [
    'Be conservative:',
    '- Most group chatter should remain silent.',
    `- Speaking is appropriate only when ${agentName} was effectively asked, can answer a clear question, can unblock the discussion, prevent a likely mistake, handle a time-sensitive need, or add clear value now.`,
    '- Do not speak for casual chatter, acknowledgements, vague usefulness, duplicated answers, or topics already handled by someone else.',
    '- If speaking would require hidden or private context, only allow it when that context is relevant and safe to use.',
    '- The recognizer does not write the final group message. It only decides whether a visible reply turn should start.',
    '- Keep the reason short and internal; do not reveal private memory, hidden context, or chain-of-thought.',
    '- Return only the structured decision with fields `reason` and `should_proactively_speak`.'
  ].join('\n')
}

function aboutSection(input: AmbientRecognizerSystemPromptInput): string {
  const blocks = [agentSoulSection(input.soul), missionSection(input.mission)].filter(Boolean)

  return [
    `## About ${input.displayName}`,
    '',
    '<about>',
    blocks.length > 0 ? blocks.join('\n\n') : 'No additional profile or mission was provided.',
    '</about>'
  ].join('\n')
}

function contextSection(input: AmbientRecognizerSystemPromptInput): string {
  return ['## Context', '', runtimeContextSection(input), formatAmbientDurableContext(input.brainSnapshot)]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Renders the agent SOUL block when present.
 */
function agentSoulSection(soul: string): string {
  const content = soul.trim()
  if (!content) return ''
  return ['<agent_soul>', content, '</agent_soul>'].join('\n')
}

/**
 * Renders the agent mission block when present.
 */
function missionSection(mission: string | undefined): string {
  const content = mission?.trim()
  if (!content) return ''
  return ['<mission>', content, '</mission>'].join('\n')
}

/**
 * Renders runtime facts used by the ambient recognizer.
 */
function runtimeContextSection(input: AmbientRecognizerSystemPromptInput): string {
  return [
    '<runtime_context>',
    `current_time: ${input.currentTime}`,
    `timezone: ${input.timezone}`,
    `platform: ${platformLabel(input.platform)}`,
    `group_name: ${input.groupName ?? 'unknown group'}`,
    '</runtime_context>'
  ].join('\n')
}

function platformGroupLabel(platform: string | undefined, groupName: string | undefined): string {
  const group = groupName ? `group "${groupName}"` : 'group'
  return `${platformLabel(platform)} ${group}`
}

function platformLabel(platform: string | undefined): string {
  switch (platform?.trim().toLowerCase()) {
    case 'feishu':
      return 'Feishu'
    case 'lark':
      return 'Lark / Feishu'
    default:
      return platform?.trim() || 'messaging platform'
  }
}
