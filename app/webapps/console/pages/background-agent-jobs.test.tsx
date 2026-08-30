import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, QueryObserver } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { MemoryRouter } from 'react-router'
import type { BackgroundAgentJobListItem } from '../api/generated/types.gen'
import {
  BackgroundAgentJobsPage,
  backgroundAgentJobListOptions,
  backgroundAgentJobSearchParams,
  backgroundAgentJobScopeParams
} from './background-agent-jobs'

// Catalogs load on demand; these assertions render translated en-US copy.
beforeAll(() => loadLocale('en-US'))

describe('Background Agent Job scope changes', () => {
  test('renders one ID or name search beside the Agent filter', () => {
    const html = renderToStaticMarkup(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter initialEntries={['/background-agent-jobs']}>
          <BackgroundAgentJobsPage />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(html).toContain('aria-label="Search by Job ID or name"')
    expect(html).toContain('maxLength="200"')
    expect(html).toContain('aria-label="Agent"')
  })

  test('gives each server-side ID or name search its own query', () => {
    const allJobs = backgroundAgentJobListOptions('agent-a', '')
    const matchingJobs = backgroundAgentJobListOptions('agent-a', 'quarterly report')

    expect(matchingJobs.queryKey).not.toEqual(allJobs.queryKey)
  })

  test('keeps the committed search in the URL without dropping other page state', () => {
    const searched = backgroundAgentJobSearchParams(new URLSearchParams('agent=agent-a&job=1000'), 'quarterly report')
    expect(searched.toString()).toBe('agent=agent-a&job=1000&q=quarterly+report')

    const cleared = backgroundAgentJobSearchParams(searched, '')
    expect(cleared.toString()).toBe('agent=agent-a&job=1000')

    const normalized = backgroundAgentJobSearchParams(searched, '  release notes  ')
    expect(normalized.get('q')).toBe('release notes')

    const whitespace = backgroundAgentJobSearchParams(searched, '   ')
    expect(whitespace.toString()).toBe('agent=agent-a&job=1000')
  })

  test('announces the number of matching Jobs', () => {
    const queryClient = new QueryClient()
    const matchingJob: BackgroundAgentJobListItem = {
      agent_uid: 'agent-a',
      attempts: 0,
      duration_seconds: 0,
      execution_failures: 0,
      id: 1000,
      inserted_at: '2026-08-14T00:00:00Z',
      status: 'queued',
      title: 'Quarterly report',
      workspace_template_id: null
    }
    queryClient.setQueryData(backgroundAgentJobListOptions('', 'quarterly report').queryKey, {
      jobs: [matchingJob],
      next_cursor: null
    })

    const html = renderToStaticMarkup(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={['/background-agent-jobs?q=quarterly+report']}>
          <BackgroundAgentJobsPage />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(html).toContain('aria-live="polite"')
    expect(html).toContain('1 shown')
  })

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
