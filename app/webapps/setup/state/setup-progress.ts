export type SetupStepID = 'bootstrap' | 'plugins' | 'identity'
export type SetupStepState = 'completed' | 'current' | 'locked'

export function setupStepState(
  step: SetupStepID,
  current: SetupStepID,
  authenticated: boolean,
  pluginsCompleted: boolean
): SetupStepState {
  if (step === 'bootstrap') return authenticated ? 'completed' : 'current'
  if (!authenticated) return 'locked'
  if (step === 'plugins') return pluginsCompleted && current === 'identity' ? 'completed' : 'current'
  return pluginsCompleted && current === 'identity' ? 'current' : 'locked'
}
