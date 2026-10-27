import { describe, expect, test } from 'bun:test'

import { applyOptionalLocalSccacheEnv, resolveSccacheMode } from './sccache'

describe('local sccache convention', () => {
  test('parses auto, enabled, and disabled ANKOLE_SCCACHE modes', () => {
    expect(resolveSccacheMode(undefined)).toBe('auto')
    expect(resolveSccacheMode('')).toBe('auto')
    expect(resolveSccacheMode(' AUTO ')).toBe('auto')
    expect(resolveSccacheMode('1')).toBe('enabled')
    expect(resolveSccacheMode(' TRUE ')).toBe('enabled')
    expect(resolveSccacheMode('0')).toBe('disabled')
    expect(resolveSccacheMode('false')).toBe('disabled')
    expect(() => resolveSccacheMode('invalid')).toThrow('Invalid ANKOLE_SCCACHE value')
  })

  test('enables local SSD cache automatically when sccache is installed', () => {
    const env = applyOptionalLocalSccacheEnv(
      {
        SCCACHE_DIR: '/fast-ssd/sccache',
        SCCACHE_BUCKET: 'remote-bucket',
        SCCACHE_REDIS: 'redis://remote',
        SCCACHE_GHA_ENABLED: 'true'
      },
      { resolveExecutable: () => '/opt/homebrew/bin/sccache' }
    )

    expect(env.RUSTC_WRAPPER).toBe('/opt/homebrew/bin/sccache')
    expect(env.CMAKE_C_COMPILER_LAUNCHER).toBe('/opt/homebrew/bin/sccache')
    expect(env.CMAKE_CXX_COMPILER_LAUNCHER).toBe('/opt/homebrew/bin/sccache')
    expect(env.SCCACHE_CACHE_SIZE).toBe('20G')
    expect(env.SCCACHE_DIR).toBe('/fast-ssd/sccache')
    expect(env.SCCACHE_BUCKET).toBeUndefined()
    expect(env.SCCACHE_REDIS).toBeUndefined()
    expect(env.SCCACHE_GHA_ENABLED).toBeUndefined()
  })

  test('falls back silently to standard Cargo when sccache is not installed', () => {
    const warnings: string[] = []
    const env = applyOptionalLocalSccacheEnv(
      { PATH: '/usr/bin' },
      { resolveExecutable: () => null, warn: message => warnings.push(message) }
    )

    expect(env.RUSTC_WRAPPER).toBeUndefined()
    expect(warnings).toEqual([])
  })

  test('warns when ANKOLE_SCCACHE=1 is set explicitly without sccache installed', () => {
    const warnings: string[] = []
    const env = applyOptionalLocalSccacheEnv(
      { ANKOLE_SCCACHE: '1', PATH: '/usr/bin' },
      { resolveExecutable: () => null, warn: message => warnings.push(message) }
    )

    expect(env.RUSTC_WRAPPER).toBeUndefined()
    expect(warnings).toHaveLength(1)
    expect(warnings[0]).toContain('sccache is not on PATH')
  })

  test('disables sccache when ANKOLE_SCCACHE=0', () => {
    const env = applyOptionalLocalSccacheEnv(
      { ANKOLE_SCCACHE: '0' },
      { resolveExecutable: () => '/opt/homebrew/bin/sccache' }
    )

    expect(env.RUSTC_WRAPPER).toBeUndefined()
  })

  test('preserves an explicit RUSTC_WRAPPER without overriding it', () => {
    const env = applyOptionalLocalSccacheEnv(
      { RUSTC_WRAPPER: '/custom/wrapper' },
      { resolveExecutable: () => '/opt/homebrew/bin/sccache' }
    )

    expect(env.RUSTC_WRAPPER).toBe('/custom/wrapper')
  })
})
