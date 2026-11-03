import { expect, test } from 'bun:test'
import { brainGraphLayout } from './brain-graph'

test('dense knowledge sets give every title a separate cell and retain adjacency', () => {
  const nodes = Array.from({ length: 200 }, (_, index) => ({ id: String(index) }))
  const links = [
    { from_page_id: '0', to_page_id: '199' },
    { from_page_id: '199', to_page_id: 'missing' }
  ]
  const layout = brainGraphLayout(nodes, links)
  const points = [...layout.positions.values()]
  expect(new Set(points.map(point => `${point.x},${point.y}`)).size).toBe(nodes.length)
  for (const point of points) {
    expect(point.x + 100).toBeLessThanOrEqual(layout.width)
    expect(point.y + 32).toBeLessThanOrEqual(layout.height)
    for (const other of points) {
      if (point !== other) expect(Math.abs(point.x - other.x) >= 220 || Math.abs(point.y - other.y) >= 60).toBe(true)
    }
  }
  expect(layout.neighbors.get('0')?.has('199')).toBe(true)
  expect(layout.neighbors.get('199')?.has('missing')).toBe(false)
})
