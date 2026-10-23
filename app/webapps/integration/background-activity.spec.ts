import { expect, test, type Page } from '@playwright/test'
import type { BackgroundActivityWorkflowCall } from '../console/api/generated'

const observed_at = '2026-10-16T00:00:00Z'
const counts = { total: 1, queued: 0, running: 1, sleeping: 0, succeeded: 0, failed: 0, cancelled: 0 }
const owner = { agent_uid: 'agent-one', owner_session_id: 'conversation:owner' }
const job = {
  ...owner,
  id: 71,
  resource_kind: 'background_job',
  title: 'Waiting report job',
  status: 'waiting_on_user',
  source_signal_id: 'signal-job',
  attempts: 2,
  error_code: null,
  error_summary: 'Waiting for the approval answer',
  queued_at: observed_at,
  started_at: observed_at,
  updated_at: observed_at
}
const call = {
  ...owner,
  id: 81,
  resource_kind: 'workflow_call',
  run_id: 91,
  run_status: 'cancelled',
  run_title: 'Cancelled parent workflow',
  task_session_id: 'wf_task:81',
  label: 'Admitted call still running',
  status: 'running',
  sleep_note: null,
  wake_kind: null,
  wake_at: null,
  attention: false,
  attempts: 1,
  error_code: null,
  error_summary: null,
  run_error_code: 'revoked',
  run_error_summary: 'Parent access was revoked',
  updated_at: observed_at,
  run_counts: counts
} satisfies BackgroundActivityWorkflowCall
const run = {
  ...owner,
  id: 92,
  resource_kind: 'workflow_run',
  title: 'Running before calls exist',
  status: 'running',
  cleanup_pending: false,
  error_code: null,
  error_summary: null,
  inserted_at: observed_at,
  completed_at: null,
  updated_at: observed_at,
  counts: { ...counts, total: 0, running: 0 }
}
const automation = {
  ...owner,
  id: 101,
  resource_kind: 'automation_run',
  automation_job_id: 111,
  definition_status: 'cancelled',
  label: 'Cancelled definition with live execution',
  status: 'running',
  attempts: 2,
  attempt_id: 'attempt-running',
  error: 'Previous attempt disconnected',
  scheduled_event_id: 'signal-automation',
  started_at: observed_at,
  inserted_at: observed_at,
  updated_at: observed_at
}

async function home(page: Page, failures = false) {
  const requests: string[] = []
  let workflowDenied = failures
  await page.route('**/api/v1/**', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    requests.push(path + url.search)
    if (path.includes('/background-activities/')) {
      if (path.endsWith('/background-jobs')) {
        return route.fulfill({
          json: {
            observed_at,
            jobs: failures
              ? []
              : url.searchParams.has('cursor')
                ? [{ ...job, id: 72, title: 'Older live job' }]
                : [job],
            next_cursor: !failures && !url.searchParams.has('cursor') ? 'next-page' : null
          }
        })
      }
      if (path.endsWith('/workflow')) {
        if (workflowDenied) {
          return route.fulfill({ status: 403, json: { error: { code: 'forbidden', message: 'access denied' } } })
        }
        return route.fulfill({
          json: {
            observed_at,
            live_calls: [
              call,
              {
                ...call,
                id: 82,
                label: 'Sleeping approval call',
                status: 'sleeping',
                sleep_note: 'Waiting for operator confirmation',
                wake_kind: 'sleep',
                wake_at: observed_at,
                attention: true
              },
              {
                ...call,
                id: 83,
                label: 'Queued for Agent capacity',
                run_id: 94,
                run_status: 'running',
                run_title: 'Waiting for capacity',
                status: 'queued',
                wake_kind: 'agent_capacity',
                wake_at: observed_at,
                run_counts: { ...counts, queued: 1, running: 0 }
              }
            ],
            calls_next_cursor: null,
            runs: [
              run,
              {
                ...run,
                id: 93,
                title: 'Terminal run with cleanup work',
                status: 'cancelled',
                cleanup_pending: true,
                completed_at: observed_at
              }
            ],
            runs_next_cursor: null
          }
        })
      }
      if (failures) {
        return route.fulfill({
          status: 503,
          json: { error: { code: 'temporarily_unavailable', message: 'Read service unavailable' } }
        })
      }
      return route.fulfill({ json: { observed_at, runs: [automation], next_cursor: null } })
    }
    if (path.includes('readiness')) return route.fulfill({ json: { ready: true, provider: { complete: true } } })
    return route.fulfill({ json: { identity_providers: [{ enabled: true }], running_count: 0, queued_count: 0 } })
  })
  // A URL predicate, because the glob `**/api/v2/**` also matches the source modules of the v2 clients.
  await page.route(
    url => url.pathname.startsWith('/api/v2/'),
    async route => {
      if (new URL(route.request().url()).pathname !== '/api/v2/agents') return route.fulfill({ json: { data: [] } })
      return route.fulfill({
        json: {
          data: [
            {
              id: 'agent-one',
              type: 'agent',
              attributes: { display_name: 'Research Agent', handle: 'research', status: 'active' }
            },
            {
              id: 'agent-two',
              type: 'agent',
              attributes: { display_name: 'Operations Agent', handle: 'operations', status: 'active' }
            }
          ]
        }
      })
    }
  )
  return {
    requests,
    allowWorkflow: () => {
      workflowDenied = false
    }
  }
}

test('Home shows native activity relationships including cancelled parents and independent pagination', async ({
  page
}, testInfo) => {
  const server = await home(page)
  await page.goto('/console-home')
  const area = page.getByRole('region', { name: 'Background activity', exact: true })
  const jobs = area.getByRole('region', { name: 'Background Jobs', exact: true })
  const workflow = area.getByRole('region', { name: 'Workflow', exact: true })
  const automations = area.getByRole('region', { name: 'Automation runs', exact: true })
  await expect(jobs.getByText('Waiting report job', { exact: true })).toBeVisible()
  await expect(jobs.getByText('Waiting for user', { exact: true })).toBeVisible()
  await expect(jobs.getByRole('link', { name: 'Waiting report job' })).toHaveAttribute(
    'href',
    '/background-agent-jobs?job=71'
  )
  await expect(workflow.getByText('Admitted call still running', { exact: true })).toBeVisible()
  await expect(workflow.getByText(/Parent run #91 .*cancelled/i).first()).toBeVisible()
  await expect(workflow.getByText('Needs attention', { exact: true })).toBeVisible()
  await expect(workflow.getByText('Waiting for operator confirmation', { exact: true })).toBeVisible()
  await expect(workflow.getByText('Queued for Agent capacity', { exact: true })).toBeVisible()
  await expect(workflow.getByText(/^Sleeping until /)).toHaveCount(1)
  await expect(workflow.getByText('Running before calls exist', { exact: true })).toBeVisible()
  await expect(workflow.getByText('Terminal cleanup pending', { exact: true })).toBeVisible()
  await expect(automations.getByText(/Definition #111 .*cancelled/i)).toBeVisible()
  await expect(automations.getByText('Running', { exact: true })).toBeVisible()
  await expect(automations.getByText('Scheduled event: signal-automation', { exact: true })).toBeVisible()
  await expect(page.getByText('Running background Agent Jobs', { exact: true })).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('home-background-activity.png'), fullPage: true })
  const workflowReads = server.requests.filter(path => path.includes('/background-activities/workflow')).length
  await jobs.getByRole('button', { name: 'Next page' }).click()
  await expect(jobs.getByText('Older live job', { exact: true })).toBeVisible()
  expect(server.requests.filter(path => path.includes('/background-activities/workflow'))).toHaveLength(workflowReads)
  await jobs.getByRole('button', { name: 'Previous page' }).click()
  await expect(jobs.getByText('Waiting report job', { exact: true })).toBeVisible()
  await area.getByRole('combobox', { name: 'Agent', exact: true }).click()
  await page.getByRole('option', { name: 'Operations Agent', exact: true }).click()
  await expect
    .poll(() => server.requests.filter(path => path.includes('/agents/agent-two/background-activities/')).length)
    .toBe(3)
  expect(new URL(page.url()).searchParams.has('activity_jobs_cursor')).toBe(false)
})

test('Home distinguishes independent permission, loading failure and empty groups and retries only the failed group', async ({
  page
}) => {
  const server = await home(page, true)
  await page.goto('/console-home')
  const area = page.getByRole('region', { name: 'Background activity', exact: true })
  const jobs = area.getByRole('region', { name: 'Background Jobs', exact: true })
  const workflow = area.getByRole('region', { name: 'Workflow', exact: true })
  const automations = area.getByRole('region', { name: 'Automation runs', exact: true })
  await expect(jobs.getByText('No current activity in this group.', { exact: true })).toBeVisible()
  await expect(
    workflow.getByText('This group is not available with the current permissions.', { exact: true })
  ).toBeVisible()
  await expect(
    automations.getByText('This activity group could not be loaded. Retry to refresh its state.', { exact: true })
  ).toBeVisible()
  await expect(automations.getByText('No current activity in this group.', { exact: true })).not.toBeVisible()
  server.allowWorkflow()
  const jobsReads = server.requests.filter(path => path.includes('/background-activities/background-jobs')).length
  await workflow.getByRole('button', { name: 'Retry', exact: true }).click()
  await expect(workflow.getByText('Admitted call still running', { exact: true })).toBeVisible()
  expect(server.requests.filter(path => path.includes('/background-activities/background-jobs'))).toHaveLength(
    jobsReads
  )
})
