import { describe, expect, test } from 'bun:test'

import { buildCargoEnv } from '../../scripts/cargo'

describe('buildCargoEnv', () => {
  test('automatically enables local SSD sccache and strips remote backends when sccache is present', () => {
    const env = buildCargoEnv(
      {
        SCCACHE_BUCKET: 'remote-s3-bucket',
        SCCACHE_GHA_ENABLED: 'true'
      },
      { resolveExecutable: () => '/usr/local/bin/sccache' }
    )

    expect(env.RUSTC_WRAPPER).toBe('/usr/local/bin/sccache')
    expect(env.CMAKE_C_COMPILER_LAUNCHER).toBe('/usr/local/bin/sccache')
    expect(env.CMAKE_CXX_COMPILER_LAUNCHER).toBe('/usr/local/bin/sccache')
    expect(env.SCCACHE_CACHE_SIZE).toBe('20G')
    expect(env.SCCACHE_BUCKET).toBeUndefined()
    expect(env.SCCACHE_GHA_ENABLED).toBeUndefined()
  })

  test('disables sccache when ANKOLE_SCCACHE=0', () => {
    const env = buildCargoEnv(
      { ANKOLE_SCCACHE: '0', PATH: '/usr/bin' },
      { resolveExecutable: () => '/usr/local/bin/sccache' }
    )

    expect(env.RUSTC_WRAPPER).toBeUndefined()
  })
})
