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

function createTopologyFixture(files: { sdkPlugins: string; consumer: string }): string {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'bullx-topology-'))
  mkdirSync(path.join(repoRoot, 'app'), { recursive: true })
  mkdirSync(path.join(repoRoot, 'packages/sdk/src'), { recursive: true })
  mkdirSync(path.join(repoRoot, 'plugin/lark-adapter/src'), { recursive: true })

  writeFileSync(
    path.join(repoRoot, 'app/tsconfig.json'),
    JSON.stringify({
      compilerOptions: {
        target: 'ES2022',
        module: 'ESNext',
        moduleResolution: 'bundler',
        strict: true,
        noEmit: true,
        baseUrl: '..',
        paths: {
          '@agentbull/bullx-sdk/*': ['packages/sdk/src/*']
        }
      },
      include: ['src/**/*.ts']
    })
  )
  writeFileSync(path.join(repoRoot, 'packages/sdk/src/plugins.ts'), files.sdkPlugins)
  writeFileSync(path.join(repoRoot, 'plugin/lark-adapter/src/consumer.ts'), files.consumer)
  return repoRoot
}

function analyzeSdkPluginFixture(
  repoRoot: string,
  report: 'consumer-topology' | 'unused-public-surface',
  intentionalUnusedPublicExportNames = new Set<string>()
) {
  const scope = createFilesystemPublicSurfaceScope(repoRoot, {
    id: 'sdk-plugins',
    description: 'test SDK plugin surface',
    entrypointRoot: 'packages/sdk/src',
    importPrefix: '@agentbull/bullx-sdk'
  })
  return analyzeTopology({
    repoRoot,
    scope,
    report,
    intentionalUnusedPublicExportNames,
    tsconfigName: 'app/tsconfig.json'
  })
}

describe('parseKnipUnusedFiles', () => {
  test('extracts repo paths from knip v6 compact --files output', () => {
    const output = [
      'app/webui/src/x.tsx: app/webui/src/x.tsx',
      'packages/sdk/src/dead.ts: packages/sdk/src/dead.ts',
      'node_modules/foo/bar.js: node_modules/foo/bar.js',
      ''
    ].join('\n')
    expect(parseKnipUnusedFiles(output)).toEqual(['app/webui/src/x.tsx', 'packages/sdk/src/dead.ts'])
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
  test('counts type-only SDK imports as public-surface usage', () => {
    const repoRoot = createTopologyFixture({
      sdkPlugins: [
        'export interface NamedTypeOnly { value: string }',
        'export type InlineTypeOnly = { id: string }'
      ].join('\n'),
      consumer: [
        "import type { NamedTypeOnly } from '@agentbull/bullx-sdk/plugins'",
        "import { type InlineTypeOnly } from '@agentbull/bullx-sdk/plugins'",
        'export type Consumer = NamedTypeOnly & InlineTypeOnly'
      ].join('\n')
    })
    try {
      const envelope = analyzeSdkPluginFixture(repoRoot, 'consumer-topology')

      expect(envelope.totals.exports).toBe(2)
      expect(envelope.totals.usedByProduction).toBe(2)
      expect(envelope.totals.unused).toBe(0)
      expect(envelope.records.map(record => record.exportNames[0]).toSorted()).toEqual([
        'InlineTypeOnly',
        'NamedTypeOnly'
      ])
      for (const record of envelope.records) {
        expect(record.productionConsumers).toEqual(['plugin/lark-adapter/src/consumer.ts'])
        expect(record.productionRefCount).toBe(1)
      }
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })

  test('counts exported types reached through an imported public declaration', () => {
    const repoRoot = createTopologyFixture({
      sdkPlugins: [
        'export interface NestedContract { value: string }',
        'export interface ImportedContract { nested: NestedContract }',
        'export interface StandaloneContract { id: string }'
      ].join('\n'),
      consumer: [
        "import type { ImportedContract } from '@agentbull/bullx-sdk/plugins'",
        'export type Consumer = ImportedContract'
      ].join('\n')
    })
    try {
      const consumerEnvelope = analyzeSdkPluginFixture(repoRoot, 'consumer-topology')
      const unusedEnvelope = analyzeSdkPluginFixture(repoRoot, 'unused-public-surface')

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
      sdkPlugins: ['export const deprecatedAlias = "compat"', 'export const trulyUnused = "unused"'].join('\n'),
      consumer: 'export {}'
    })
    try {
      const envelope = analyzeSdkPluginFixture(repoRoot, 'unused-public-surface', new Set(['deprecatedAlias']))

      expect(envelope.totals.unused).toBe(1)
      expect(envelope.totals.allowlistedUnused).toBe(1)
      expect(envelope.records.map(record => record.exportNames[0])).toEqual(['trulyUnused'])
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })
})
