import type { TFunction } from 'i18next'
import i18n from '../common/i18n'
import { InternalAPIError } from '../common/internal-api-client'
import { podRouteID } from '../common/pod-url'
import { requestErrorCode } from '../common/request-errors'
import { chatError, podKeys } from './api'
import { podEventBindings, podJobRoutine, podJobs, podJobsSummary } from './api/generated/sdk.gen'
import type { PodJobRoutineResponse, PodJobsResponse } from './api/generated/types.gen'

export type JobBoardItem = PodJobsResponse['items'][number]
export type JobCandidateAgent = PodJobsResponse['agents'][number]
export type JobColumn = JobBoardItem['column']
export type JobRoutineKind = 'cron' | 'automation_job' | 'checkback'
export type JobRoutineDetail = PodJobRoutineResponse

export const jobColumns = ['scheduled', 'running', 'completed'] as const

/*
 * Jobs queries live under `podKeys.conversations` so Pod's realtime `conversations_changed`
 * event refreshes the lightweight sidebar summary automatically without an extra channel,
 * while the full board query mounts only on `/jobs` and on the Pod home, which share its cache.
 */
export const jobsKeys = {
  get all() {
    return [...podKeys.conversations, 'jobs'] as const
  },
  get summary() {
    return [...jobsKeys.all, 'summary'] as const
  },
  get board() {
    return [...jobsKeys.all, 'board'] as const
  },
  routine: (kind: JobRoutineKind, rawID: string) => [...jobsKeys.all, 'routine', kind, rawID] as const,
  routineBindings: (rawID: string) => [...jobsKeys.all, 'routine-bindings', rawID] as const,
  execution: (kind: 'background_agent_job' | 'workflow', runID: string) =>
    [...jobsKeys.all, 'execution', kind, runID] as const
}

export const jobRoutineBindingsQuery = (rawID: string) => ({
  queryKey: jobsKeys.routineBindings(rawID),
  queryFn: ({ signal }: { signal: AbortSignal }) => podEventBindings({ query: { routine_id: rawID }, signal }),
  retry: false
})

export const jobsSummaryQuery = {
  queryKey: jobsKeys.summary,
  queryFn: ({ signal }: { signal: AbortSignal }) => podJobsSummary({ signal })
}

export const jobsBoardQuery = {
  queryKey: jobsKeys.board,
  queryFn: ({ signal }: { signal: AbortSignal }) => podJobs({ signal }),
  refetchInterval: 30_000
}

export const jobRoutineQuery = (kind: JobRoutineKind, rawID: string) => ({
  queryKey: jobsKeys.routine(kind, rawID),
  queryFn: ({ signal }: { signal: AbortSignal }) => podJobRoutine({ path: { kind, raw_id: rawID }, signal }),
  retry: false
})

/** An attention item that a person's answer or instruction unblocks; every other attention item is a failure. */
export function jobNeedsAnswer(item: JobBoardItem): boolean {
  return item.status === 'waiting_on_user' || item.status === 'incomplete'
}

export function jobAttentionLabel(item: JobBoardItem, t: TFunction): string {
  if (item.status === 'waiting_on_user') return t('pod.chat_timeline.execution_waiting_user')
  if (item.status === 'incomplete') return t('pod.chat_timeline.execution_incomplete')
  if (item.status === 'unavailable') return t('pod.jobs.status_unavailable')
  return t('pod.jobs.attention_failed')
}

const PAGE_LINK = /\[((?:\\.|[^\]\\])+)\]\(ankole:page\/([^)\s]+)\)/

/** The first Pod Page an Agent linked in its result, which Pod offers as the run's deliverable. */
export function resultPageLink(markdown?: string | null): { id: string; title: string } | undefined {
  const match = markdown ? PAGE_LINK.exec(markdown) : null
  const id = podRouteID(match?.[2])
  const title = match?.[1]?.replace(/\\(.)/g, '$1').trim()
  return id && title ? { id, title } : undefined
}

export function jobsError(error: unknown): unknown {
  const payload = error instanceof InternalAPIError ? error.payload : error
  const raw = payload && typeof payload === 'object' && 'error' in payload ? payload.error : undefined
  const code = requestErrorCode(payload) ?? (typeof raw === 'string' ? raw : undefined)
  if (code) {
    const jobKey = `pod.jobs.errors.${code}`
    if (i18n.exists(jobKey)) return new Error(i18n.t(jobKey))
  }
  return chatError(error)
}
