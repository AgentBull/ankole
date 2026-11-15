// Regression guards for the analyzer parts most likely to silently break on a
// knip or parser dependency bump: the Knip JSON parser, runtime import
// scanner, and Tarjan strongly-connected-component detector.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, test } from 'bun:test'
import { scanBoundarySource } from './smells'
import { createSourceResolver, collectRuntimeStaticSpecifiers } from './cycles'
import { collectStronglyConnectedComponents } from './lib/import-cycle-graph'
import { checkDirectoryRules, checkStructureSources } from './structure'
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

test('shared library boundaries reject application imports and allow declared UI peers', () => {
  for (const file of ['libs/ankole-editor/src/editor.ts', 'libs/applet-sdk/src/index.tsx']) {
    expect(scanBoundarySource(file, "import { x } from '../../../app/webapps/pod/app'")).toHaveLength(1)
    expect(scanBoundarySource(file, "import { x } from '@ankole/agent-computer/runtime'")).toHaveLength(1)
    expect(scanBoundarySource(file, "import { Button } from '@ankole/uikit'\nimport React from 'react'")).toEqual([])
  }
})

test('workspace exports and subpaths participate in runtime cycles without type-only targets', () => {
  const a = 'libs/a/src/index.ts',
    b = 'libs/b/src/component.tsx'
  const resolve = createSourceResolver(
    [a, b],
    [],
    [
      { root: 'libs/a', name: '@test/a', exports: { '.': { types: './src/type.ts', import: './src/index.ts' } } },
      {
        root: 'libs/b',
        name: '@test/b',
        exports: { './*': { import: './src/*.tsx' }, './types': { types: './src/type.ts' } }
      }
    ]
  )
  expect(resolve(a, '@test/b/component')).toBe(b)
  expect(resolve(b, '@test/a')).toBe(a)
  expect(resolve(a, '@test/b/types')).toBe(null)
  expect(
    collectStronglyConnectedComponents(
      new Map([
        [a, [resolve(a, '@test/b/component')!]],
        [b, [resolve(b, '@test/a')!]]
      ])
    )
  ).toEqual([[a, b]])
})

describe('structure conventions', () => {
  test('accepts compliant webapp entrypoints, lazy setup constant, and computer tool factories', async () => {
    const diagnostics = await checkStructureSources({
      'app/webapps/auth/app.tsx': 'export function AuthApp() { return null }',
      'app/webapps/pod/app.tsx': 'function renderPod() { return null }\nexport { renderPod as PodApp }',
      'app/webapps/entrypoints/auth.tsx':
        "import { mountApp } from '../common/mount'\nimport { AuthApp } from '../auth/app'\nvoid mountApp(AuthApp)",
      'app/webapps/entrypoints/setup.tsx':
        "import { mountApp } from '../common/mount'\nconst SetupApp = () => null\nvoid mountApp(SetupApp)",
      'app/agent_computer/src/tools/computer/apply-patch-tool.ts': 'export function createApplyPatchTool() {}'
    })
    expect(diagnostics).toEqual([])
  })

  test('rejects type-only imports, non-const bindings, and missing factory exports', async () => {
    const diagnostics = await checkStructureSources({
      'app/webapps/entrypoints/auth.tsx':
        "import type { mountApp } from '../common/mount'\nimport { type AuthApp } from '../auth/app'",
      'app/webapps/entrypoints/setup.tsx': "import { mountApp } from '../common/mount'\nlet SetupApp = null",
      'app/agent_computer/src/tools/computer/read-file-tool.ts': 'export const createReadFileTool = () => ({})'
    })
    expect(diagnostics.map(item => `${item.filePath}:${item.conventionName}:${item.predicateName}`)).toEqual([
      'app/agent_computer/src/tools/computer/read-file-tool.ts:computer-tool-factories:exportFunctions',
      'app/webapps/entrypoints/auth.tsx:webapp-direct-entrypoint-app-imports:importValues',
      'app/webapps/entrypoints/auth.tsx:webapp-entrypoints:importValues',
      'app/webapps/entrypoints/setup.tsx:webapp-setup-entrypoint-lazy-app:declareConstants'
    ])
  })

  test('enforces plugin directory root Elixir module convention', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-structure-plugins-'))
    try {
      mkdirSync(join(root, 'plugins', 'slack_adapter', 'lib', 'ankole', 'plugins'), { recursive: true })
      writeFileSync(join(root, 'plugins', 'slack_adapter', 'lib', 'ankole', 'plugins', 'slack_adapter.ex'), '')
      mkdirSync(join(root, 'plugins', 'broken_adapter'), { recursive: true })
      writeFileSync(join(root, 'plugins', 'stray.txt'), 'nope')

      expect(checkDirectoryRules(root)).toEqual([
        {
          conventionName: 'plugin-root-files',
          filePath: 'plugins/broken_adapter',
          predicateName: 'haveFiles',
          message: 'Missing required file: lib/ankole/plugins/broken_adapter.ex'
        },
        {
          conventionName: 'plugin-root-files',
          filePath: 'plugins/stray.txt',
          predicateName: 'haveType',
          message: 'Expected a directory but found a file'
        }
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
