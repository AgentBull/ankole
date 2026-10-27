import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'bun:test'
import { loadAppDevelopmentEnv } from './utils'

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
