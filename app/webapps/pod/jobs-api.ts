import i18n from '../common/i18n'
import { InternalAPIError } from '../common/internal-api-client'
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
 * while the full `/jobs` board query mounts only while `/jobs` is open.
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
