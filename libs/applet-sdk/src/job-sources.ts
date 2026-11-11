import type { PodAPI } from './types'

export type JobSchedule = {
  id: string
  owner_job_id: number
  name: string
  status: 'active' | 'paused' | 'completed' | 'deleted'
  schedule: Record<string, unknown>
  timezone: string
  payload: Record<string, unknown>
  next_fire_at: string | null
  last_fire_at: string | null
}
export type JobScheduleInput = ({ id: string; name?: string } | { id?: never; name: string }) & {
  schedule?: Record<string, unknown>
  timezone?: string
  payload?: Record<string, unknown>
  idempotency_key?: string
}
export type JobWebhook = {
  id: string
  owner_job_id: number
  label: string
  mode: 'standing' | 'one_shot'
  event_format: 'raw' | 'cloudevents'
  status: 'armed' | 'active' | 'paused' | 'fired' | 'cancelled' | 'expired'
  expires_at: string
}
export type JobDelivery = {
  source_event_id: string
  received_at: string
  automation_job_run_id: number | null
  run_status: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | null
  coalesced: boolean
}
export type JobScheduleHistory = {
  events: Array<{
    id: number
    status: 'scheduled' | 'fired' | 'cancelled' | 'failed'
    cron_fire_slot_at: string | null
    fired_at: string | null
    last_fire_error: Record<string, unknown>
  }>
  deliveries: JobDelivery[]
}

/** Trigger management uses the same Page permission and personal authority as its Job. */
export function createJobSources(pod: Pick<PodAPI, 'request'>, pageID: string, jobID: number) {
  const root = `/pages/${encodeURIComponent(pageID)}/jobs/${jobID}`
  async function request<T>(path: string, method = 'GET', attributes?: unknown): Promise<T> {
    const response = await pod.request<{ result: T }>(root + path, method, attributes)
    return response.result
  }
  const idPath = (kind: string, id: string, action?: string) =>
    `/${kind}/${encodeURIComponent(id)}${action ? `/${action}` : ''}`
  return {
    schedules: {
      list: () => request<JobSchedule[]>('/schedules'),
      put: (input: JobScheduleInput) => request<JobSchedule>('/schedules', 'PUT', input),
      pause: (id: string) => request<JobSchedule>(idPath('schedules', id, 'pause'), 'POST', {}),
      resume: (id: string) => request<JobSchedule>(idPath('schedules', id, 'resume'), 'POST', {}),
      delete: (id: string) => request<JobSchedule>(idPath('schedules', id), 'DELETE'),
      run: (id: string, idempotencyKey: string) =>
        request<{ status: 'scheduled' | 'already_scheduled'; scheduled_event: { id: number } }>(
          idPath('schedules', id, 'run'),
          'POST',
          { idempotency_key: idempotencyKey }
        ),
      runs: (id: string) => request<JobScheduleHistory>(idPath('schedules', id, 'runs'))
    },
    webhooks: {
      list: () => request<Array<{ endpoint: JobWebhook; deliveries: JobDelivery[] }>>('/webhooks'),
      create: (input: {
        label: string
        expires_at: string
        mode?: JobWebhook['mode']
        event_format?: JobWebhook['event_format']
      }) => request<{ webhook_endpoint: JobWebhook; token: string; callback_path: string }>('/webhooks', 'POST', input),
      update: (id: string, input: { label?: string; expires_at?: string }) =>
        request<JobWebhook>(idPath('webhooks', id), 'PATCH', input),
      pause: (id: string) => request<JobWebhook>(idPath('webhooks', id, 'pause'), 'POST', {}),
      resume: (id: string) => request<JobWebhook>(idPath('webhooks', id, 'resume'), 'POST', {}),
      cancel: (id: string) => request<JobWebhook>(idPath('webhooks', id, 'cancel'), 'POST', {}),
      delete: (id: string) => request<JobWebhook>(idPath('webhooks', id), 'DELETE')
    }
  }
}
