/** Keep linked objects together and give every label its own fixed-size cell. */
export function brainGraphLayout(
  nodes: readonly { id: string }[],
  links: readonly { from_page_id: string; to_page_id: string }[]
) {
  const neighbors = new Map(nodes.map(node => [node.id, new Set<string>()]))
  for (const link of links) {
    if (!neighbors.has(link.from_page_id) || !neighbors.has(link.to_page_id)) continue
    neighbors.get(link.from_page_id)!.add(link.to_page_id)
    neighbors.get(link.to_page_id)!.add(link.from_page_id)
  }
  const seen = new Set<string>()
  const order: string[] = []
  for (const node of nodes) {
    if (seen.has(node.id)) continue
    const queue = [node.id]
    seen.add(node.id)
    for (let index = 0; index < queue.length; index++) {
      const id = queue[index]!
      order.push(id)
      for (const neighbor of neighbors.get(id)!) {
        if (seen.has(neighbor)) continue
        seen.add(neighbor)
        queue.push(neighbor)
      }
    }
  }
  const columns = Math.max(3, Math.ceil(Math.sqrt(nodes.length)))
  return {
    width: columns * 240,
    height: Math.max(400, Math.ceil(nodes.length / columns) * 120),
    neighbors,
    positions: new Map(
      order.map((id, index) => [id, { x: (index % columns) * 240 + 120, y: Math.floor(index / columns) * 120 + 60 }])
    )
  }
}
