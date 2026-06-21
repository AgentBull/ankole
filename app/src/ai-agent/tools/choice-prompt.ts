import {
  bullxInteractiveOutputVersion,
  type BullXInteractiveOutput,
  type BullXInteractiveOutputChoiceOption
} from '@agentbull/bullx-sdk/plugins'
import { parseBullXInteractiveOutputActionValue } from '@agentbull/bullx-sdk/plugins'

// Stable control id stamped on the card and checked on the way back, so a click
// that belongs to some other interactive card is not misread as a clarify answer.
const CLARIFY_CONTROL_ID = 'clarify_answer'
// Shown under the buttons because the card also accepts a free-text reply, not
// just the predefined options.
const FREE_TEXT_HINT = 'Reply in this chat if none of the choices fit.'

export interface ClarifyAnswerValue {
  controlId: typeof CLARIFY_CONTROL_ID
  interactionId: string
  choiceIndex: number
  choiceValue: string
}

export interface ClarifyChoicePromptInput {
  question: string
  choices: string[]
  correlationId: string
  fallbackText: string
  locked?: boolean
  answeredChoiceIndex?: number
  answeredText?: string
}

/**
 * Builds the interactive clarify card for channels that can render one.
 *
 * `correlationId` (the conversation id) becomes the card's `interactionId` so a
 * later click can be tied back to the right pending question. `customText`
 * keeps the free-text escape hatch open alongside the buttons. The policy makes
 * the first response win and lets any room member answer — a group clarify is
 * resolved by whoever replies first, not only the original asker. When `locked`
 * is set the card is re-rendered as already answered with the winning option
 * highlighted, which is how an answered question stops accepting more clicks.
 */
export function renderClarifyChoicePrompt(input: ClarifyChoicePromptInput): BullXInteractiveOutput {
  const options = input.choices.map(choiceOption)
  const selectedOptionId = input.answeredChoiceIndex === undefined ? undefined : options[input.answeredChoiceIndex]?.id

  return {
    version: bullxInteractiveOutputVersion,
    content: {
      title: 'Clarification needed',
      body: input.question,
      format: 'markdown'
    },
    response: {
      type: 'choice',
      interactionId: input.correlationId,
      controlId: CLARIFY_CONTROL_ID,
      selection: 'single',
      options,
      customText: { enabled: true, hint: FREE_TEXT_HINT },
      policy: { firstResponseWins: true, responderScope: 'any_room_member' }
    },
    state: {
      status: input.locked ? 'answered' : 'open',
      selectedOptionId,
      responseText: input.answeredText
    },
    fallbackText: input.fallbackText
  }
}

/**
 * Decodes a card-button click payload back into a clarify answer. Returns
 * undefined for anything that is not a clarify action — a malformed payload or a
 * click on a different control — so the gateway only treats real clarify clicks
 * as answers.
 */
export function parseClarifyAnswerValue(value: unknown): ClarifyAnswerValue | undefined {
  const action = parseBullXInteractiveOutputActionValue(value)
  if (!action || action.controlId !== CLARIFY_CONTROL_ID) return undefined

  return {
    controlId: CLARIFY_CONTROL_ID,
    interactionId: action.interactionId,
    choiceIndex: choiceIndexFromOptionId(action.optionId),
    choiceValue: action.value ?? ''
  }
}

// Option ids are positional (`choice_<index>`) so the click can be mapped back
// to the original choice index without carrying a separate lookup table.
function choiceOption(choice: string, index: number): BullXInteractiveOutputChoiceOption {
  return {
    id: `choice_${index}`,
    label: choice,
    value: choice,
    style: 'primary'
  }
}

// Recovers the index from a `choice_<n>` id; -1 when the id is absent or was the
// free-text option, i.e. "not one of the predefined choices".
function choiceIndexFromOptionId(optionId: string | undefined): number {
  const match = optionId?.match(/^choice_(\d+)$/)
  return match ? Number(match[1]) : -1
}
