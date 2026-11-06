import { expect, test } from '@playwright/test'

test('a chart owns one rendered surface across mount and resize', async ({ page }) => {
  const pageErrors: string[] = []
  page.on('pageerror', err => pageErrors.push(err.message))

  await page.goto('/integration/chart-recovery/index.html')
  const chart = page.getByRole('img', { name: 'Sales chart' })
  await expect(chart.locator('svg').first()).toBeVisible()
  await page.setViewportSize({ width: 900, height: 700 })
  await expect(chart.locator('svg')).toHaveCount(1)
  expect(pageErrors).toEqual([])
})

test('canvas statistical charts render pixels with legends across pie, donut, column, funnel, sunburst, theme switches, and export', async ({
  page
}) => {
  const pageErrors: string[] = []
  page.on('pageerror', err => pageErrors.push(err.message))

  await page.goto('/integration/chart-recovery/index.html')
  const statusChart = page.getByRole('img', { name: 'Interactive status chart' })
  await expect(statusChart.locator('canvas')).toHaveCount(1)

  const countNonBgPixels = async () =>
    statusChart.locator('canvas').evaluate((canvas: HTMLCanvasElement) => {
      const ctx = canvas.getContext('2d')
      if (!ctx || canvas.width === 0 || canvas.height === 0) return 0
      const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data
      const r0 = data[0] ?? 0
      const g0 = data[1] ?? 0
      const b0 = data[2] ?? 0
      let diff = 0
      for (let i = 0; i < data.length; i += 16) {
        if (
          (data[i + 3] ?? 0) > 0 &&
          (Math.abs((data[i] ?? 0) - r0) > 5 ||
            Math.abs((data[i + 1] ?? 0) - g0) > 5 ||
            Math.abs((data[i + 2] ?? 0) - b0) > 5)
        ) {
          diff += 1
        }
      }
      return diff
    })

  // Wait for G2 enter animation to paint non-background pie + legend pixels, still owning exactly 1 canvas
  await expect.poll(countNonBgPixels, { timeout: 5000 }).toBeGreaterThan(200)
  await expect(statusChart.locator('canvas')).toHaveCount(1)

  // Click a rendered pie slice and verify drilldown datum preserves __groupIndex
  const box = await statusChart.locator('canvas').boundingBox()
  expect(box).not.toBeNull()
  await page.mouse.click(box!.x + box!.width * 0.56, box!.y + box!.height * 0.42)
  await expect(page.getByTestId('clicked-group')).toHaveText(/^(进行中:0|已完成:1)$/)

  // Switch across chart types rapidly and verify each paints cleanly on a single canvas
  for (const nextType of ['donut', 'column', 'line', 'funnel', 'sunburst'] as const) {
    await page.getByRole('button', { name: `Switch ${nextType}` }).click()
    await expect(statusChart.locator('canvas')).toHaveCount(1)
    await expect.poll(countNonBgPixels, { timeout: 5000 }).toBeGreaterThan(100)
  }

  // Toggle dark mode and verify canvas re-renders without errors or duplicate canvases
  await page.getByRole('button', { name: 'Toggle theme' }).click()
  await page.setViewportSize({ width: 960, height: 740 })
  await expect(statusChart.locator('canvas')).toHaveCount(1)
  await expect.poll(countNonBgPixels, { timeout: 5000 }).toBeGreaterThan(100)

  // Verify live SVG + PNG export on canvas-backed chart
  await page.getByRole('button', { name: 'Probe export' }).click()
  await expect(page.getByTestId('exported-info')).toContainText(':png:true')
  expect(pageErrors).toEqual([])
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
