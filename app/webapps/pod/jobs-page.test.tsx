import { SidebarProvider } from '@ankole/uikit'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import { stripBidi } from '../common/bidi'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { coalesceMatchesBinding } from './connector-event-picker'
import { JobCreateFormContent } from './job-create-dialog'
import type { ConversationExecutionDetail } from './chat/types'
import { jobsKeys, resultPageLink, type JobBoardItem, type JobCandidateAgent, type JobRoutineDetail } from './jobs-api'
import { JobsRoute } from './jobs-page'
import {
  buildRoutineUpdatePayload,
  RoutineEventTriggersSection,
  RoutineInlineEditForm,
  routineHasSchedule
} from './jobs-routine-editor'
import { connectorKeys } from './state/connectors'
import { JobCreateFormModel, resolveJobCandidateAgent } from './state/job-create-form'

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
  expect(clean).toContain('1 needs attention')
  expect(clean).toContain('0 9 * * 1-5')
  expect(clean).toContain('12 steps · +2')
  expect(clean).toContain('Needs input')

  // Attention card (`Blocked deployment job`) is rendered ahead of `Normal running indexing job` with warning tone.
  expect(html.indexOf('Blocked deployment job')).toBeLessThan(html.indexOf('Normal running indexing job'))
  expect(html).toContain('data-tone="warning"')
})

test('cards surface summary snippets and determinate plan progress bars, and URL search/filters narrow the board', async () => {
  const items: JobBoardItem[] = [
    makeItem({
      id: 'job:50',
      rawID: '50',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'running',
      status: 'running',
      title: 'Synthesize Q4 revenue signals',
      summary: 'Cross-checking regional cohorts against CRM exports.',
      planCompleted: 3,
      planTotal: 5,
      chainLength: 2
    }),
    makeItem({
      id: 'job:51',
      rawID: '51',
      kind: 'workflow',
      cardType: 'one_off',
      column: 'running',
      status: 'failed',
      title: 'Broken ingestion pipeline',
      summary: 'Upstream S3 bucket returned 403.',
      attention: true,
      attentionReason: 'failed',
      agentUID: 'ops-bot',
      agentName: 'Ops Colleague'
    })
  ]

  const fullHtml = await renderJobsAt('/jobs', client => {
    client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
  })
  expect(fullHtml).toContain('Cross-checking regional cohorts against CRM exports.')
  expect(fullHtml).toContain('data-slot="board-card-progress"')
  expect(fullHtml).toContain('>3/5 · +1</span>')
  expect(fullHtml).toContain('data-tone="danger"')

  const searchedHtml = await renderJobsAt('/jobs?q=cohorts', client => {
    client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
  })
  expect(searchedHtml).toContain('Synthesize Q4 revenue signals')
  expect(searchedHtml).not.toContain('Broken ingestion pipeline')
  expect(searchedHtml).toContain('No scheduled routines')
  expect(searchedHtml).toContain('No completed jobs yet')

  const emptyFilteredHtml = await renderJobsAt('/jobs?q=nonexistent-keyword&kind=cron', client => {
    client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
  })
  expect(emptyFilteredHtml).toContain('No jobs match the current search or filters.')
  expect(emptyFilteredHtml).toContain('Clear filters')
})

const TODO_PAGE_ID = '019a2b00-0000-7000-8000-000000000071'

test('the Running header counts healthy runs apart from attention items, and a finished card writes its outcome as plain text', async () => {
  const failed = (id: number) =>
    makeItem({
      id: `job:${id}`,
      rawID: String(id),
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'running',
      status: 'failed',
      title: 'Build the todo Applet',
      attention: true,
      attentionReason: 'failed'
    })
  const items = [
    failed(61),
    failed(62),
    failed(63),
    makeItem({
      id: 'job:64',
      rawID: '64',
      kind: 'background_agent_job',
      cardType: 'one_off',
      column: 'completed',
      status: 'succeeded',
      title: 'Build the todo Applet',
      summary: `**Done.** Published [Todo list](ankole:page/${TODO_PAGE_ID}) for the team.`
    })
  ]

  const html = stripBidi(
    await renderJobsAt('/jobs', client => {
      client.setQueryData(jobsKeys.board, { items, agents: sampleAgents })
    })
  )

  expect(html).toMatch(/Running<\/span><span[^>]*>0<\/span>/)
  expect(html).toContain('>Needs attention 3</span>')
  expect(html).toContain('Done. Published Todo list for the team.')
  expect(html).not.toContain('ankole:page/')
  // The deliverable opens from the detail panel's title, so the card stays as the design draws it.
  expect(html).not.toContain('Open Todo list')
})

test('a failed execution leads with what to do next and keeps the raw diagnostic behind Technical details', async () => {
  const card = makeItem({
    id: 'job:61',
    rawID: '61',
    kind: 'background_agent_job',
    cardType: 'one_off',
    column: 'running',
    status: 'failed',
    title: 'Build the todo Applet',
    attention: true,
    attentionReason: 'failed'
  })
  const detail: ConversationExecutionDetail = {
    id: '61',
    kind: 'background_agent_job',
    title: 'Build the todo Applet',
    agentUID: 'pa-alice',
    status: 'failed',
    task: null,
    createdAt: '2026-11-15T07:00:00Z',
    startedAt: '2026-11-15T07:00:01Z',
    completedAt: '2026-11-15T07:00:52Z',
    updatedAt: '2026-11-15T07:00:52Z',
    stoppable: false,
    canMessage: false,
    continuedFromJobID: null,
    successorJobID: null,
    outcomeText: `Saved a first draft as [Todo list](ankole:page/${TODO_PAGE_ID}).`,
    errorText: 'getaddrinfo ENOTFOUND api.internal:443 (transport closed)',
    stepCount: 0,
    pendingQuestions: [],
    plan: null,
    threads: [],
    workflowCounts: null,
    items: [],
    nextCursor: null
  }

  const html = stripBidi(
    await renderJobsAt('/jobs?item=job%3A61', client => {
      client.setQueryData(jobsKeys.board, { items: [card], agents: sampleAgents })
      client.setQueryData(jobsKeys.execution('background_agent_job', '61'), { pages: [detail], pageParams: [null] })
    })
  )
  const t = i18n.getFixedT('en-US')

  expect(html).toContain(t('pod.chat_timeline.execution_failed_hint_with_result'))
  expect(html).toContain(t('pod.chat_timeline.execution_technical_details'))
  expect(html).not.toContain('ENOTFOUND')
  expect(html.indexOf('Open Todo list')).toBeGreaterThan(-1)
  expect(html.indexOf('Open Todo list')).toBeLessThan(html.indexOf('role="alert"'))
})

test('resultPageLink reads the first linked Pod Page and skips links without a valid Page', () => {
  expect(resultPageLink(`See [Q4 \\[Draft\\]](ankole:page/${TODO_PAGE_ID}) and [x](ankole:page/other)`)).toEqual({
    id: TODO_PAGE_ID,
    title: 'Q4 [Draft]'
  })
  expect(resultPageLink('[Broken](ankole:page/not-an-id)')).toBeUndefined()
  expect(resultPageLink('[Site](https://example.com) only')).toBeUndefined()
  expect(resultPageLink(null)).toBeUndefined()
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
  expect(html).toContain('Edit')
  expect(html).toContain('Remove')
  expect(html).toContain('Compile the nightly engineering digest and highlight regressions.')
  expect(html).toContain('Digest deep scan')
  expect(html).toContain('Delivered digest')
})

test('Routine inspector discloses long summaries via native <details>, flags delivery warnings, and shows linked Connector triggers', async () => {
  const routineCard = makeItem({
    id: 'cron:77',
    rawID: '77',
    kind: 'cron',
    cardType: 'routine',
    column: 'scheduled',
    status: 'active',
    title: 'CRM triage monitor',
    triggerSummary: '1 event trigger',
    summary: 'Checked 20 tickets, 0 anomalies.',
    manageable: true
  })

  const longSummary = [
    'Checked 25 incoming CRM tickets across EMEA and APAC queues.',
    'Escalated #4821 (SLA < 30m) and scheduled a 45m checkback on #4829.',
    'Remaining 23 tickets matched normal triage thresholds with zero customer impact.'
  ].join('\n')

  const routineDetail: JobRoutineDetail = {
    item: routineCard,
    instructions: 'Triage new CRM tickets and alert only when SLA intervention is required.',
    quietSuccess: true,
    unavailableReason: null,
    childExecutions: [],
    runs: [
      {
        id: 'run-short',
        status: 'completed',
        trigger: 'signal',
        startedAt: '2026-11-15T10:00:00Z',
        finishedAt: '2026-11-15T10:01:00Z',
        summary: 'Checked 20 tickets, 0 anomalies.',
        deliveryWarning: false,
        error: null
      },
      {
        id: 'run-long',
        status: 'completed',
        trigger: 'signal',
        startedAt: '2026-11-15T09:00:00Z',
        finishedAt: '2026-11-15T09:02:00Z',
        summary: longSummary,
        deliveryWarning: true,
        error: null
      }
    ]
  }

  const html = await renderJobsAt('/jobs?item=cron%3A77', client => {
    client.setQueryData(jobsKeys.board, { items: [routineCard], agents: sampleAgents })
    client.setQueryData(jobsKeys.routine('cron', '77'), routineDetail)
    client.setQueryData(jobsKeys.routineBindings('77'), {
      bindings: [
        {
          id: 'b-1',
          adapter: 'connector',
          agent_routine_id: '77',
          agent_uid: 'ops-bot',
          automation_job_id: null,
          config_ref: 'connector://conn-1/tickets',
          enabled: true,
          filters: {},
          coalesce: { enabled: true, window_ms: 5000, max_batch_size: 20 },
          name: 'CRM Tickets',
          routing_mode: 'ai_colleague',
          target: { kind: 'agent_routine', routine_id: '77' },
          unaddressed_group_message_policy: 'ignore',
          unavailable_reason: null,
          unmatched_sender_policy: 'manual_review',
          watched_field_ids: []
        }
      ]
    })
    client.setQueryData(connectorKeys.catalog, {
      can_manage: true,
      connectors: [
        {
          id: 'catalog-entry-zendesk',
          plugin_id: 'zendesk',
          event_streams: [{ id: 'tickets', label: 'Ticket stream', event_types: ['ticket.created'] }],
          trigger_types: []
        }
      ]
    })
    client.setQueryData(connectorKeys.triggers, { triggers: [] })
    client.setQueryData(connectorKeys.connections, {
      connections: [
        { id: 'conn-1', plugin_id: 'zendesk', slug: 'zendesk-prod', display_name: 'Zendesk Prod', status: 'active' }
      ]
    })
  })

  expect(html).toContain('<details')
  expect(html).toContain('<summary')
  expect(html).toContain('View full summary')
  expect(html).toContain('Remaining 23 tickets matched normal triage thresholds')
  expect(html).toContain('Notification not delivered')
  expect(html).toContain('Zendesk Prod · Ticket stream')
  expect(html).toContain('5s / 20')
  // Event-only Routine with a single active binding disables Disconnect so it cannot be stranded without triggers.
  expect(html).toMatch(/<button[^>]*\sdisabled=""[^>]*>Disconnect event<\/button>/)
})

test('event-only Routine edit form keeps schedule off while bindings are still loading and never injects a default cron', async () => {
  await loadLocale('en-US')
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false } }
  })

  const eventOnlyItem = makeItem({
    id: 'cron:88',
    rawID: '88',
    kind: 'cron',
    cardType: 'routine',
    column: 'scheduled',
    status: 'active',
    title: 'CRM triage monitor',
    triggerSummary: '1 event trigger',
    schedule: null,
    manageable: true
  })
  const detail: JobRoutineDetail = {
    item: eventOnlyItem,
    instructions: 'Watch incoming tickets and summarize SLA risks.',
    quietSuccess: true,
    unavailableReason: null,
    childExecutions: [],
    runs: []
  }

  // `jobRoutineBindingsQuery('88')` is intentionally left unseeded (pending) when the edit form mounts.
  const html = renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <RoutineInlineEditForm rawID="88" item={eventOnlyItem} detail={detail} onCancel={() => {}} onSaved={() => {}} />
      </QueryClientProvider>
    </I18nextProvider>
  )

  expect(routineHasSchedule(eventOnlyItem)).toBe(false)
  expect(html).not.toContain('name="expression"')
  expect(html).not.toContain('0 9 * * 1-5')

  expect(
    buildRoutineUpdatePayload({
      title: 'CRM SLA monitor',
      task: detail.instructions,
      quietSuccess: true,
      initialHasSchedule: routineHasSchedule(eventOnlyItem),
      hasSchedule: false,
      expression: '0 9 * * 1-5',
      timezone: 'UTC'
    })
  ).toEqual({
    title: 'CRM SLA monitor',
    task: 'Watch incoming tickets and summarize SLA risks.',
    quietSuccess: true
  })

  // Toggling off an existing schedule on a Hybrid Routine explicitly sends `removeSchedule: true`.
  expect(
    buildRoutineUpdatePayload({
      title: 'Hybrid monitor',
      task: detail.instructions,
      quietSuccess: false,
      initialHasSchedule: true,
      hasSchedule: false,
      expression: '0 9 * * 1-5',
      timezone: 'UTC'
    })
  ).toEqual({
    title: 'Hybrid monitor',
    task: 'Watch incoming tickets and summarize SLA risks.',
    quietSuccess: false,
    removeSchedule: true
  })
})

test('Hybrid Routine enables unlinking its event trigger, coalesce changes unlock in-place updates, and JobCreateFormModel derives late agents with ToggleGroup and CronEditor', async () => {
  await loadLocale('en-US')
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false } }
  })

  client.setQueryData(jobsKeys.routineBindings('90'), {
    bindings: [
      {
        id: 'b-90',
        adapter: 'connector',
        agent_routine_id: '90',
        agent_uid: 'ops-bot',
        automation_job_id: null,
        config_ref: 'connector://conn-1/tickets',
        enabled: true,
        filters: {},
        coalesce: { enabled: true, window_ms: 30_000, max_batch_size: 15 },
        name: 'CRM Tickets',
        routing_mode: 'ai_colleague',
        target: { kind: 'agent_routine', routine_id: '90' },
        unaddressed_group_message_policy: 'ignore',
        unavailable_reason: null,
        unmatched_sender_policy: 'manual_review',
        watched_field_ids: []
      }
    ]
  })
  client.setQueryData(connectorKeys.catalog, {
    can_manage: true,
    connectors: [
      {
        id: 'catalog-zendesk',
        plugin_id: 'zendesk',
        event_streams: [{ id: 'tickets', label: 'Ticket stream', event_types: ['ticket.created'] }],
        trigger_types: []
      }
    ]
  })
  client.setQueryData(connectorKeys.triggers, { triggers: [] })
  client.setQueryData(connectorKeys.connections, {
    connections: [
      { id: 'conn-1', plugin_id: 'zendesk', slug: 'zendesk-prod', display_name: 'Zendesk Prod', status: 'active' }
    ]
  })

  const rootRoute = createRootRoute({
    component: () => <RoutineEventTriggersSection rawID="90" manageable hasSchedule />
  })
  const router = createRouter({ routeTree: rootRoute, history: createMemoryHistory({ initialEntries: ['/'] }) })
  await router.load()

  const hybridTriggersHtml = renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </I18nextProvider>
  )

  expect(hybridTriggersHtml).toContain('>Disconnect event</button>')
  expect(hybridTriggersHtml).not.toMatch(/<button[^>]*\sdisabled=""[^>]*>Disconnect event<\/button>/)
  expect(hybridTriggersHtml).toContain('value="30"')
  expect(hybridTriggersHtml).toContain('value="15"')
  expect(
    coalesceMatchesBinding(
      { enabled: true, window_ms: 30_000, max_batch_size: 15 },
      { enabled: true, window_ms: 30_000, max_batch_size: 15 }
    )
  ).toBe(true)
  expect(
    coalesceMatchesBinding(
      { enabled: true, window_ms: 30_000, max_batch_size: 15 },
      { enabled: true, window_ms: 10_000, max_batch_size: 15 }
    )
  ).toBe(false)

  // Opening JobCreateFormModel before `agents` arrive leaves `agentUID` empty, and `resolveJobCandidateAgent` derives `agents[0]` once loaded.
  const form = new JobCreateFormModel({ mode: 'cron', title: 'Hourly sweep', task: 'Inspect queue' }, [])
  expect(form.agentUID.value).toBe('')
  expect(resolveJobCandidateAgent(sampleAgents, form.agentUID.value)?.uid).toBe('pa-alice')

  const formHtml = renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <JobCreateFormContent
          agents={sampleAgents}
          preset={{ mode: 'cron', title: 'Hourly sweep', task: 'Inspect queue' }}
          onClose={() => {}}
          onCreated={() => {}}
        />
      </QueryClientProvider>
    </I18nextProvider>
  )
  expect(formHtml).toContain('data-slot="toggle-group"')
  expect(formHtml).not.toContain('type="radio"')
  expect(formHtml).toContain('0 9 * * 1-5')
  expect(formHtml).toContain('>Create schedule</button>')
  expect(formHtml).not.toMatch(/<button type="submit"[^>]*\sdisabled=/)
})
