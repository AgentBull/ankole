import { podKeys } from './api'
import { podIssue, podIssues, podScheduledWork } from './api/generated/sdk.gen'
import type { PodIssueResponse } from './api/generated/types.gen'

/** A room that has an Issue, or a room in which a Background Agent Job or Workflow is live. */
export type WorkItem = PodIssueResponse

/** The board's columns, in the order in which work moves through them. */
export const workStatuses = ['todo', 'working', 'waiting', 'review', 'done'] as const
export type WorkStatus = (typeof workStatuses)[number]

/*
 * Every Work query lives under the conversations key. An Issue is a room, so the Pod's `conversations_changed`
 * event, which follows each committed message, run, and Issue change, refreshes the board without another channel.
 */
export const workKeys = {
  get all() {
    return [...podKeys.conversations, 'work'] as const
  },
  get items() {
    return [...workKeys.all, 'items'] as const
  },
  item: (id: string) => [...workKeys.all, 'item', id] as const,
  get scheduled() {
    return [...workKeys.all, 'scheduled'] as const
  }
}

export const workItemsQuery = {
  queryKey: workKeys.items,
  queryFn: async ({ signal }: { signal: AbortSignal }) => (await podIssues({ signal })).issues
}

export const workItemQuery = (id: string) => ({
  queryKey: workKeys.item(id),
  queryFn: ({ signal }: { signal: AbortSignal }) => podIssue({ path: { id }, signal })
})

export const scheduledWorkQuery = {
  queryKey: workKeys.scheduled,
  queryFn: async ({ signal }: { signal: AbortSignal }) => (await podScheduledWork({ signal })).schedules,
  // A rule that fires quietly posts no message, so its next time is read again while the list stays open.
  refetchInterval: 60_000
}
