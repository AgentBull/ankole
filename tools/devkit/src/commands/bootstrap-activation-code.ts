export type BootstrapActivationCodeState = {
  value?: string | null
  completed?: boolean
}

export type BootstrapActivationCodeStatus =
  | { kind: 'completed'; text: string }
  | { kind: 'active'; code: string; text: string }
  | { kind: 'missing'; text: string }

export const bootstrapActivationCodeLabel = 'SETUP ACTIVATION CODE'
export const bootstrapActivationCodeLabelWithColon = `${bootstrapActivationCodeLabel}:`
export const bootstrapActivationCodeCompletedMessage =
  'Setup is already completed. No bootstrap activation code is active.'
export const bootstrapActivationCodeMissingMessage = 'Setup is open, but no bootstrap activation code is stored.'

export function bootstrapActivationCodeLine(code: string): string {
  return `${bootstrapActivationCodeLabelWithColon} ${code}`
}

export function bootstrapActivationCodeStatus(state: BootstrapActivationCodeState): BootstrapActivationCodeStatus {
  if (state.completed) {
    return { kind: 'completed', text: bootstrapActivationCodeCompletedMessage }
  }

  if (state.value) {
    return { kind: 'active', code: state.value, text: bootstrapActivationCodeLine(state.value) }
  }

  return { kind: 'missing', text: bootstrapActivationCodeMissingMessage }
}
