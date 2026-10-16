import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import path from 'node:path'

import {
  assertPublishedWorkerLabels,
  buildWorkerImageBuildArgs,
  localWorkerImageRef,
  workerBaseSource,
  workerInputRoots
} from './local-worker-image'
import { repoRootPath } from './utils'

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
    const baseImage = `ghcr.io/agentbull/ankole-agent-os-base:${'a'.repeat(40)}@sha256:${'c'.repeat(64)}`
    const args = buildWorkerImageBuildArgs(localWorkerImageRef('complete', inputHash), 'complete', inputHash, baseImage)

    expect(args).toContain(`BASE_IMAGE=${baseImage}`)
    expect(args).toContain(`io.ankole.local-worker.input-hash=${inputHash}`)
    expect(args).toContain('io.ankole.local-worker.input-scope=complete')
    expect(args).not.toContain('main-latest')
  })

  test('hashes every repository file that the final Worker image copies', () => {
    const dockerfile = readFileSync(path.join(repoRootPath, 'app', 'agent_computer', 'Dockerfile'), 'utf8')
    const finalStage = dockerfile.slice(dockerfile.lastIndexOf('\nFROM '))
    const sources = finalStage
      .split('\n')
      .filter(line => line.startsWith('COPY ') && !line.includes('--from='))
      .flatMap(line => line.split(/\s+/).slice(1, -1))
    const roots = workerInputRoots('complete')

    expect(sources.length).toBeGreaterThan(0)
    for (const source of sources) {
      expect(roots.some(root => source === root || source.startsWith(`${root}/`))).toBe(true)
    }
  })

  test('uses the pinned Agent OS base only when its recipe matches', () => {
    const recipe = 'a'.repeat(40)

    expect(workerBaseSource(recipe, recipe)).toBe('lock')
    expect(workerBaseSource('b'.repeat(40), recipe)).toBe('local')
    expect(workerBaseSource(null, recipe)).toBe('local')
    expect(workerBaseSource(recipe, null)).toBe('local')
  })

  test('includes the Agent OS recipe in the Worker image inputs', () => {
    expect(workerInputRoots('source-mounted')).toContain('app/agent_computer/Dockerfile.base')
    expect(workerInputRoots('complete')).toContain('app/agent_computer/Dockerfile.base')
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
