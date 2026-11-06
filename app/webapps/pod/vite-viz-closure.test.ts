import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'bun:test'

interface ManifestChunk {
  isEntry?: boolean
  name?: string
  file?: string
  imports?: string[]
  dynamicImports?: string[]
}

const LAZY_VIZ_CHUNKS = new Set(['vendor-g2', 'vendor-charts', 'vendor-graph', 'vendor-infographic'])

function findEagerVizChunkLeaks(manifest: Record<string, ManifestChunk>): string[] {
  const leaks: string[] = []
  for (const [entryKey, entryMeta] of Object.entries(manifest)) {
    if (!entryMeta?.isEntry) continue
    const visited = new Set<string>()
    const queue = [...(entryMeta.imports ?? [])]
    while (queue.length > 0) {
      const depKey = queue.shift()!
      if (visited.has(depKey)) continue
      visited.add(depKey)
      const dep = manifest[depKey]
      if (!dep) continue
      if (dep.name && LAZY_VIZ_CHUNKS.has(dep.name)) {
        leaks.push(`${entryKey} -> ${dep.name} (${dep.file ?? depKey})`)
      }
      for (const child of dep.imports ?? []) {
        if (!visited.has(child)) queue.push(child)
      }
    }
  }
  return leaks
}

describe('Vite visualization lazy-chunk closure', () => {
  test('flags transitive static imports of heavy viz chunks while allowing dynamicImports', () => {
    const cleanManifest: Record<string, ManifestChunk> = {
      'entrypoints/pod.tsx': {
        isEntry: true,
        name: 'pod',
        file: 'js/pod-1.js',
        imports: ['_uikit.js'],
        dynamicImports: ['_base-chart-view.js']
      },
      'entrypoints/applet-vendor/uikit.ts': {
        isEntry: true,
        name: 'applet-uikit',
        file: 'js/applet-uikit-1.js',
        imports: ['_uikit.js'],
        dynamicImports: ['_viz-statistical.js', '_viz-financial.js', '_viz-infographic.js', '_viz-graph.js']
      },
      '_uikit.js': {
        name: 'uikit',
        file: 'js/uikit-1.js',
        imports: []
      },
      '_viz-statistical.js': {
        name: 'statistical',
        file: 'js/statistical-1.js',
        imports: ['_vendor-g2.js']
      },
      '_vendor-g2.js': {
        name: 'vendor-g2',
        file: 'js/vendor-g2-1.js'
      }
    }
    expect(findEagerVizChunkLeaks(cleanManifest)).toEqual([])

    const leakyManifest: Record<string, ManifestChunk> = {
      ...cleanManifest,
      '_uikit.js': {
        name: 'uikit',
        file: 'js/uikit-1.js',
        imports: ['_vendor-g2.js']
      }
    }
    expect(findEagerVizChunkLeaks(leakyManifest)).toEqual([
      'entrypoints/pod.tsx -> vendor-g2 (js/vendor-g2-1.js)',
      'entrypoints/applet-vendor/uikit.ts -> vendor-g2 (js/vendor-g2-1.js)'
    ])
  })

  test('keeps vendor-g2, vendor-charts, vendor-graph, and vendor-infographic out of static entry closures', () => {
    const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
    const uikitIndex = readFileSync(path.join(repoRoot, 'libs/uikit/src/index.ts'), 'utf8')
    expect(uikitIndex).not.toMatch(/from\s+['"]@antv\/(g2|g6|infographic|g-svg)['"]/)
    expect(uikitIndex).not.toMatch(/from\s+['"]lightweight-charts['"]/)
    expect(uikitIndex).not.toMatch(/from\s+['"]\.\/viz\/(statistical|financial|infographic|graph)['"]/)

    for (const edition of ['foss', 'saas']) {
      const manifestPath = path.join(repoRoot, 'app/control_plane/_build', edition, 'webapps/assets/manifest.json')
      if (!existsSync(manifestPath)) continue
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Record<string, ManifestChunk>
      expect(manifest['entrypoints/pod.tsx']?.isEntry).toBe(true)
      expect(manifest['entrypoints/applet-vendor/uikit.ts']?.isEntry).toBe(true)
      expect(findEagerVizChunkLeaks(manifest)).toEqual([])
    }
  })
})
