import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import path from 'node:path'

import {
  assertPublishedFunctionRuntimeLabels,
  buildFunctionRuntimeImageBuildArgs,
  canReuseEdgeRuntimeBinary,
  extractNativeStageRecipe,
  functionRuntimeInputRoots,
  localFunctionRuntimeImageRef
} from './local-function-runtime-image'
import { repoRootPath } from './utils'

describe('local Function Runtime image identity', () => {
  test('uses the sha256 input hash instead of a moving tag', () => {
    const inputHash = 'a'.repeat(64)

    expect(localFunctionRuntimeImageRef(inputHash)).toBe(`ankole-function-runtime:local-${inputHash}`)
    expect(() => localFunctionRuntimeImageRef('short')).toThrow('must be sha256')
  })

  test('passes EDGE_RUNTIME_IMAGE only when a matching native stage image is available', () => {
    const inputHash = 'b'.repeat(64)
    const image = localFunctionRuntimeImageRef(inputHash)
    const fullBuildArgs = buildFunctionRuntimeImageBuildArgs(image, inputHash)
    const overlayBuildArgs = buildFunctionRuntimeImageBuildArgs(
      image,
      inputHash,
      `ghcr.io/agentbull/ankole-function-runtime:${'c'.repeat(40)}`
    )

    expect(fullBuildArgs).toContain(`io.ankole.local-function-runtime.input-hash=${inputHash}`)
    expect(fullBuildArgs.some(arg => arg.startsWith('EDGE_RUNTIME_IMAGE='))).toBe(false)
    expect(overlayBuildArgs).toContain(`EDGE_RUNTIME_IMAGE=ghcr.io/agentbull/ankole-function-runtime:${'c'.repeat(40)}`)
  })

  test('hashes every repository file that the Function Runtime Dockerfile copies', () => {
    const dockerfile = readFileSync(path.join(repoRootPath, 'app', 'function_runtime', 'Dockerfile'), 'utf8')
    const sources = dockerfile
      .split('\n')
      .filter(line => line.startsWith('COPY ') && !line.includes('--from='))
      .flatMap(line => line.split(/\s+/).slice(1, -1))

    expect(sources.length).toBeGreaterThan(0)
    for (const source of sources) {
      expect(functionRuntimeInputRoots.some(root => source === root || source.startsWith(`${root}/`))).toBe(true)
    }
  })

  test('reuses a published edge-runtime binary only when the native stage recipe matches', () => {
    const current = readFileSync(path.join(repoRootPath, 'app', 'function_runtime', 'Dockerfile'), 'utf8')
    const modifiedTypeScriptStage = current.replace('FROM oven/bun:1.4.4 AS build', 'FROM oven/bun:1.4.5 AS build')
    const modifiedNativeStage = current.replace(
      'FROM rust:1.99.1-bookworm AS native',
      'FROM rust:1.98.0-bookworm AS native'
    )

    expect(extractNativeStageRecipe(current)).toContain('FROM rust:1.99.1-bookworm AS native')
    expect(canReuseEdgeRuntimeBinary(modifiedTypeScriptStage, current)).toBe(true)
    expect(canReuseEdgeRuntimeBinary(modifiedNativeStage, current)).toBe(false)
    expect(canReuseEdgeRuntimeBinary(null, current)).toBe(false)
  })

  test('verifies the revision label on published Function Runtime images', () => {
    const revision = 'd'.repeat(40)

    expect(() =>
      assertPublishedFunctionRuntimeLabels({ 'org.opencontainers.image.revision': revision }, revision)
    ).not.toThrow()
    expect(() =>
      assertPublishedFunctionRuntimeLabels({ 'org.opencontainers.image.revision': 'e'.repeat(40) }, revision)
    ).toThrow('does not declare revision')
  })
})
