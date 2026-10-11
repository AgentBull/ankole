// Regression guards for the analyzer parts most likely to silently break on a
// knip or parser dependency bump: the Knip JSON parser, runtime import
// scanner, and Tarjan strongly-connected-component detector.

import { describe, expect, test } from 'bun:test'
import { collectRuntimeStaticSpecifiers } from './cycles'
import { collectStronglyConnectedComponents } from './lib/import-cycle-graph'
import { parseKnipIssues } from './unused'

describe('parseKnipIssues', () => {
  test('keeps function, type, dependency and file findings separate', () => {
    const report = JSON.stringify({
      issues: [
        {
          file: 'app/example.ts',
          files: [{ name: 'app/example.ts' }],
          exports: [{ name: 'deadFunction' }],
          types: [{ name: 'DeadType' }],
          dependencies: [{ name: 'unused-package' }]
        }
      ]
    })
    expect(parseKnipIssues(report)).toEqual([
      { file: 'app/example.ts', kind: 'dependencies', name: 'unused-package' },
      { file: 'app/example.ts', kind: 'exports', name: 'deadFunction' },
      { file: 'app/example.ts', kind: 'files', name: 'app/example.ts' },
      { file: 'app/example.ts', kind: 'types', name: 'DeadType' }
    ])
  })
  test('rejects tool errors and incomplete output instead of reporting a clean graph', () => {
    expect(() => parseKnipIssues('Knip failed')).toThrow()
    expect(() => parseKnipIssues('{}')).toThrow()
    expect(() => parseKnipIssues('{"issues":[{"file":"x.ts"}]}')).toThrow()
    expect(parseKnipIssues('{"issues":[]}')).toEqual([])
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
