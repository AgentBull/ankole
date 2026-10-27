import { createModel, signal } from '@preact/signals-react'

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

export function readSetupProgress(search: string) {
  const params = new URLSearchParams(search)
  const candidate = params.get('step')
  const step = candidate === 'industry' || candidate === 'identity' ? candidate : 'plugins'
  const completed = new Set<SetupStepID>()
  if (params.get('completed')?.includes('plugins') || step !== 'plugins') completed.add('plugins')
  if (params.get('completed')?.includes('industry') || step === 'identity') completed.add('industry')
  return { step, completed } as { step: Exclude<SetupStepID, 'bootstrap'>; completed: ReadonlySet<SetupStepID> }
}

export const SetupProgressModel = createModel(() => {
  const initial = readSetupProgress(window.location.search)
  const step = signal(initial.step)
  const completed = signal(initial.completed)
  const select = (next: Exclude<SetupStepID, 'bootstrap'>) => {
    step.value = next
    const url = new URL(window.location.href)
    url.searchParams.set('step', next)
    url.searchParams.set('completed', [...completed.value].join(','))
    window.history.replaceState(null, '', url)
  }
  return {
    step,
    completed,
    select,
    complete(value: SetupStepID, next: Exclude<SetupStepID, 'bootstrap'>) {
      completed.value = new Set([...completed.value, value])
      select(next)
    }
  }
})
