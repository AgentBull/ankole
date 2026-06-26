// Regression guard for the two ported algorithms most likely to silently break
// on a knip/typescript dependency bump: the knip compact-output parser and the
// Tarjan strongly-connected-component detector.

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { describe, expect, test } from 'bun:test'
import { collectStronglyConnectedComponents } from './lib/import-cycle-graph'
import { analyzeTopology } from './lib/ts-topology/analyze'
import { createFilesystemPublicSurfaceScope } from './lib/ts-topology/scope'
import { parseKnipUnusedFiles } from './unused'

function createTopologyFixture(files: { coreIndex: string; consumer: string }): string {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'ankole-topology-'))
  mkdirSync(path.join(repoRoot, 'app/agent_computer/src/core'), { recursive: true })
  mkdirSync(path.join(repoRoot, 'app/webapps/console'), { recursive: true })

  writeFileSync(
    path.join(repoRoot, 'app/agent_computer/tsconfig.json'),
    JSON.stringify({
      compilerOptions: {
        target: 'ES2022',
        module: 'ESNext',
        moduleResolution: 'bundler',
        strict: true,
        noEmit: true,
        baseUrl: '.',
        paths: {
          '@/*': ['./src/*']
        }
      },
      include: ['src/**/*.ts']
    })
  )
  writeFileSync(path.join(repoRoot, 'app/agent_computer/src/core/index.ts'), files.coreIndex)
  writeFileSync(path.join(repoRoot, 'app/webapps/console/consumer.ts'), files.consumer)
  return repoRoot
}

function analyzeAgentCoreFixture(
  repoRoot: string,
  report: 'consumer-topology' | 'unused-public-surface',
  intentionalUnusedPublicExportNames = new Set<string>()
) {
  const scope = createFilesystemPublicSurfaceScope(repoRoot, {
    id: 'agent-computer-core',
    description: 'test Agent Computer core surface',
    entrypointRoot: 'app/agent_computer/src/core',
    importPrefix: '@/core'
  })
  return analyzeTopology({
    repoRoot,
    scope,
    report,
    intentionalUnusedPublicExportNames,
    tsconfigName: 'app/agent_computer/tsconfig.json'
  })
}

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

describe('analyzeTopology', () => {
  test('counts type-only public imports as public-surface usage', () => {
    const repoRoot = createTopologyFixture({
      coreIndex: [
        'export interface NamedTypeOnly { value: string }',
        'export type InlineTypeOnly = { id: string }'
      ].join('\n'),
      consumer: [
        "import type { NamedTypeOnly } from '@/core'",
        "import { type InlineTypeOnly } from '@/core'",
        'export type Consumer = NamedTypeOnly & InlineTypeOnly'
      ].join('\n')
    })
    try {
      const envelope = analyzeAgentCoreFixture(repoRoot, 'consumer-topology')

      expect(envelope.totals.exports).toBe(2)
      expect(envelope.totals.usedByProduction).toBe(2)
      expect(envelope.totals.unused).toBe(0)
      expect(envelope.records.map(record => record.exportNames[0]).toSorted()).toEqual([
        'InlineTypeOnly',
        'NamedTypeOnly'
      ])
      for (const record of envelope.records) {
        expect(record.productionConsumers).toEqual(['app/webapps/console/consumer.ts'])
        expect(record.productionRefCount).toBe(1)
      }
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })

  test('counts exported types reached through an imported public declaration', () => {
    const repoRoot = createTopologyFixture({
      coreIndex: [
        'export interface NestedContract { value: string }',
        'export interface ImportedContract { nested: NestedContract }',
        'export interface StandaloneContract { id: string }'
      ].join('\n'),
      consumer: ["import type { ImportedContract } from '@/core'", 'export type Consumer = ImportedContract'].join('\n')
    })
    try {
      const consumerEnvelope = analyzeAgentCoreFixture(repoRoot, 'consumer-topology')
      const unusedEnvelope = analyzeAgentCoreFixture(repoRoot, 'unused-public-surface')

      expect(consumerEnvelope.records.map(record => record.exportNames[0]).toSorted()).toEqual([
        'ImportedContract',
        'NestedContract'
      ])
      expect(unusedEnvelope.records.map(record => record.exportNames[0])).toEqual(['StandaloneContract'])
      expect(unusedEnvelope.totals.unused).toBe(1)
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })

  test('keeps intentionally retained public exports out of unused reports', () => {
    const repoRoot = createTopologyFixture({
      coreIndex: ['export const deprecatedAlias = "compat"', 'export const trulyUnused = "unused"'].join('\n'),
      consumer: 'export {}'
    })
    try {
      const envelope = analyzeAgentCoreFixture(repoRoot, 'unused-public-surface', new Set(['deprecatedAlias']))

      expect(envelope.totals.unused).toBe(1)
      expect(envelope.totals.allowlistedUnused).toBe(1)
      expect(envelope.records.map(record => record.exportNames[0])).toEqual(['trulyUnused'])
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })
})
