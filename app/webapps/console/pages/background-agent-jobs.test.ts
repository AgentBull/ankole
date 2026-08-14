import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryObserver } from '@tanstack/react-query'
import type { BackgroundAgentJobListItem } from '../api/generated/types.gen'
import { backgroundAgentJobListOptions, backgroundAgentJobScopeParams } from './background-agent-jobs'

describe('Background Agent Job scope changes', () => {
  test('does not retain rows from the previous Agent while the next scope loads', () => {
    const queryClient = new QueryClient()
    const first = backgroundAgentJobListOptions('agent-a')
    const second = backgroundAgentJobListOptions('agent-b')
    const previousJob: BackgroundAgentJobListItem = {
      agent_uid: 'agent-a',
      attempts: 0,
      duration_seconds: 0,
      execution_failures: 0,
      id: 1000,
      inserted_at: '2026-08-14T00:00:00Z',
      status: 'queued',
      title: 'Agent A job',
      workspace_template_id: null
    }
    queryClient.setQueryData(first.queryKey, { jobs: [previousJob], next_cursor: null })

    const observer = new QueryObserver(queryClient, { ...first, enabled: false })
    expect(observer.getCurrentResult().data).toEqual({ jobs: [previousJob], next_cursor: null })

    observer.setOptions({ ...second, enabled: false })
    expect(observer.getCurrentResult().data).toBeUndefined()
    expect(observer.getCurrentResult().isPlaceholderData).toBe(false)
  })

  test('closes the previous Agent detail when the scope changes', () => {
    const selected = backgroundAgentJobScopeParams(new URLSearchParams('agent=agent-a&job=1000'), 'agent-b')
    expect(selected.toString()).toBe('agent=agent-b')

    const allAgents = backgroundAgentJobScopeParams(new URLSearchParams('agent=agent-a&job=1000'), '')
    expect(allAgents.toString()).toBe('')
  })
})
