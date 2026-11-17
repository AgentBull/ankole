import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { repoRootPath } from '../../utils'

interface OxlintDiagnostic {
  readonly code?: string
  readonly filename?: string
  readonly message?: string
}

describe('anti-slop Oxlint plugin', () => {
  let fixtureRoot = ''
  let diagnostics: OxlintDiagnostic[] = []

  const writeFixture = (relativePath: string, content: string) => {
    const fullPath = path.join(fixtureRoot, relativePath)
    mkdirSync(path.dirname(fullPath), { recursive: true })
    writeFileSync(fullPath, content)
  }

  const codesFor = (relativePath: string): string[] =>
    diagnostics
      .filter(item => item.filename?.replaceAll('\\', '/').endsWith(relativePath))
      .map(item => item.code ?? '')
      .sort()

  beforeAll(() => {
    fixtureRoot = mkdtempSync(path.join(tmpdir(), 'ankole-anti-slop-'))
    const pluginPath = path.join(repoRootPath, 'tools/devkit/src/oxlint/anti-slop/index.ts')

    writeFixture(
      '.oxlintrc.json',
      JSON.stringify(
        {
          plugins: ['typescript', 'oxc'],
          jsPlugins: [{ name: 'anti-slop', specifier: pluginPath }],
          rules: {
            'oxc/no-accumulating-spread': 'error',
            'anti-slop/global-data': 'error',
            'anti-slop/max-ternary-depth': ['error', { maxDepth: 3 }],
            'anti-slop/no-chained-type-assertions': 'error',
            'anti-slop/no-disabled-type-assertion-rules': 'error',
            'anti-slop/no-module-mocking': [
              'error',
              { allowSpecifierPatterns: ['\\?(?:.*&)?(?:worker|url|raw|inline)(?:[&=]|$)'] }
            ],
            'anti-slop/no-reduce-accumulator-copy': 'error',
            'anti-slop/no-reflect-apply': 'error',
            'anti-slop/no-reflect-get': 'error',
            'anti-slop/no-test-code-in-src': 'error',
            'anti-slop/no-unknown-type-aliases': 'error',
            'anti-slop/no-widen-then-assert': 'error'
          },
          overrides: [
            {
              files: ['**/*.test.ts', '**/test/**'],
              rules: {
                'anti-slop/no-chained-type-assertions': 'off'
              }
            },
            {
              files: ['colocated/src/**'],
              rules: {
                'anti-slop/no-test-code-in-src': ['error', { allowTestFiles: true }]
              }
            }
          ]
        },
        null,
        2
      )
    )

    writeFixture(
      'pkg/src/clean.tsx',
      [
        'export const MAX_RETRIES = 3',
        'export type JsonPrimitive = string | number | boolean | null',
        'export function statusView(state: "idle" | "loading" | "error" | "ready") {',
        '  return state === "loading" ? "wait" : state === "error" ? "fail" : state === "ready" ? "ok" : "idle"',
        '}',
        'export function wrapStorage(storage: Storage): Storage {',
        '  return new Proxy(storage, {',
        '    get(target, key) {',
        '      return Reflect.get(target, key, target)',
        '    }',
        '  })',
        '}',
        'export function collect(items: readonly number[]): number[] {',
        '  return items.reduce<number[]>((acc, item) => {',
        '    acc.push(item)',
        '    return acc',
        '  }, [])',
        '}'
      ].join('\n')
    )

    writeFixture(
      'pkg/src/violations.ts',
      [
        '// oxlint-disable-next-line',
        'export const afterBlanketDisable = 0',
        'export let mutableGlobal = 1',
        'export type HiddenUnknown = unknown',
        'export function bad(raw: Record<string, string>, fn: (x: number) => number): number {',
        '  const casted = raw as unknown as { count: number }',
        '  const wide: unknown = { count: casted.count }',
        '  const narrow = wide as { count: number }',
        '  const deep = narrow.count === 1 ? "a" : narrow.count === 2 ? "b" : narrow.count === 3 ? "c" : narrow.count === 4 ? "d" : "e"',
        '  const prop = Reflect.get(raw, deep)',
        '  const copied = [1, 2].reduce<number[]>((acc, item) => acc.concat(item), [])',
        '  return Reflect.apply(fn, undefined, [copied.length + Number(prop)])',
        '}',
        'export class FakeTransport {}'
      ].join('\n')
    )

    writeFixture('pkg/src/in-src.test.ts', 'export const misplaced = true\n')

    writeFixture(
      'pkg/test/mocking.test.ts',
      [
        'import { mock } from "bun:test"',
        'mock.module("./worker.ts?worker&url", () => ({ default: "blob:worker" }))',
        'mock.module("../src/clean", () => ({}))',
        'export const fixture = ({} as unknown as { ok: boolean })'
      ].join('\n')
    )

    writeFixture('colocated/src/helper.test.ts', 'export const colocatedTestAllowed = true\n')
    writeFixture(
      'colocated/src/prod.ts',
      'import { colocatedTestAllowed } from "./helper.test.ts"\nexport const bad = colocatedTestAllowed\n'
    )

    const oxlintBin = path.join(repoRootPath, 'node_modules/.bin/oxlint')
    const proc = Bun.spawnSync(['bun', '--bun', oxlintBin, '--format', 'json', '.'], {
      cwd: fixtureRoot,
      stdout: 'pipe',
      stderr: 'pipe'
    })
    const output = JSON.parse(proc.stdout.toString('utf8')) as { diagnostics?: OxlintDiagnostic[] }
    diagnostics = output.diagnostics ?? []
  })

  afterAll(() => {
    if (fixtureRoot) rmSync(fixtureRoot, { recursive: true, force: true })
  })

  test('passes clean idiomatic Ankole TypeScript including Proxy get traps and 4-state ternaries', () => {
    expect(codesFor('pkg/src/clean.tsx')).toEqual([])
  })

  test('catches every enabled anti-slop rule on production source violations', () => {
    expect(codesFor('pkg/src/violations.ts')).toEqual([
      'anti-slop(global-data)',
      'anti-slop(max-ternary-depth)',
      'anti-slop(no-chained-type-assertions)',
      'anti-slop(no-disabled-type-assertion-rules)',
      'anti-slop(no-reduce-accumulator-copy)',
      'anti-slop(no-reflect-apply)',
      'anti-slop(no-reflect-get)',
      'anti-slop(no-test-code-in-src)',
      'anti-slop(no-unknown-type-aliases)',
      'anti-slop(no-widen-then-assert)'
    ])
  })

  test('rejects misplaced test files in src/ while honoring allowTestFiles without relaxing test-import bans', () => {
    expect(codesFor('pkg/src/in-src.test.ts')).toEqual(['anti-slop(no-test-code-in-src)'])
    expect(codesFor('colocated/src/helper.test.ts')).toEqual([])
    expect(codesFor('colocated/src/prod.ts')).toEqual(['anti-slop(no-test-code-in-src)'])
  })

  test('catches bun:test mock.module on runtime modules while allowing Vite asset queries and test fixture casts', () => {
    expect(codesFor('pkg/test/mocking.test.ts')).toEqual(['anti-slop(no-module-mocking)'])
  })
})
