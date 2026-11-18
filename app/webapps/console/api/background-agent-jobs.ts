import { fromDocument, nextPageAfter } from './json-api'
import { getBackgroundAgentJobOptions, listBackgroundAgentJobsOptions } from './v2/generated/@tanstack/react-query.gen'
import type { GetBackgroundAgentJobResponse, ListBackgroundAgentJobsResponse } from './v2/generated/types.gen'

/** One page of Jobs. The Console keeps the integer Job id of the resource `id`. */
function jobsPage(document: ListBackgroundAgentJobsResponse) {
  return {
    jobs: fromDocument(document).map(job => ({ ...job, id: Number(job.id) })),
    nextAfter: nextPageAfter(document)
  }
}

function jobFromDocument(document: GetBackgroundAgentJobResponse) {
  const job = fromDocument(document)
  return { ...job, id: Number(job.id) }
}

export type BackgroundAgentJobListItem = ReturnType<typeof jobsPage>['jobs'][number]
export type BackgroundAgentJobItem = ReturnType<typeof jobFromDocument>

/** The query of one page of Jobs, newest first, with `{ jobs, nextAfter }` as its data. */
export function backgroundAgentJobsOptions({
  limit,
  ...filters
}: {
  agent_uid?: string
  search?: string
  status?: BackgroundAgentJobListItem['status']
  limit: number
}) {
  return { ...listBackgroundAgentJobsOptions({ query: { ...filters, page: { limit } } }), select: jobsPage }
}

/**
 * Whether a Job was queued at or after `since`. The Console home alert counts failed Jobs with this test, and the
 * board's `?since=` filter applies the same test, so both show one set. An empty or invalid `since` admits every Job.
 */
export function queuedSince(job: { queued_at?: string | null }, since: string | undefined): boolean {
  const start = Date.parse(since ?? '')
  return Number.isNaN(start) || Date.parse(job.queued_at ?? '') >= start
}

/** The query of one Job, with the flat record as its data. */
export function backgroundAgentJobOptions(id: number) {
  return { ...getBackgroundAgentJobOptions({ path: { id: String(id) } }), select: jobFromDocument }
}
