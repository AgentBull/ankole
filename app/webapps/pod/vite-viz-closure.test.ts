import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'bun:test'

interface ManifestChunk {
  isEntry?: boolean
  name?: string
  file?: string
  css?: string[]
  imports?: string[]
  dynamicImports?: string[]
}

const LAZY_VIZ_CHUNKS = new Set(['vendor-g2', 'vendor-charts', 'vendor-graph', 'vendor-infographic'])

function findStaticChunkCycles(manifest: Record<string, ManifestChunk>): string[][] {
  const index = new Map<string, number>()
  const lowlink = new Map<string, number>()
  const stack: string[] = []
  const onStack = new Set<string>()
  const cycles: string[][] = []
  let nextIndex = 0

  const strongConnect = (key: string): void => {
    index.set(key, nextIndex)
    lowlink.set(key, nextIndex)
    nextIndex += 1
    stack.push(key)
    onStack.add(key)

    for (const dep of manifest[key]?.imports ?? []) {
      if (!manifest[dep]) continue
      if (!index.has(dep)) {
        strongConnect(dep)
        lowlink.set(key, Math.min(lowlink.get(key)!, lowlink.get(dep)!))
      } else if (onStack.has(dep)) {
        lowlink.set(key, Math.min(lowlink.get(key)!, index.get(dep)!))
      }
    }

    if (lowlink.get(key) === index.get(key)) {
      const component: string[] = []
      let member: string
      do {
        member = stack.pop()!
        onStack.delete(member)
        component.push(member)
      } while (member !== key)
      if (component.length > 1) cycles.push(component.reverse())
    }
  }

  for (const key of Object.keys(manifest)) {
    if (!index.has(key)) strongConnect(key)
  }

  return cycles
}

function findAppletCssHostLeaks(manifest: Record<string, ManifestChunk>): string[] {
  const appletCss = new Set<string>()
  const seenApplet = new Set<string>()
  const appletQueue = ['entrypoints/applet-vendor/uikit.ts']
  while (appletQueue.length > 0) {
    const key = appletQueue.shift()!
    if (seenApplet.has(key)) continue
    seenApplet.add(key)
    const chunk = manifest[key]
    if (!chunk) continue
    for (const cssFile of chunk.css ?? []) appletCss.add(cssFile)
    for (const child of chunk.imports ?? []) {
      if (!seenApplet.has(child)) appletQueue.push(child)
    }
  }
  if (appletCss.size === 0) return []

  const leaks: string[] = []
  for (const [entryKey, entryMeta] of Object.entries(manifest)) {
    if (!entryMeta?.isEntry || entryMeta.name?.startsWith('applet-')) continue
    const visited = new Set<string>()
    const queue = [entryKey]
    while (queue.length > 0) {
      const key = queue.shift()!
      if (visited.has(key)) continue
      visited.add(key)
      const chunk = manifest[key]
      if (!chunk) continue
      for (const cssFile of chunk.css ?? []) {
        if (appletCss.has(cssFile)) {
          leaks.push(`${entryKey} -> ${key} (${cssFile})`)
        }
      }
      for (const child of [...(chunk.imports ?? []), ...(chunk.dynamicImports ?? [])]) {
        if (!visited.has(child)) queue.push(child)
      }
    }
  }
  return leaks
}

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
      expect(findAppletCssHostLeaks(manifest)).toEqual([])
      expect(findStaticChunkCycles(manifest)).toEqual([])
    }
  })

  test('flags static JS chunk import cycles across CJS/ESM chunks', () => {
    const acyclicManifest: Record<string, ManifestChunk> = {
      '../../internals/webapps/landing.tsx': {
        isEntry: true,
        name: 'saas-landing',
        file: 'js/saas-landing-1.js',
        imports: ['_vendor-react.js', '_vendor-setup-ui.js']
      },
      '_vendor-setup-ui.js': {
        name: 'vendor-setup-ui',
        file: 'js/vendor-setup-ui-1.js',
        imports: ['_vendor-react.js']
      },
      '_vendor-react.js': {
        name: 'vendor-react',
        file: 'js/vendor-react-1.js',
        imports: []
      }
    }
    expect(findStaticChunkCycles(acyclicManifest)).toEqual([])

    const cyclicManifest: Record<string, ManifestChunk> = {
      ...acyclicManifest,
      '_vendor-react.js': {
        name: 'uikit-merged-react',
        file: 'js/uikit-merged-react-1.js',
        imports: ['_vendor-setup-ui.js']
      }
    }
    expect(findStaticChunkCycles(cyclicManifest)).toEqual([['_vendor-react.js', '_vendor-setup-ui.js']])
  })

  test('flags standalone applet-uikit Tailwind CSS leaking into host SPA entries or lazy routes', () => {
    const cleanManifest: Record<string, ManifestChunk> = {
      '../../internals/webapps/landing.tsx': {
        isEntry: true,
        name: 'saas-landing',
        file: 'js/saas-landing-1.js',
        css: ['css/saas-landing-1.css'],
        imports: ['_mount.js', '_uikit.js']
      },
      'entrypoints/applet-vendor/uikit.ts': {
        isEntry: true,
        name: 'applet-uikit',
        file: 'js/applet-uikit-1.js',
        css: ['css/applet-uikit-1.css'],
        imports: ['_uikit.js']
      },
      '_mount.js': {
        name: 'mount',
        file: 'js/mount-1.js',
        css: ['css/mount-1.css']
      },
      '_uikit.js': {
        name: 'uikit',
        file: 'js/uikit-1.js'
      }
    }
    expect(findAppletCssHostLeaks(cleanManifest)).toEqual([])

    const leakyManifest: Record<string, ManifestChunk> = {
      ...cleanManifest,
      'entrypoints/applet-vendor/uikit.ts': {
        isEntry: true,
        name: 'applet-uikit',
        file: 'js/applet-uikit-1.js',
        imports: ['_uikit.js']
      },
      '_uikit.js': {
        name: 'uikit',
        file: 'js/uikit-1.js',
        css: ['css/uikit-duplicate-tailwind.css']
      }
    }
    expect(findAppletCssHostLeaks(leakyManifest)).toEqual([
      '../../internals/webapps/landing.tsx -> _uikit.js (css/uikit-duplicate-tailwind.css)'
    ])
  })
})
