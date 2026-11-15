import { SidebarProvider } from '@ankole/uikit'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import { stripBidi } from '../common/bidi'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { jobsKeys, type JobBoardItem, type JobCandidateAgent, type JobRoutineDetail } from './jobs-api'
import { JobsRoute } from './jobs-page'

async function renderJobsAt(href: string, setup: (client: QueryClient) => void): Promise<string> {
  await loadLocale('en-US')
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false } }
  })
  setup(client)
  const rootRoute = createRootRoute({
    component: () => (
      <SidebarProvider>
        <JobsRoute />
      </SidebarProvider>
    )
  })
  const router = createRouter({
    routeTree: rootRoute,
    history: createMemoryHistory({ initialEntries: [href] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  return renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </I18nextProvider>
  )
}

const sampleAgents: JobCandidateAgent[] = [
  {
    uid: 'pa-alice',
    displayName: 'Alice Assistant',
    agentType: 'personal_assistant',
    canRunBackgroundJob: true,
    avatarURL: null
  },
  {
    uid: 'ops-bot',
    displayName: 'Ops Colleague',
    agentType: 'colleague',
    canRunBackgroundJob: true,
    avatarURL: null
  }
]

function makeItem(
  overrides: Partial<JobBoardItem> &
    Pick<JobBoardItem, 'id' | 'rawID' | 'kind' | 'cardType' | 'column' | 'status' | 'title'>
): JobBoardItem {
  return {
    agentUID: 'pa-alice',
    agentName: 'Alice Assistant',
    conversationID: null,
    conversationTitle: null,
    pageID: null,
    pageTitle: null,
    summary: null,
    attention: false,
    attentionReason: null,
    stoppable: false,
    manageable: false,
    canMessage: false,
    activeExecutionKind: null,
    activeExecutionID: null,
    stepCount: 0,
    chainLength: 1,
    planCompleted: null,
    planTotal: null,
    triggerSummary: null,
    timezone: null,
    nextRunAt: null,
    lastRunAt: null,
    lastRunStatus: null,
    schedule: null,
    createdAt: '2026-11-15T07:00:00Z',
    updatedAt: '2026-11-15T07:30:00Z',
    ...overrides
  }
}

test('empty Jobs board renders guided starter templates and New Job button', async () => {
  const html = await renderJobsAt('/jobs', client => {
    client.setQueryData(jobsKeys.board, { items: [], agents: sampleAgents })
  })

  expect(html).toContain('Jobs')
  expect(html).toContain('New Job')
  expect(html).toContain('No background jobs or routines yet')
  expect(html).toContain('Morning workspace briefing')
  expect(html).toContain('Deep research &amp; synthesis')
  expect(html).toContain('Hourly status check')
})

test('status board renders 3 columns, pins attention items at the top of Running, and folds chains', async () => {
  const items: JobBoardItem[] = [
    makeItem({
      id: 'cron:10',
      rawID: '10',
      kind: 'cron',
      cardType: 'routine',
      column: 'scheduled',
      status: 'active',
      title: 'Weekday briefing',
      triggerSummary: '0 9 * * 1-5',
      manageable: true
    }),
    makeItem({
      id: 'job:20',
      rawID: '20',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'running',
      status: 'running',
      title: 'Normal running indexing job',
      stoppable: true,
      activeExecutionKind: 'background_agent_job',
      activeExecutionID: '20',
      stepCount: 12,
      chainLength: 3
    }),
    makeItem({
      id: 'job:21',
      rawID: '21',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'running',
      status: 'waiting_on_user',
      title: 'Blocked deployment job',
      attention: true,
      attentionReason: 'waiting_on_user',
      canMessage: true
    }),
    makeItem({
      id: 'job:30',
      rawID: '30',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'completed',
      status: 'succeeded',
      title: 'Completed quarterly audit',
      agentUID: 'ops-bot',
      agentName: 'Ops Colleague'
    })
  ]

  const html = await renderJobsAt('/jobs', client => {
    client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
  })

  const clean = stripBidi(html)
  expect(clean).toContain('Scheduled')
  expect(clean).toContain('Running')
  expect(clean).toContain('Completed')
  expect(clean).toContain('Alice Assistant working')
  expect(clean).toContain('0 9 * * 1-5')
  expect(clean).toContain('12 steps · +2')
  expect(clean).toContain('Needs input')

  // Attention card (`Blocked deployment job`) is rendered ahead of `Normal running indexing job`.
  expect(html.indexOf('Blocked deployment job')).toBeLessThan(html.indexOf('Normal running indexing job'))
})

test('By Agent view groups jobs per Agent and separates Page automations', async () => {
  const items: JobBoardItem[] = [
    makeItem({
      id: 'job:1',
      rawID: '1',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'running',
      status: 'running',
      title: 'Assistant task',
      agentUID: 'pa-alice',
      agentName: 'Alice Assistant'
    }),
    makeItem({
      id: 'automation:99',
      rawID: '99',
      kind: 'automation_job',
      cardType: 'routine',
      column: 'scheduled',
      status: 'active',
      title: 'Sync CRM rows',
      agentUID: null,
      agentName: null,
      pageID: '019a2b00-0000-7000-8000-000000000099',
      pageTitle: 'CRM Sync Applet',
      triggerSummary: 'Every 15m'
    })
  ]

  const html = await renderJobsAt('/jobs?view=agent', client => {
    client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
  })

  expect(html).toContain('Alice Assistant')
  expect(html).toContain('Ops Colleague')
  expect(html).toContain('Page automations')
  expect(html).toContain('Sync CRM rows')
})

test('selecting a Cron routine card opens the Routine inspector beside the board', async () => {
  const cronCard = makeItem({
    id: 'cron:42',
    rawID: '42',
    kind: 'cron',
    cardType: 'routine',
    column: 'scheduled',
    status: 'active',
    title: 'Nightly digest',
    triggerSummary: '0 22 * * *',
    timezone: 'Asia/Shanghai',
    manageable: true,
    conversationID: '019a2b00-0000-7000-8000-000000000042'
  })

  const routineDetail: JobRoutineDetail = {
    item: cronCard,
    instructions: 'Compile the nightly engineering digest and highlight regressions.',
    quietSuccess: true,
    unavailableReason: null,
    childExecutions: [
      {
        id: '501',
        kind: 'background_agent_job',
        title: 'Digest deep scan',
        status: 'succeeded',
        summary: 'All suites green',
        startedAt: '2026-11-14T14:00:00Z',
        completedAt: '2026-11-14T14:04:00Z',
        createdAt: '2026-11-14T14:00:00Z'
      }
    ],
    runs: [
      {
        id: 'run-1',
        status: 'completed',
        trigger: 'cron',
        startedAt: '2026-11-14T14:00:00Z',
        finishedAt: '2026-11-14T14:05:00Z',
        summary: 'Delivered digest',
        error: null
      }
    ]
  }

  const html = await renderJobsAt('/jobs?item=cron%3A42', client => {
    client.setQueryData(jobsKeys.board, { items: [cronCard], agents: sampleAgents })
    client.setQueryData(jobsKeys.routine('cron', '42'), routineDetail)
  })

  expect(html).toContain('Run now')
  expect(html).toContain('Pause')
  expect(html).toContain('Remove')
  expect(html).toContain('Compile the nightly engineering digest and highlight regressions.')
  expect(html).toContain('Digest deep scan')
  expect(html).toContain('Delivered digest')
})
