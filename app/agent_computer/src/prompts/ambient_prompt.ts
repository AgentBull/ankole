/**
 * Prompt builders for the ambient recognizer: the cheap pre-step that decides
 * whether the agent should proactively speak in an IM room where it was not
 * directly addressed. The response schema is owned by `recognizeAmbientIntervention`,
 * so this module stays focused on policy text.
 */

import type { BrainSnapshot } from '../lanes/rpc_lane'
import { formatAmbientDurableContext } from './durable_context'

export type AmbientRecognizerSystemPromptInput = {
  displayName: string
  mission?: string
  soul: string
}

export type AmbientRecognizerUserPromptInput = {
  brainSnapshot?: BrainSnapshot
  conversationHistory: string
  currentTime: string
  groupName?: string
  platform?: string
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
  return [aboutSection(input), interventionPolicySection()].filter(Boolean).join('\n\n')
}

/**
 * Builds the user-turn prompt carrying current room facts and the transcript.
 */
export function buildAmbientRecognizerUserPrompt(input: AmbientRecognizerUserPromptInput): string {
  return [
    runtimeContextSection(input),
    formatAmbientDurableContext(input.brainSnapshot),
    'Conversation History:',
    input.conversationHistory.trim() || '- No visible group messages were provided.'
  ]
    .filter(Boolean)
    .join('\n\n')
}

function interventionPolicySection(): string {
  return [
    'Decide whether this Agent should proactively start a visible reply after observing an unaddressed conversation in a shared room.',
    '',
    'Be conservative:',
    '- Most group chatter should remain silent.',
    '- Speaking is appropriate only when the Agent was effectively asked, can answer a clear question, can unblock the discussion, prevent a likely mistake, handle a time-sensitive need, or add clear value now.',
    '- Do not speak for casual chatter, acknowledgements, vague usefulness, duplicated answers, or topics already handled by someone else.',
    '- If speaking would require hidden or private context, only allow it when that context is relevant and safe to use.',
    '- The recognizer does not write the final group message. It only decides whether a visible reply turn should start.',
    '- Do not reveal private memory, hidden context, or chain-of-thought in the internal reason.'
  ].join('\n')
}

function aboutSection(input: AmbientRecognizerSystemPromptInput): string {
  const blocks = [agentSoulSection(input.soul), missionSection(input.mission)].filter(Boolean)

  return [
    '## Agent',
    '',
    '<about>',
    `<display_name>${input.displayName}</display_name>`,
    blocks.length > 0 ? blocks.join('\n\n') : 'No additional profile or mission was provided.',
    '</about>'
  ].join('\n')
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
function runtimeContextSection(input: AmbientRecognizerUserPromptInput): string {
  return [
    '<runtime_context>',
    `current_time: ${input.currentTime}`,
    `timezone: ${input.timezone}`,
    `platform: ${platformLabel(input.platform)}`,
    `group_name: ${input.groupName ?? 'unknown group'}`,
    '</runtime_context>'
  ].join('\n')
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
