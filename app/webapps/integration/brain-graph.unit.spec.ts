import { expect, test, type Locator, type Page, type Route } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { MetaBrainResponse, PodAgentsResponse, PodPageNavigationResponse } from '../pod/api/generated/types.gen'

async function dragCanvasBy(graph: Locator, dx: number, dy: number) {
  await graph.evaluate(
    async (groupElement, delta) => {
      const canvases = Array.from(groupElement.querySelectorAll('canvas'))
      const canvas = canvases.find(element => element.style.pointerEvents !== 'none') ?? canvases[0]
      if (!canvas) throw new Error('Expected G6 main canvas element')
      const rect = canvas.getBoundingClientRect()
      const startX = rect.right - 64
      const startY = rect.bottom - 64
      const steps = 6
      canvas.dispatchEvent(
        new PointerEvent('pointerdown', {
          bubbles: true,
          cancelable: true,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: startX,
          clientY: startY
        })
      )
      // G6 configures `@antv/g-plugin-dragndrop` with `dragstartTimeThreshold: 100` ms,
      // and `DragCanvas` reads `PointerEvent.movementX`/`movementY` (which CDP `mouse.move` leaves at 0).
      await new Promise(resolve => window.setTimeout(resolve, 120))
      let prevX = startX
      let prevY = startY
      for (let i = 1; i <= steps; i++) {
        await new Promise(resolve => window.setTimeout(resolve, 25))
        const nextX = startX + Math.round((delta.dx * i) / steps)
        const nextY = startY + Math.round((delta.dy * i) / steps)
        canvas.dispatchEvent(
          new PointerEvent('pointermove', {
            bubbles: true,
            cancelable: true,
            pointerId: 1,
            pointerType: 'mouse',
            isPrimary: true,
            button: 0,
            buttons: 1,
            clientX: nextX,
            clientY: nextY,
            movementX: nextX - prevX,
            movementY: nextY - prevY
          })
        )
        prevX = nextX
        prevY = nextY
      }
      await new Promise(resolve => window.setTimeout(resolve, 25))
      canvas.dispatchEvent(
        new PointerEvent('pointerup', {
          bubbles: true,
          cancelable: true,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 0,
          clientX: prevX,
          clientY: prevY
        })
      )
    },
    { dx, dy }
  )
}

function mockPodSession(page: Page) {
  return page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'person',
        displayName: 'Person',
        canManagePod: false,
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )
}

/** Answers the Pod requests around the Brain page with an empty Pod. */
function fulfillEmptyPod(route: Route, path: string) {
  if (path.endsWith('/agents')) {
    return route.fulfill({
      json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
    })
  }
  if (path.endsWith('/pages/navigation')) {
    return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
  }
  return route.fulfill({
    json: path.endsWith('/conversations')
      ? { conversations: [], nextCursor: null }
      : path.startsWith('/api/v2/pod/pages')
        ? {
            pages: [],
            can_create_space: false,
            can_create_private: false,
            can_manage_space: false,
            next_cursor: null
          }
        : []
  })
}

async function anchorMetrics(link: Locator) {
  const box = await link.boundingBox()
  expect(box).not.toBeNull()
  return {
    cx: box!.x + box!.width / 2,
    cy: box!.y + box!.height / 2,
    width: box!.width,
    height: box!.height
  }
}

test('Brain graph keeps accessible node anchors synchronized across async load, pan, wheel zoom, and filtering', async ({
  page
}) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.setViewportSize({ width: 1365, height: 900 })
  await mockPodSession(page)

  let releaseBrain!: (route: Route) => void
  const brainGate = new Promise<Route>(resolve => {
    releaseBrain = resolve
  })

  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/meta/brain')) {
      releaseBrain(route)
      return
    }
    return fulfillEmptyPod(route, path)
  })

  // Mount `/meta/brain` before the graph payload resolves so `AnkoleGraph` binds G6 listeners while `nodes` is empty.
  await page.goto('/meta/brain?layout=hierarchy')
  const graph = page.getByRole('group', { name: 'Knowledge graph', exact: true })
  await expect(graph).toBeVisible({ timeout: 15_000 })
  await expect(graph.getByRole('link')).toHaveCount(0)

  const brainRoute = await brainGate
  await brainRoute.fulfill({
    json: {
      viewer_uid: 'person',
      assistant_uid: null,
      categories: [
        { id: 'cat-companies', name: 'companies', can_edit: false, entity_type: 'company', primitive: 'entity' },
        { id: 'cat-notes', name: 'notes', can_edit: false, entity_type: 'note', primitive: 'concept' }
      ],
      nodes: [
        { id: 'obj-acme', title: 'Acme Corp', slug: 'companies/acme', type: 'company', parent_id: 'cat-companies' },
        { id: 'obj-cloud', title: 'Acme Cloud', slug: 'companies/acme/cloud', type: 'project', parent_id: 'obj-acme' },
        { id: 'obj-memo', title: 'Quarterly Memo', slug: 'notes/q3-memo', type: 'note', parent_id: 'cat-notes' }
      ],
      links: [
        { from_page_id: 'obj-acme', to_page_id: 'obj-cloud', link_type: 'contains', relation_kind: 'hierarchy' },
        { from_page_id: 'obj-memo', to_page_id: 'obj-acme', link_type: 'references', relation_kind: 'reference' }
      ]
    } satisfies MetaBrainResponse
  })

  await expect(graph.getByRole('link')).toHaveCount(3)
  const acmeLink = graph.getByRole('link', { name: 'Acme Corp', exact: true })
  await expect(acmeLink).toBeVisible()

  // Close the top-left ontology layers card so canvas drag coordinates have full unobstructed space.
  await page.getByRole('button', { name: 'Ontology layers', exact: true }).click()

  const cloudLink = graph.getByRole('link', { name: 'Acme Cloud', exact: true })
  const beforePanAcme = await anchorMetrics(acmeLink)
  const beforePanCloud = await anchorMetrics(cloudLink)
  await dragCanvasBy(graph, 120, 80)

  await expect
    .poll(async () => {
      const currentAcme = await anchorMetrics(acmeLink)
      const currentCloud = await anchorMetrics(cloudLink)
      const acmeDx = Math.round(currentAcme.cx - beforePanAcme.cx)
      const acmeDy = Math.round(currentAcme.cy - beforePanAcme.cy)
      const cloudDx = Math.round(currentCloud.cx - beforePanCloud.cx)
      const cloudDy = Math.round(currentCloud.cy - beforePanCloud.cy)
      return acmeDx >= 45 && acmeDy >= 30 && Math.abs(acmeDx - cloudDx) <= 1 && Math.abs(acmeDy - cloudDy) <= 1
    })
    .toBe(true)

  // Wheel-zoom directly over the semantic `<a href>` anchor (forwards wheel to G6 `main` canvas and re-projects).
  const beforeZoom = await anchorMetrics(acmeLink)
  await page.mouse.move(beforeZoom.cx, beforeZoom.cy)
  await page.mouse.wheel(0, -480)
  await page.mouse.wheel(0, -480)

  await expect.poll(async () => (await anchorMetrics(acmeLink)).width).toBeGreaterThan(beforeZoom.width)

  // Filter by category first, fit view, then filter by search query, and verify subsequent canvas panning tracks the filtered anchor.
  await page.getByRole('combobox', { name: 'Ontology category', exact: true }).click()
  await page.getByRole('option', { name: 'companies', exact: true }).click()
  await page.getByRole('button', { name: 'Fit view', exact: true }).click()
  await expect(graph.getByRole('link')).toHaveCount(2)

  await page.getByRole('combobox', { name: 'Ontology category', exact: true }).click()
  await page.getByRole('option', { name: 'All categories', exact: true }).click()
  await page.getByLabel('Find knowledge', { exact: true }).fill('Quarterly Memo')
  await expect(graph.getByRole('link')).toHaveCount(1)
  const memoLink = graph.getByRole('link', { name: 'Quarterly Memo', exact: true })
  await expect(memoLink).toBeVisible()

  const beforeFilteredPan = await anchorMetrics(memoLink)
  await dragCanvasBy(graph, -120, 80)

  await expect
    .poll(async () => {
      const current = await anchorMetrics(memoLink)
      return Math.round(current.cx - beforeFilteredPan.cx) <= -45 && Math.round(current.cy - beforeFilteredPan.cy) >= 30
    })
    .toBe(true)
})

test('Brain network graph opens at rest and keeps its layout when a node is selected', async ({ page }) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await mockPodSession(page)
  // Each drawn frame paints every circular node with one `arc` call, so the count tells how many frames a change drew.
  await page.addInitScript(() => {
    const scope = window as typeof window & { brainArcCalls: number }
    scope.brainArcCalls = 0
    const arc = CanvasRenderingContext2D.prototype.arc
    CanvasRenderingContext2D.prototype.arc = function (...args: Parameters<typeof arc>) {
      scope.brainArcCalls++
      return arc.apply(this, args)
    }
  })
  const nodes = Array.from({ length: 24 }, (_, index) => ({
    id: `obj-${index}`,
    title: `Object ${index}`,
    slug: `notes/object-${index}`,
    type: 'note',
    parent_id: 'cat-notes'
  }))
  const links = nodes.slice(1).map((node, index) => ({
    from_page_id: nodes[index]!.id,
    to_page_id: node.id,
    link_type: 'references',
    relation_kind: 'reference'
  }))
  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (!path.endsWith('/meta/brain')) return fulfillEmptyPod(route, path)
    return route.fulfill({
      json: {
        viewer_uid: 'person',
        assistant_uid: null,
        categories: [{ id: 'cat-notes', name: 'notes', can_edit: false, entity_type: 'note', primitive: 'concept' }],
        nodes,
        links
      } satisfies MetaBrainResponse
    })
  })

  await page.goto('/meta/brain')
  const graph = page.getByRole('group', { name: 'Knowledge graph', exact: true })
  await expect(graph.getByRole('link')).toHaveCount(nodes.length, { timeout: 15_000 })
  const positions = async () =>
    Promise.all(
      nodes.map(async node => {
        const { cx, cy } = await anchorMetrics(graph.getByRole('link', { name: node.title, exact: true }))
        return [Math.round(cx), Math.round(cy)]
      })
    )

  // The anchors take the drawn viewport once the canvas finishes its entrance fade, then stay where the layout put
  // them; one second without movement means the graph is at rest.
  let settled = await positions()
  let quietReads = 0
  await expect
    .poll(
      async () => {
        const next = await positions()
        quietReads = JSON.stringify(next) === JSON.stringify(settled) ? quietReads + 1 : 0
        settled = next
        return quietReads
      },
      { intervals: [250], timeout: 10_000 }
    )
    .toBeGreaterThanOrEqual(4)

  // Focusing an anchor selects its node. Selection restyles the network layout in one frame instead of laying the graph
  // out again over about a hundred animated frames.
  await page.evaluate(() => {
    ;(window as typeof window & { brainArcCalls: number }).brainArcCalls = 0
  })
  await graph.getByRole('link', { name: 'Object 12', exact: true }).focus()
  for (let sample = 0; sample < 6; sample++) {
    await page.waitForTimeout(150)
    expect(await positions()).toEqual(settled)
  }
  const arcCalls = await page.evaluate(() => (window as typeof window & { brainArcCalls: number }).brainArcCalls)
  expect(arcCalls).toBeLessThanOrEqual(nodes.length * 4)
})
