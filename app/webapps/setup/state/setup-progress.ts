export type SetupStepID = 'bootstrap' | 'plugins' | 'identity'
export type SetupStepState = 'completed' | 'current' | 'available' | 'locked'

export function setupStepState(
  step: SetupStepID,
  current: SetupStepID,
  authenticated: boolean,
  pluginsCompleted: boolean
): SetupStepState {
  if (step === 'bootstrap') return authenticated ? 'completed' : 'current'
  if (!authenticated) return 'locked'
  if (step === 'plugins') return current === 'plugins' ? 'current' : 'completed'
  if (current === 'identity') return 'current'
  return pluginsCompleted ? 'available' : 'locked'
}
