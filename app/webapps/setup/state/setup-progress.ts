export type SetupStepID = 'bootstrap' | 'plugins' | 'industry' | 'identity'
export type SetupStepState = 'completed' | 'current' | 'available' | 'locked'

const STEP_ORDER: SetupStepID[] = ['bootstrap', 'plugins', 'industry', 'identity']

export function setupStepState(
  step: SetupStepID,
  current: SetupStepID,
  authenticated: boolean,
  completed: ReadonlySet<SetupStepID>
): SetupStepState {
  if (step === 'bootstrap') return authenticated ? 'completed' : 'current'
  if (!authenticated) return 'locked'
  if (step === current) return 'current'

  const stepIndex = STEP_ORDER.indexOf(step)
  if (stepIndex < STEP_ORDER.indexOf(current)) return 'completed'

  // A later step opens only after every step between here and it has run once.
  return STEP_ORDER.slice(1, stepIndex).every(id => completed.has(id)) ? 'available' : 'locked'
}
