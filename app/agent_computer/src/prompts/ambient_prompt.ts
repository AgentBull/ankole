/**
 * Prompt builders for the ambient recognizer: the cheap pre-step that decides
 * whether the agent should proactively speak in an IM room where it was not
 * directly addressed. The response schema is owned by `runAmbientRecognizer`
 * through AI SDK `Output.object`, so this module stays focused on policy text.
 */

export type AmbientRecognizerSystemPromptInput = {
  agentUid: string
  channelLabel?: string
  conversationId: string
  displayName: string
  mission?: string
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
    `You are deciding whether ${input.displayName} should proactively speak in an IM room.`,
    '',
    'This is an internal Ankole decision step, not the visible reply. The visible reply, if any, will be written by the normal agent generation loop.',
    '',
    agentIdentitySection(input),
    agentSoulSection(input.soul),
    missionSection(input.mission),
    runtimeContextSection(input),
    [
      '<intervention_policy>',
      '"Ambient" means room messages observed by Ankole where the agent was not directly addressed.',
      'The product question is whether a capable human teammate with this agent identity would now enter the conversation with a useful, low-friction reply.',
      'Return intervene=true when the current observed messages contain a concrete request, question, correction, handoff, blocker, or recoverable reference that this agent can likely answer or unblock.',
      'Return intervene=true when people clearly summon or assign work to the agent but omit a material detail; the later visible reply should ask a brief clarification.',
      'Return intervene=false when replying would be redundant, speculative, socially awkward, interruptive, or based only on stale context.',
      'Return intervene=false for casual chatter, acknowledgements, reactions, or messages already handled by someone else.',
      'Use only the current observed messages as the trigger. Recent transcript and earlier observed messages are supporting context, not standalone reasons to speak.',
      'Use the structured output schema. Do not write markdown or prose outside the structured result.',
      '</intervention_policy>'
    ].join('\n')
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Builds the user-turn prompt carrying the room state to judge, passed in as YAML.
 *
 * The closing instruction is load-bearing: only the current observed messages
 * may trigger a reply, preventing repeated intervention on stale chatter.
 */
export function buildAmbientRecognizerUserPrompt(decisionInputYaml: string): string {
  return [
    'Decide whether the agent should send a visible reply to the IM room now.',
    '',
    '<decision_input>',
    decisionInputYaml.trim(),
    '</decision_input>',
    '',
    'Use only the current observed messages as the trigger. Recent transcript and earlier observed messages are supporting context, not standalone reasons to speak.'
  ].join('\n')
}

function agentIdentitySection(input: AmbientRecognizerSystemPromptInput): string {
  return ['<agent_identity>', `display_name: ${input.displayName}`, `uid: ${input.agentUid}`, '</agent_identity>'].join(
    '\n'
  )
}

function agentSoulSection(soul: string): string {
  const content = soul.trim()
  if (!content) return ''
  return ['<agent_soul>', content, '</agent_soul>'].join('\n')
}

function missionSection(mission: string | undefined): string {
  const content = mission?.trim()
  if (!content) return ''
  return ['<mission>', content, '</mission>'].join('\n')
}

function runtimeContextSection(input: AmbientRecognizerSystemPromptInput): string {
  return [
    '<runtime_context>',
    `timezone: ${input.timezone}`,
    `conversation_id: ${input.conversationId}`,
    `current_channel: ${input.channelLabel ?? 'unknown room'}`,
    '</runtime_context>'
  ].join('\n')
}
