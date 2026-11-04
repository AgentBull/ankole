import type { ActionRun, PodAPI } from './types'

export type AppletJob = {
  id: number
  page_id: string
  action_key: string
  label: string
  authorization_kind: 'human' | 'service'
  human_uid: string | null
  status: 'active' | 'cancelled'
  config: Record<string, unknown>
}

/** Published Action discovery, Job configuration, and its latest 100 Runs. */
export function createAppletJobs(pod: PodAPI, pageID: string) {
  const root = `/pages/${encodeURIComponent(pageID)}`
  return {
    actions: async () => (await pod.request<{ actions: string[] }>(`${root}/job-actions`)).actions,
    list: async () => (await pod.request<{ jobs: AppletJob[] }>(`${root}/jobs`)).jobs,
    create: async (input: {
      action_key: string
      label?: string
      authorization_kind?: AppletJob['authorization_kind']
      config?: Record<string, unknown>
    }) => (await pod.request<{ job: AppletJob }>(`${root}/jobs`, 'POST', input)).job,
    configure: async (id: number, input: { label?: string; config?: Record<string, unknown> }) =>
      (await pod.request<{ job: AppletJob }>(`${root}/jobs/${id}`, 'PATCH', input)).job,
    delete: (id: number) => pod.request(`${root}/jobs/${id}`, 'DELETE'),
    runs: async (id: number) => (await pod.request<{ runs: ActionRun[] }>(`${root}/jobs/${id}/runs`)).runs
  }
}
