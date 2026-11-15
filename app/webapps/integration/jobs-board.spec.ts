import { expect, test, type Page } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { JobBoardItem, JobCandidateAgent, JobRoutineDetail } from '../pod/jobs-api'

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
  },
  {
    uid: 'research-bot',
    displayName: 'Research Analyst',
    agentType: 'colleague',
    canRunBackgroundJob: true,
    avatarURL: null
  }
]

const sampleItems: JobBoardItem[] = [
  {
    id: 'cron:10',
    rawID: '10',
    kind: 'cron',
    cardType: 'routine',
    column: 'scheduled',
    status: 'active',
    title: 'Morning workspace briefing',
    summary: 'Summarizes overnight pull requests, customer escalations, and calendar priorities before standup.',
    agentUID: 'pa-alice',
    agentName: 'Alice Assistant',
    conversationID: '019a2b00-0000-7000-8000-000000000010',
    conversationTitle: 'Daily Briefings',
    pageID: null,
    pageTitle: null,
    attention: false,
    attentionReason: null,
    stoppable: false,
    manageable: true,
    canMessage: false,
    activeExecutionKind: null,
    activeExecutionID: null,
    stepCount: 0,
    chainLength: 1,
    planCompleted: null,
    planTotal: null,
    triggerSummary: '0 9 * * 1-5',
    timezone: 'Asia/Shanghai',
    nextRunAt: '2026-11-16T01:00:00Z',
    lastRunAt: '2026-11-15T01:00:00Z',
    lastRunStatus: 'completed',
    schedule: { expression: '0 9 * * 1-5' },
    createdAt: '2026-11-01T00:00:00Z',
    updatedAt: '2026-11-15T01:02:00Z'
  },
  {
    id: 'automation:12',
    rawID: '12',
    kind: 'automation_job',
    cardType: 'routine',
    column: 'scheduled',
    status: 'active',
    title: 'Sync Enterprise CRM pipeline rows',
    summary: 'Mirrors closed-won renewals from Salesforce into the Revenue Base every 15 minutes.',
    agentUID: null,
    agentName: null,
    conversationID: null,
    conversationTitle: null,
    pageID: '019a2b00-0000-7000-8000-000000000099',
    pageTitle: 'CRM Sync Applet',
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
    triggerSummary: '*/15 * * * *',
    timezone: 'UTC',
    nextRunAt: '2026-11-15T15:45:00Z',
    lastRunAt: '2026-11-15T15:30:00Z',
    lastRunStatus: 'completed',
    schedule: { expression: '*/15 * * * *' },
    createdAt: '2026-11-05T00:00:00Z',
    updatedAt: '2026-11-15T15:30:00Z'
  },
  {
    id: 'job:21',
    rawID: '21',
    kind: 'background_agent_job',
    cardType: 'one_off',
    column: 'running',
    status: 'waiting_on_user',
    title: 'Approve staging schema migration plan',
    summary:
      'Prepared additive migration for tenant audit indexes; waiting on confirmation before applying to EU shard.',
    agentUID: 'ops-bot',
    agentName: 'Ops Colleague',
    conversationID: '019a2b00-0000-7000-8000-000000000021',
    conversationTitle: 'Infra Releases',
    pageID: null,
    pageTitle: null,
    attention: true,
    attentionReason: 'waiting_on_user',
    stoppable: false,
    manageable: false,
    canMessage: true,
    activeExecutionKind: 'background_agent_job',
    activeExecutionID: '21',
    stepCount: 6,
    chainLength: 1,
    planCompleted: 2,
    planTotal: 4,
    triggerSummary: null,
    timezone: null,
    nextRunAt: null,
    lastRunAt: null,
    lastRunStatus: null,
    schedule: null,
    createdAt: '2026-11-15T14:50:00Z',
    updatedAt: '2026-11-15T15:12:00Z'
  },
  {
    id: 'job:20',
    rawID: '20',
    kind: 'background_agent_job',
    cardType: 'one_off',
    column: 'running',
    status: 'running',
    title: 'Synthesize Q4 enterprise cohort retention',
    summary: 'Cross-checking regional usage telemetry against renewal contracts across 4 workspaces.',
    agentUID: 'research-bot',
    agentName: 'Research Analyst',
    conversationID: null,
    conversationTitle: null,
    pageID: null,
    pageTitle: null,
    attention: false,
    attentionReason: null,
    stoppable: true,
    manageable: false,
    canMessage: true,
    activeExecutionKind: 'background_agent_job',
    activeExecutionID: '20',
    stepCount: 14,
    chainLength: 2,
    planCompleted: 3,
    planTotal: 5,
    triggerSummary: null,
    timezone: null,
    nextRunAt: null,
    lastRunAt: null,
    lastRunStatus: null,
    schedule: null,
    createdAt: '2026-11-15T15:00:00Z',
    updatedAt: '2026-11-15T15:18:00Z'
  },
  {
    id: 'workflow:31',
    rawID: '31',
    kind: 'workflow',
    cardType: 'one_off',
    column: 'completed',
    status: 'succeeded',
    title: 'Weekly security & dependency audit',
    summary: 'Verified 18 packages and zero vulnerable transitive advisories across control plane and worker images.',
    agentUID: 'ops-bot',
    agentName: 'Ops Colleague',
    conversationID: null,
    conversationTitle: null,
    pageID: null,
    pageTitle: null,
    attention: false,
    attentionReason: null,
    stoppable: false,
    manageable: false,
    canMessage: false,
    activeExecutionKind: null,
    activeExecutionID: null,
    stepCount: 9,
    chainLength: 1,
    planCompleted: 4,
    planTotal: 4,
    triggerSummary: null,
    timezone: null,
    nextRunAt: null,
    lastRunAt: null,
    lastRunStatus: null,
    schedule: null,
    createdAt: '2026-11-15T11:00:00Z',
    updatedAt: '2026-11-15T11:14:00Z'
  },
  {
    id: 'job:32',
    rawID: '32',
    kind: 'background_agent_job',
    cardType: 'one_off',
    column: 'completed',
    status: 'succeeded',
    title: 'Draft release changelog for v2.8',
    summary: 'Compiled 12 merged pull requests into user-facing release notes and upgrade guidance.',
    agentUID: 'pa-alice',
    agentName: 'Alice Assistant',
    conversationID: null,
    conversationTitle: null,
    pageID: null,
    pageTitle: null,
    attention: false,
    attentionReason: null,
    stoppable: false,
    manageable: false,
    canMessage: false,
    activeExecutionKind: null,
    activeExecutionID: null,
    stepCount: 8,
    chainLength: 1,
    planCompleted: null,
    planTotal: null,
    triggerSummary: null,
    timezone: null,
    nextRunAt: null,
    lastRunAt: null,
    lastRunStatus: null,
    schedule: null,
    createdAt: '2026-11-15T09:00:00Z',
    updatedAt: '2026-11-15T09:20:00Z'
  }
]

const routineDetail: JobRoutineDetail = {
  item: sampleItems[0]!,
  instructions: 'Summarize overnight pull requests, customer escalations, and key decisions before 09:00 standup.',
  quietSuccess: true,
  unavailableReason: null,
  childExecutions: [
    {
      id: '501',
      kind: 'background_agent_job',
      title: 'Scan GitHub & Linear overnight updates',
      status: 'succeeded',
      summary: 'Collected 7 merged PRs and 2 P1 customer threads.',
      startedAt: '2026-11-15T01:00:00Z',
      completedAt: '2026-11-15T01:01:45Z',
      createdAt: '2026-11-15T01:00:00Z'
    }
  ],
  runs: [
    {
      id: 'run-101',
      status: 'completed',
      trigger: 'cron',
      startedAt: '2026-11-15T01:00:00Z',
      finishedAt: '2026-11-15T01:02:00Z',
      summary: 'Posted morning briefing to Daily Briefings room.',
      error: null
    },
    {
      id: 'run-100',
      status: 'completed',
      trigger: 'manual',
      startedAt: '2026-11-14T01:00:00Z',
      finishedAt: '2026-11-14T01:01:30Z',
      summary: 'No blockers overnight; quiet check completed.',
      error: null
    }
  ]
}

async function mountJobsHarness(
  page: Page,
  options: { items?: JobBoardItem[]; onStop?: (runID: string) => void } = {}
) {
  const boardItems = options.items ?? sampleItems

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alex',
        displayName: 'Alex Chen',
        tenant: { id: 'tenant-1', slug: 'acme', displayName: 'Acme Studio', avatarURL: null },
        canManagePod: true,
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.routeWebSocket('**/pod/socket/**', ws => {
    ws.onMessage(raw => {
      if (typeof raw !== 'string') return
      const [joinRef, ref, topic] = JSON.parse(raw) as [string | null, string | null, string, string]
      ws.send(
        JSON.stringify([
          joinRef,
          ref,
          topic,
          'phx_reply',
          {
            status: 'ok',
            response: {
              pages: [],
              path: [],
              can_create_space: true,
              can_create_private: true,
              conversations: [],
              entries: []
            }
          }
        ])
      )
    })
  })

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()
    if (url.pathname === '/api/v2/pod/jobs/summary') {
      return route.fulfill({
        json: {
          runningCount: boardItems.filter(item => item.column === 'running').length,
          attentionCount: boardItems.filter(item => item.attention).length,
          scheduledCount: boardItems.filter(item => item.column === 'scheduled').length
        }
      })
    }
    if (url.pathname === '/api/v2/pod/jobs') {
      return route.fulfill({ json: { items: boardItems, agents: sampleAgents } })
    }
    if (url.pathname === '/api/v2/pod/jobs/routines/cron/10') {
      return route.fulfill({ json: routineDetail })
    }
    const stopMatch = /^\/api\/v2\/pod\/jobs\/executions\/[^/]+\/(\d+)\/stop$/.exec(url.pathname)
    if (stopMatch && method === 'POST') {
      options.onStop?.(stopMatch[1]!)
      return route.fulfill({ json: { stopped: true } })
    }
    if (url.pathname === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'test-token', principal: { uid: 'alex', name: 'Alex Chen' } } })
    }
    if (url.pathname.endsWith('/directory-capabilities')) {
      return route.fulfill({ json: { principal_uid: 'alex', can_create_space: true, can_create_private: true } })
    }
    if (url.pathname.endsWith('/path')) {
      return route.fulfill({ json: { path: [] } })
    }
    if (url.pathname.endsWith('/children') || url.pathname === '/api/v2/pod/pages') {
      return route.fulfill({ json: { pages: [], can_create_space: true, can_create_private: true } })
    }
    if (url.pathname.endsWith('/attention')) return route.fulfill({ json: [] })
    if (url.pathname.endsWith('/agents')) {
      return route.fulfill({
        json: {
          agents: sampleAgents.map(agent => ({
            uid: agent.uid,
            displayName: agent.displayName,
            agentType: agent.agentType,
            avatarURL: agent.avatarURL
          }))
        }
      })
    }
    return route.fulfill({ json: { conversations: [], entries: [] } })
  })
}

test('Jobs kanban supports whole-card opening, independent Stop action, search/view switching, and quick column creation', async ({
  page
}) => {
  const stoppedRuns: string[] = []
  await page.setViewportSize({ width: 1440, height: 900 })
  await mountJobsHarness(page, { onStop: runID => stoppedRuns.push(runID) })

  await page.goto('/jobs')
  await expect(page.getByRole('heading', { name: 'Jobs' })).toBeVisible()
  await expect(page.getByText('Morning workspace briefing')).toBeVisible()
  await expect(page.getByText('1 needs attention')).toBeVisible()

  // Hovering a stoppable running card reveals Stop, and clicking Stop does NOT open the card's detail panel.
  const runningCard = page.locator('[data-slot="board-card"]', { hasText: 'Synthesize Q4 enterprise cohort retention' })
  await runningCard.hover()
  await runningCard.getByRole('button', { name: 'Stop' }).click()
  await expect.poll(() => stoppedRuns).toEqual(['20'])
  expect(new URL(page.url()).searchParams.get('item')).toBeNull()

  // Clicking anywhere on the card body (at the coordinates of its summary paragraph, outside the title text) opens the Routine inspector.
  const cronCard = page.locator('[data-slot="board-card"]', { hasText: 'Morning workspace briefing' })
  const descBox = await cronCard.locator('[data-slot="board-card-description"]').boundingBox()
  expect(descBox).not.toBeNull()
  await page.mouse.click(descBox!.x + descBox!.width / 2, descBox!.y + descBox!.height / 2)
  await expect.poll(() => new URL(page.url()).searchParams.get('item')).toBe('cron:10')
  await expect(page.getByText('Posted morning briefing to Daily Briefings room.')).toBeVisible()

  // Close inspector with Escape, switch to By Agent view, and verify quick-create preselects that Agent.
  await page.keyboard.press('Escape')
  await expect.poll(() => new URL(page.url()).searchParams.get('item')).toBeNull()

  await page.getByRole('tab', { name: 'By Agent' }).click()
  await expect.poll(() => new URL(page.url()).searchParams.get('view')).toBe('agent')
  await expect(page.getByRole('heading', { name: 'Page automations' })).toBeVisible()

  await page.getByRole('button', { name: /New job for .*Ops Colleague/ }).click()
  await expect(page.getByRole('dialog')).toContainText('Ops Colleague (@ops-bot)')
  await page.keyboard.press('Escape')

  // Switch back to status view and verify inline search filtering.
  await page.getByRole('tab', { name: 'By status' }).click()
  await page.getByRole('searchbox', { name: 'Search jobs…' }).fill('cohort')
  await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe('cohort')
  await expect(page.getByText('Synthesize Q4 enterprise cohort retention')).toBeVisible()
  await expect(page.getByText('Morning workspace briefing')).toHaveCount(0)
})

test('Empty Jobs board renders starter presets cleanly', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await mountJobsHarness(page, { items: [] })

  await page.goto('/jobs')
  await expect(page.getByText('No background jobs or routines yet')).toBeVisible()
  await expect(page.getByRole('button', { name: /Morning workspace briefing/i })).toBeVisible()
})
