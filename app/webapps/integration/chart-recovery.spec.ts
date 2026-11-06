import { expect, test } from '@playwright/test'

test('a chart owns one rendered surface across mount and resize', async ({ page }) => {
  await page.goto('/integration/chart-recovery/index.html')
  const chart = page.getByRole('img', { name: 'Sales chart' })
  await expect(chart.locator('svg').first()).toBeVisible()
  await page.setViewportSize({ width: 900, height: 700 })
  await expect(chart.locator('svg')).toHaveCount(1)
})

test('an infographic recovers when its author corrects invalid source', async ({ page }) => {
  await page.goto('/integration/chart-recovery/index.html')
  await expect(page.getByRole('alert')).toBeVisible()
  await page
    .getByLabel('Diagram source')
    .fill(
      [
        'infographic list-row-simple-horizontal-arrow',
        'data',
        '  title Recovery',
        '  items',
        '    - label First',
        '    - label Second'
      ].join('\n')
    )
  await expect(page.getByRole('alert')).toHaveCount(0)
  await expect(page.getByRole('img', { name: 'Infographic diagram' }).locator('svg').first()).toBeVisible()
})
