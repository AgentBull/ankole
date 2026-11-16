import { uuidV4 } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import {
  buildCoalescePayload,
  eventTypeFilterExpression,
  isValidCoalesceInput,
  type ConnectorEventOrigin
} from '../connector-event-picker'
import type { JobCandidateAgent } from '../jobs-api'

export type JobStarterPreset = {
  mode: 'one_off' | 'cron'
  agentUID?: string
  title?: string
  task?: string
  expression?: string
}

export type RoutineTriggerMode = 'schedule' | 'event' | 'hybrid'

export const DEFAULT_DELIVERY = '__default__'
export const DEFAULT_CRON_EXPRESSION = '0 9 * * 1-5'

function defaultTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  } catch {
    return 'UTC'
  }
}

function initialFormValues(preset?: JobStarterPreset | null, agents: ReadonlyArray<JobCandidateAgent> = []) {
  const anyBackgroundCapable = agents.some(agent => agent.canRunBackgroundJob)
  const presetAgent = preset?.agentUID ? agents.find(agent => agent.uid === preset.agentUID) : undefined
  const mode: 'one_off' | 'cron' =
    preset?.mode === 'cron' ||
    (agents.length > 0 && !anyBackgroundCapable) ||
    (presetAgent && !presetAgent.canRunBackgroundJob)
      ? 'cron'
      : 'one_off'
  const preferredAgent =
    presetAgent ?? (mode === 'one_off' ? (agents.find(agent => agent.canRunBackgroundJob) ?? agents[0]) : agents[0])

  return {
    mode,
    agentUID: preset?.agentUID ?? preferredAgent?.uid ?? '',
    title: preset?.title ?? '',
    task: preset?.task ?? '',
    expression: preset?.expression ?? DEFAULT_CRON_EXPRESSION,
    timezone: defaultTimezone()
  }
}

export function resolveJobCandidateAgent(
  agents: ReadonlyArray<JobCandidateAgent>,
  agentUID: string
): JobCandidateAgent | undefined {
  return agents.find(agent => agent.uid === agentUID) ?? agents[0]
}

export const JobCreateFormModel = createModel(
  (preset?: JobStarterPreset | null, initialAgents: ReadonlyArray<JobCandidateAgent> = []) => {
    const seed = initialFormValues(preset, initialAgents)

    const mode = signal<'one_off' | 'cron'>(seed.mode)
    const triggerMode = signal<RoutineTriggerMode>('schedule')
    const agentUID = signal(seed.agentUID)
    const title = signal(seed.title)
    const task = signal(seed.task)
    const expression = signal(seed.expression)
    const timezone = signal(seed.timezone)
    const quietSuccess = signal(true)
    const runNow = signal(false)
    const deliveryConversationID = signal(DEFAULT_DELIVERY)
    const requestID = signal(uuidV4())

    const eventSourceRef = signal('')
    const eventType = signal('')
    const coalesceWindowSec = signal('5')
    const coalesceMaxBatch = signal('20')

    const hasScheduleTrigger = computed(() => triggerMode.value === 'schedule' || triggerMode.value === 'hybrid')
    const hasEventTrigger = computed(() => triggerMode.value === 'event' || triggerMode.value === 'hybrid')
    const validCron = computed(() => !hasScheduleTrigger.value || expression.value.trim().split(/\s+/).length === 5)
    const validCoalesce = computed(() => isValidCoalesceInput(coalesceWindowSec.value, coalesceMaxBatch.value))
    const coalesce = computed(() => buildCoalescePayload(coalesceWindowSec.value, coalesceMaxBatch.value))
    const hasRequiredText = computed(() => Boolean(title.value.trim()) && Boolean(task.value.trim()))

    return {
      mode,
      triggerMode,
      agentUID,
      title,
      task,
      expression,
      timezone,
      quietSuccess,
      runNow,
      deliveryConversationID,
      requestID,
      eventSourceRef,
      eventType,
      coalesceWindowSec,
      coalesceMaxBatch,
      hasScheduleTrigger,
      hasEventTrigger,
      validCron,
      validCoalesce,
      coalesce,
      hasRequiredText,
      selectMode(next: 'one_off' | 'cron', agents: ReadonlyArray<JobCandidateAgent>) {
        batch(() => {
          mode.value = next
          const current = resolveJobCandidateAgent(agents, agentUID.value)
          if (next === 'one_off' && current && !current.canRunBackgroundJob) {
            const candidate = agents.find(agent => agent.canRunBackgroundJob)
            if (candidate) agentUID.value = candidate.uid
          }
        })
      },
      selectAgent(nextUID: string, agents: ReadonlyArray<JobCandidateAgent>) {
        batch(() => {
          agentUID.value = nextUID
          const chosen = agents.find(agent => agent.uid === nextUID)
          if (chosen && !chosen.canRunBackgroundJob && mode.value === 'one_off') {
            mode.value = 'cron'
          }
        })
      },
      selectEventSource(ref: string) {
        batch(() => {
          eventSourceRef.value = ref
          eventType.value = ''
        })
      },
      resolveEventSelection(choices: ReadonlyArray<ConnectorEventOrigin>) {
        const activeSource = eventSourceRef.value
          ? choices.find(item => item.reference === eventSourceRef.value)
          : choices[0]
        const resolvedEventType = activeSource?.eventTypes.includes(eventType.value) ? eventType.value : ''
        const filterExpr = eventTypeFilterExpression(resolvedEventType)
        return {
          activeSource,
          filters: (filterExpr ? { cel: filterExpr } : {}) as Record<string, unknown>
        }
      },
      reset(nextPreset?: JobStarterPreset | null, agents: ReadonlyArray<JobCandidateAgent> = []) {
        const next = initialFormValues(nextPreset, agents)
        batch(() => {
          mode.value = next.mode
          triggerMode.value = 'schedule'
          agentUID.value = next.agentUID
          title.value = next.title
          task.value = next.task
          expression.value = next.expression
          timezone.value = next.timezone
          quietSuccess.value = true
          runNow.value = false
          deliveryConversationID.value = DEFAULT_DELIVERY
          requestID.value = uuidV4()
          eventSourceRef.value = ''
          eventType.value = ''
          coalesceWindowSec.value = '5'
          coalesceMaxBatch.value = '20'
        })
      }
    }
  }
)
