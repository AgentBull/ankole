// Regression guards for the analyzer parts most likely to silently break on a
// knip or parser dependency bump: the knip compact-output parser, runtime import
// scanner, and Tarjan strongly-connected-component detector.

import { describe, expect, test } from 'bun:test'
import { collectRuntimeStaticSpecifiers } from './cycles'
import { collectStronglyConnectedComponents } from './lib/import-cycle-graph'
import { parseKnipUnusedFiles } from './unused'

describe('parseKnipUnusedFiles', () => {
  test('extracts repo paths from knip v6 compact --files output', () => {
    const output = [
      'app/webapps/common/x.tsx: app/webapps/common/x.tsx',
      'libs/uikit/src/dead.ts: libs/uikit/src/dead.ts',
      'node_modules/foo/bar.js: node_modules/foo/bar.js',
      ''
    ].join('\n')
    expect(parseKnipUnusedFiles(output)).toEqual(['app/webapps/common/x.tsx', 'libs/uikit/src/dead.ts'])
  })

  test('tolerates bare-path lines and dedupes', () => {
    expect(parseKnipUnusedFiles('tools/devkit/src/a.ts\ntools/devkit/src/a.ts\n')).toEqual(['tools/devkit/src/a.ts'])
  })
})

describe('collectStronglyConnectedComponents', () => {
  test('detects a 2-node cycle', () => {
    const graph = new Map([
      ['a', ['b']],
      ['b', ['a']]
    ])
    expect(collectStronglyConnectedComponents(graph)).toEqual([['a', 'b']])
  })

  test('reports no cycle for an acyclic graph', () => {
    const graph = new Map([
      ['a', ['b']],
      ['b', ['c']],
      ['c', []]
    ])
    expect(collectStronglyConnectedComponents(graph)).toEqual([])
  })
})

describe('collectRuntimeStaticSpecifiers', () => {
  test('keeps static runtime edges and removes type-only and deferred edges', () => {
    const source = [
      "import type { TypeOnly } from './type-only'",
      "import { type MixedType, runtimeValue } from './mixed-import'",
      "export type { ExportedType } from './type-export'",
      "export { type ReExportedType, runtimeExport } from './mixed-export'",
      "export * from './export-all'",
      "import './side-effect'",
      'const identity = <T>(value: T): T => value',
      "require('./required')",
      "import('./dynamic')"
    ].join('\n')

    expect(collectRuntimeStaticSpecifiers(source)).toEqual([
      './mixed-import',
      './mixed-export',
      './export-all',
      './side-effect'
    ])
  })
})
