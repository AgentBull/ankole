import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'bun:test'
import { loadAppDevelopmentEnv, resolveLocalBin } from './utils'

test('development dotenv files use control-plane precedence and preserve OS overrides', () => {
  const root = mkdtempSync(join(tmpdir(), 'ankole-dev-env-'))
  const key = 'ANKOLE_DEVKIT_ENV_TEST'
  const original = process.env[key]
  try {
    delete process.env[key]
    writeFileSync(join(root, '.env.dev'), `${key}=default\nANKOLE_DEVKIT_DEFAULT_TEST=present\n`)
    expect(loadAppDevelopmentEnv(root)[key]).toBe('default')
    writeFileSync(join(root, '.env.dev.local'), `${key}=development-local\n`)
    expect(loadAppDevelopmentEnv(root)[key]).toBe('development-local')
    writeFileSync(join(root, '.env.local'), `${key}="local"\n`)
    expect(loadAppDevelopmentEnv(root)[key]).toBe('local')
    expect(loadAppDevelopmentEnv(root).ANKOLE_DEVKIT_DEFAULT_TEST).toBe('present')
    process.env[key] = 'os'
    expect(loadAppDevelopmentEnv(root)[key]).toBe('os')
  } finally {
    if (original === undefined) delete process.env[key]
    else process.env[key] = original
    rmSync(root, { recursive: true, force: true })
  }
})

test('resolveLocalBin prefers workspace .bin links over stale .bun store entries and sorts .bun versions numerically', () => {
  const repoRoot = mkdtempSync(join(tmpdir(), 'ankole-bin-resolve-'))
  const packageRoot = join(repoRoot, 'tools', 'devkit')
  try {
    const staleStoreBin = join(repoRoot, 'node_modules', '.bun', 'tool@1.0.0-beta.9', 'node_modules', '.bin', 'tool')
    const newerStoreBin = join(repoRoot, 'node_modules', '.bun', 'tool@1.0.0-beta.13', 'node_modules', '.bin', 'tool')
    mkdirSync(join(staleStoreBin, '..'), { recursive: true })
    mkdirSync(join(newerStoreBin, '..'), { recursive: true })
    writeFileSync(staleStoreBin, '')
    writeFileSync(newerStoreBin, '')

    expect(resolveLocalBin('tool', { repoRoot, packageRoot })).toBe(newerStoreBin)

    const packageBin = join(packageRoot, 'node_modules', '.bin', 'tool')
    mkdirSync(join(packageBin, '..'), { recursive: true })
    writeFileSync(packageBin, '')
    expect(resolveLocalBin('tool', { repoRoot, packageRoot })).toBe(packageBin)

    const rootBin = join(repoRoot, 'node_modules', '.bin', 'tool')
    mkdirSync(join(rootBin, '..'), { recursive: true })
    writeFileSync(rootBin, '')
    expect(resolveLocalBin('tool', { repoRoot, packageRoot })).toBe(rootBin)
  } finally {
    rmSync(repoRoot, { recursive: true, force: true })
  }
})
