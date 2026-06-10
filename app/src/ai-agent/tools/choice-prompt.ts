import {
  bullxInteractiveOutputVersion,
  type BullXInteractiveOutput,
  type BullXInteractiveOutputChoiceOption
} from '@agentbull/bullx-sdk/plugins'
import { parseBullXInteractiveOutputActionValue } from '@agentbull/bullx-sdk/plugins'

const CLARIFY_CONTROL_ID = 'clarify_answer'
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

function choiceOption(choice: string, index: number): BullXInteractiveOutputChoiceOption {
  return {
    id: `choice_${index}`,
    label: choice,
    value: choice,
    style: 'primary'
  }
}

function choiceIndexFromOptionId(optionId: string | undefined): number {
  const match = optionId?.match(/^choice_(\d+)$/)
  return match ? Number(match[1]) : -1
}
