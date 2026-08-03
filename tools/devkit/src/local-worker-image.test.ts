import { describe, expect, test } from 'bun:test'

import { assertPublishedWorkerLabels, buildWorkerImageBuildArgs, localWorkerImageRef } from './local-worker-image'

describe('local Worker image identity', () => {
  test('uses the complete input hash and scope instead of a reusable version tag', () => {
    const inputHash = 'a'.repeat(64)

    expect(localWorkerImageRef('source-mounted', inputHash)).toBe(
      `ankole-agent-computer:local-source-mounted-${inputHash}`
    )
    expect(localWorkerImageRef('complete', inputHash)).toBe(`ankole-agent-computer:local-complete-${inputHash}`)
    expect(() => localWorkerImageRef('complete', 'short')).toThrow('must be sha256')
  })

  test('pins the base and records the exact inputs on a local build', () => {
    const inputHash = 'b'.repeat(64)
    const baseImage = `ghcr.io/agentbull/ankole-agent-os-base@sha256:${'c'.repeat(64)}`
    const args = buildWorkerImageBuildArgs(localWorkerImageRef('complete', inputHash), 'complete', inputHash, baseImage)

    expect(args).toContain(`BASE_IMAGE=${baseImage}`)
    expect(args).toContain(`io.ankole.local-worker.input-hash=${inputHash}`)
    expect(args).toContain('io.ankole.local-worker.input-scope=complete')
    expect(args).not.toContain('main-latest')
  })

  test('accepts the published base identity without coupling it to the fallback base lock', () => {
    const revision = 'd'.repeat(40)
    const labels = {
      'org.opencontainers.image.revision': revision,
      'io.ankole.agent-os-base.digest': `sha256:${'e'.repeat(64)}`
    }

    expect(() => assertPublishedWorkerLabels(labels, revision)).not.toThrow()
    expect(() => assertPublishedWorkerLabels(labels, 'f'.repeat(40))).toThrow('does not declare revision')
    expect(() =>
      assertPublishedWorkerLabels({ ...labels, 'io.ankole.agent-os-base.digest': 'moving-tag' }, revision)
    ).toThrow('does not declare its Agent OS base digest')
  })
})
