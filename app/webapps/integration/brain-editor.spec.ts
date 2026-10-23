import { expect, test, type Page, type Route } from '@playwright/test'
import type { BrainObjectPage } from '../console/api/generated/types.gen'

function object(slug: string): BrainObjectPage {
  return {
    slug,
    type: 'note',
    subtype: null,
    title: `Title ${slug}`,
    body: `Body ${slug}`,
    meta: {},
    effective_date: null,
    content_hash: `hash-${slug}`,
    editable: true,
    edit_block_reason: null,
    deleted: false,
    library_managed: false,
    rendered: '',
    tags: [],
    facts: [],
    takes: [],
    timelines: [],
    contradictions: [],
    links: { incoming: [], outgoing: [] }
  }
}

function summary(row: BrainObjectPage) {
  return {
    slug: row.slug,
    type: row.type,
    subtype: row.subtype ?? null,
    title: row.title,
    effective_date: row.effective_date ?? null,
    managed_by_source_id: null
  }
}

// A JSON:API generic action takes its arguments in `data`.
function writeBody(route: Route) {
  return (route.request().postDataJSON() as { data: BrainObjectPage & { expected_content_hash?: string } }).data
}

async function brain(page: Page) {
  const objects = new Map(['A', 'B'].map(slug => [slug, object(slug)]))
  const writes: Route[] = []
  const heldReads: Route[] = []
  const reads = new Map<string, number>()
  let holdSlug: string | undefined
  // Object writes, the list, and the versions are JSON:API v2 routes; the
  // object page and the type list are v1 read models.
  await page.route('**/api/v2/brain/**', async route => {
    const url = new URL(route.request().url())
    if (['POST', 'PATCH'].includes(route.request().method())) {
      writes.push(route)
      return
    }
    if (url.pathname.endsWith('/object-versions')) return route.fulfill({ json: { data: [] } })
    return route.fulfill({
      json: {
        data: [...objects.values()].map(row => ({
          id: row.slug,
          type: 'brain_object',
          attributes: { ...summary(row), deleted_at: null, updated_at: '2026-10-16T00:00:00Z' }
        }))
      }
    })
  })
  await page.route('**/api/v1/brain/**', async route => {
    const url = new URL(route.request().url())
    if (url.pathname.endsWith('/object-types')) return route.fulfill({ json: { types: ['note'] } })
    if (url.pathname.endsWith('/show')) {
      const slug = url.searchParams.get('slug')!
      reads.set(slug, (reads.get(slug) ?? 0) + 1)
      if (holdSlug === slug) {
        holdSlug = undefined
        heldReads.push(route)
        return
      }
      return route.fulfill({ json: { object: objects.get(slug) } })
    }
    return route.fallback()
  })
  return {
    writes,
    heldReads,
    reads,
    holdNextRead: (slug: string) => {
      holdSlug = slug
    },
    async complete(index: number, result: 'success' | 'error' | 'conflict' = 'success') {
      const route = writes[index]!
      if (result !== 'success') {
        return route.fulfill({
          status: result === 'conflict' ? 409 : 500,
          json: {
            errors: [{ code: result === 'conflict' ? 'content_hash_conflict' : 'late_failure', detail: 'Late failure' }]
          }
        })
      }
      const body = writeBody(route)
      const saved: BrainObjectPage = { ...object(body.slug), ...body, content_hash: `saved-${index}` }
      objects.set(saved.slug, saved)
      return route.fulfill({ status: route.request().method() === 'POST' ? 201 : 200, json: summary(saved) })
    }
  }
}

const source = (page: Page) => page.getByRole('textbox', { name: 'Body source', exact: true })
const title = (page: Page) => page.getByRole('textbox', { name: 'Title (required)', exact: true })
const save = (page: Page) => page.getByRole('button', { name: 'Save', exact: true })
const nav = (page: Page, name: string) =>
  page.getByRole('navigation', { name: 'Browser test navigation' }).getByRole('link', { name, exact: true })

async function settled(page: Page, status: 'success' | 'error') {
  await page.waitForFunction(
    expected =>
      (window as unknown as { testMutationStatuses: () => string[] }).testMutationStatuses().at(-1) === expected,
    status
  )
}

for (const result of ['success', 'error'] as const) {
  for (const returnToA of [false, true]) {
    test(`late ${result} from A cannot affect ${returnToA ? 'a new visit to A' : 'B'}`, async ({ page }) => {
      const server = await brain(page)
      await page.goto('/brain/objects/A/edit')
      await source(page).fill('Submitted A')
      await save(page).click()
      await expect.poll(() => server.writes.length).toBe(1)
      await nav(page, 'Edit B').click()
      await expect(source(page)).toHaveValue('Body B')
      if (returnToA) {
        await nav(page, 'Edit A').click()
        await expect(source(page)).toHaveValue('Body A')
      }
      const selected = returnToA ? 'A' : 'B'
      await source(page).fill(`New draft ${selected}`)
      const before = server.reads.get(selected) ?? 0
      await server.complete(0, result)
      await settled(page, result)
      if (result === 'success') await expect.poll(() => server.reads.get(selected) ?? 0).toBeGreaterThan(before)
      await expect(source(page)).toHaveValue(`New draft ${selected}`)
      await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible()
      await expect(page.locator('[data-sonner-toast]')).toHaveCount(0)
      await expect(page.getByText('Late failure', { exact: true })).toHaveCount(0)
      await expect(page).toHaveURL(new RegExp(`/brain/objects/${selected}/edit$`))
      await save(page).click()
      await expect.poll(() => server.writes.length).toBe(2)
      expect(writeBody(server.writes[1]!)).toMatchObject({
        slug: selected,
        body: `New draft ${selected}`,
        expected_content_hash: `hash-${selected}`
      })
      await server.complete(1)
    })
  }
}

for (const result of ['success', 'error'] as const) {
  test(`late create ${result} cannot navigate or clear a later new-object visit`, async ({ page }) => {
    const server = await brain(page)
    await page.goto('/brain/objects/new')
    await page.getByRole('textbox', { name: 'Slug (required)', exact: true }).fill('created-old')
    await title(page).fill('Old title')
    await source(page).fill('Old new-object draft')
    await save(page).click()
    await expect.poll(() => server.writes.length).toBe(1)
    await nav(page, 'Edit B').click()
    await expect(source(page)).toHaveValue('Body B')
    await nav(page, 'New object').click()
    await expect(page.getByRole('textbox', { name: 'Slug (required)', exact: true })).toBeVisible()
    await expect(title(page)).toHaveValue('')
    await title(page).fill('Separate title')
    await source(page).fill('Separate draft')
    await expect(source(page)).toHaveValue('Separate draft')
    await server.complete(0, result)
    await settled(page, result)
    await expect(source(page)).toHaveValue('Separate draft')
    await expect(title(page)).toHaveValue('Separate title')
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible()
    await expect(page.locator('[data-sonner-toast]')).toHaveCount(0)
    await expect(page.getByText('Late failure', { exact: true })).toHaveCount(0)
    await expect(page).toHaveURL(/\/brain\/objects\/new$/)
  })
}

test('a write that finishes after the editor unmounts still refreshes the actual list', async ({ page }) => {
  const server = await brain(page)
  await page.goto('/brain/objects/A/edit')
  await title(page).fill('Saved A from an old visit')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await nav(page, 'Object list').click()
  await expect(page.getByText('Title A', { exact: true })).toBeVisible()
  await server.complete(0)
  await settled(page, 'success')
  await expect(page.getByText('Saved A from an old visit', { exact: true })).toBeVisible()
  await expect(page.locator('[data-sonner-toast]')).toHaveCount(0)
  await expect(page).toHaveURL(/\/brain\/objects$/)
})

test('a save on the current editor acknowledges the draft and uses its new hash', async ({ page }) => {
  const server = await brain(page)
  await page.goto('/brain/objects/A/edit')
  await source(page).fill('Saved current draft')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await server.complete(0)
  await settled(page, 'success')
  await expect(page.locator('[data-sonner-toast]')).toContainText(/A.*saved\./)
  await expect(page.getByText('Unsaved changes', { exact: true })).toHaveCount(0)
  await source(page).fill('Next edit')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(writeBody(server.writes[1]!)).toMatchObject({
    slug: 'A',
    body: 'Next edit',
    expected_content_hash: 'saved-0'
  })
  await server.complete(1)
})

test('a current create still navigates to its saved object', async ({ page }) => {
  const server = await brain(page)
  await page.goto('/brain/objects/new')
  await page.getByRole('textbox', { name: 'Slug (required)', exact: true }).fill('created-current')
  await title(page).fill('Current create')
  await source(page).fill('Current body')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await server.complete(0)
  await expect(page).toHaveURL(/\/brain\/objects\/created-current$/)
  await expect(page.getByRole('heading', { name: 'Current create', exact: true })).toBeVisible()
})

test('late load-latest comparison cannot replace the hash of a later A visit', async ({ page }) => {
  const server = await brain(page)
  await page.goto('/brain/objects/A/edit')
  await source(page).fill('Conflicting A draft')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await server.complete(0, 'conflict')
  await settled(page, 'error')
  server.holdNextRead('A')
  await page.getByRole('button', { name: 'Load latest for comparison', exact: true }).click()
  await expect.poll(() => server.heldReads.length).toBe(1)
  await nav(page, 'Edit B').click()
  await page.getByRole('button', { name: 'Discard changes', exact: true }).click()
  await expect(source(page)).toHaveValue('Body B')
  await nav(page, 'Edit A').click()
  await expect(source(page)).toHaveValue('Body A')
  await source(page).fill('Later A draft')
  await server.heldReads[0]!.fulfill({
    json: { object: { ...object('A'), content_hash: 'obsolete-comparison', body: 'Old comparison' } }
  })
  await expect(source(page)).toHaveValue('Later A draft')
  await expect(page.getByText('Old comparison', { exact: true })).toHaveCount(0)
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(writeBody(server.writes[1]!)).toMatchObject({
    slug: 'A',
    body: 'Later A draft',
    expected_content_hash: 'hash-A'
  })
  await server.complete(1)
})

test('load-latest on the current editor updates only comparison and hash', async ({ page }) => {
  const server = await brain(page)
  await page.goto('/brain/objects/A/edit')
  await source(page).fill('Keep this draft')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await server.complete(0, 'conflict')
  await settled(page, 'error')
  server.holdNextRead('A')
  await page.getByRole('button', { name: 'Load latest for comparison', exact: true }).click()
  await expect.poll(() => server.heldReads.length).toBe(1)
  await server.heldReads[0]!.fulfill({
    json: { object: { ...object('A'), content_hash: 'latest-A', body: 'Remote comparison' } }
  })
  await expect(page.getByText('Remote comparison', { exact: true })).toBeVisible()
  await expect(source(page)).toHaveValue('Keep this draft')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(writeBody(server.writes[1]!)).toMatchObject({
    slug: 'A',
    body: 'Keep this draft',
    expected_content_hash: 'latest-A'
  })
  await server.complete(1)
})
