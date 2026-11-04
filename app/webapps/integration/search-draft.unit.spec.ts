import { expect, test } from '@playwright/test'

// Browser unit coverage: the real Console search control exercises the shared draft hook.
test('Console search typing is debounced and clearing restores cached results immediately', async ({ page }) => {
  const searches: string[] = []
  await page.route(
    url => url.pathname.startsWith('/api/v2/'),
    route => {
      const url = new URL(route.request().url())
      const query = url.searchParams.get('search') ?? ''
      if (url.pathname.endsWith('/brain/objects')) searches.push(query)
      return route.fulfill({
        json: {
          data: [{ id: 'object-1', attributes: { title: query ? `Results for ${query}` : 'All objects', type: 'doc' } }]
        }
      })
    }
  )
  await page.goto('/brain/objects')
  const input = page.getByRole('searchbox')
  await expect(input).toBeVisible()
  await expect.poll(() => searches.length).toBeGreaterThan(0)
  await page.clock.install()
  await input.fill('alpha')
  await page.clock.runFor(299)
  expect(searches).not.toContain('alpha')
  await page.clock.runFor(1)
  await expect.poll(() => searches.at(-1)).toBe('alpha')
  await input.fill('alpha beta')
  await page.clock.runFor(300)
  await expect.poll(() => searches.at(-1)).toBe('alpha beta')
  await expect(input).toHaveValue('alpha beta')
  await input.fill('')
  await expect(page.getByRole('cell', { name: 'All objects', exact: true })).toBeVisible()
  await expect(input).toHaveValue('')
})

// Hook unit coverage holds the URL echo, without replacing any production persistence adapter.
test('a delayed URL echo preserves newer typing while back and scope changes restore the query', async ({ page }) => {
  await page.goto('/integration/search-draft/index.html')
  const input = page.getByRole('textbox', { name: 'Search', exact: true })
  const submitted = page.getByRole('status', { name: 'Submitted', exact: true })
  await expect(input).toBeVisible()
  await page.clock.install()
  await input.fill('alpha')
  await page.clock.runFor(300)
  await expect(submitted).toHaveText('alpha')
  await input.fill('alpha beta')
  await expect(input).toHaveValue('alpha beta')
  await page.getByRole('button', { name: 'Accept URL echo' }).click()
  await expect(input).toHaveValue('alpha beta')
  await page.clock.runFor(300)
  await expect(submitted).toHaveText('alpha beta')
  await page.getByRole('button', { name: 'Accept URL echo' }).click()
  await page.getByRole('button', { name: 'Navigate back' }).click()
  await expect(input).toHaveValue('previous query')
  await input.fill('uncommitted input')
  await page.getByRole('button', { name: 'Change scope' }).click()
  await expect(input).toHaveValue('previous query')
  await page.clock.runFor(300)
  await expect(submitted).toHaveText('alpha beta')
})
