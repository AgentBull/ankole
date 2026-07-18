import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  pairRevisionLabel,
  protocolVersionLabel,
  releaseRevisionLabel,
  renderRuntimePairHelmValues,
  runtimeFabricProtocolVersion,
  runtimeImagePairStatus
} from './runtime-image-pair'

const revision = 'a'.repeat(40)

function metadata(digestCharacter: string) {
  const labels = {
    [releaseRevisionLabel]: revision,
    [pairRevisionLabel]: revision,
    [protocolVersionLabel]: runtimeFabricProtocolVersion
  }

  return {
    manifest: { digest: `sha256:${digestCharacter.repeat(64)}` },
    image: {
      'linux/amd64': { config: { Labels: { ...labels } } },
      'linux/arm64': { config: { Labels: { ...labels } } }
    }
  }
}

const controlPlane = {
  ref: `ghcr.io/agentbull/ankole-agent-control-plane:${revision}`,
  metadata: metadata('1')
}
const worker = {
  ref: `ghcr.io/agentbull/ankole-agent-computer-worker:${revision}`,
  metadata: metadata('2')
}

describe('runtime image pair rollout gate', () => {
  test('stays closed when control plane publishes first and opens only after the matching worker arrives', () => {
    expect(runtimeImagePairStatus({ revision, controlPlane })).toEqual({ ready: false, missing: ['worker'] })

    const complete = runtimeImagePairStatus({ revision, controlPlane, worker })
    expect(complete.ready).toBe(true)
  })

  test('stays closed when worker publishes first and opens only after the matching control plane arrives', () => {
    expect(runtimeImagePairStatus({ revision, worker })).toEqual({ ready: false, missing: ['control-plane'] })

    const complete = runtimeImagePairStatus({ revision, controlPlane, worker })
    expect(complete.ready).toBe(true)
  })

  test('fails closed on a stale revision, protocol, or missing architecture', () => {
    const staleRevision = metadata('3')
    staleRevision.image['linux/arm64'].config.Labels[releaseRevisionLabel] = 'b'.repeat(40)
    expect(() =>
      runtimeImagePairStatus({ revision, controlPlane: { ...controlPlane, metadata: staleRevision } })
    ).toThrow(/must be a{40}/)

    const staleProtocol = metadata('4')
    staleProtocol.image['linux/amd64'].config.Labels[protocolVersionLabel] = '1'
    expect(() => runtimeImagePairStatus({ revision, worker: { ...worker, metadata: staleProtocol } })).toThrow(
      /must be 2/
    )

    const missingArchitecture = metadata('5')
    delete (missingArchitecture.image as Record<string, unknown>)['linux/arm64']
    expect(() =>
      runtimeImagePairStatus({ revision, controlPlane: { ...controlPlane, metadata: missingArchitecture } })
    ).toThrow(/linux\/arm64 image is missing/)
  })

  test('renders digest-pinned values for the two ordered Helm phases', () => {
    const status = runtimeImagePairStatus({ revision, controlPlane, worker })
    if (!status.ready) throw new Error('fixture pair must be ready')

    const controlPlaneValues = renderRuntimePairHelmValues(status.pair, 'control-plane')
    const workerValues = renderRuntimePairHelmValues(status.pair, 'worker')

    expect(controlPlaneValues).toContain(`releaseRevision: "${revision}"`)
    expect(controlPlaneValues).toContain('rolloutPhase: "control-plane"')
    expect(controlPlaneValues).toContain(`control-plane@sha256:${'1'.repeat(64)}`)
    expect(workerValues).toContain('rolloutPhase: "worker"')
    expect(workerValues).toContain(`worker@sha256:${'2'.repeat(64)}`)
    expect(controlPlaneValues).not.toContain('main-latest')
  })

  test('runs the workflow CLI and writes the complete deployment artifact', async () => {
    const outputRoot = mkdtempSync(join(tmpdir(), 'ankole-runtime-pair-'))
    const entrypoint = fileURLToPath(new URL('./runtime-image-pair.ts', import.meta.url))
    const controlPlaneMetadata = join(outputRoot, 'control-plane.json')
    const workerMetadata = join(outputRoot, 'worker.json')
    const pairOutput = join(outputRoot, 'pair', 'runtime-image-pair.json')
    const controlPlaneValuesOutput = join(outputRoot, 'pair', 'control-plane.values.yaml')
    const workerValuesOutput = join(outputRoot, 'pair', 'worker.values.yaml')

    try {
      writeFileSync(controlPlaneMetadata, JSON.stringify(controlPlane.metadata))
      writeFileSync(workerMetadata, JSON.stringify(worker.metadata))

      const result = Bun.spawnSync([
        process.execPath,
        entrypoint,
        'verify',
        '--revision',
        revision,
        '--control-plane-ref',
        controlPlane.ref,
        '--control-plane-metadata',
        controlPlaneMetadata,
        '--worker-ref',
        worker.ref,
        '--worker-metadata',
        workerMetadata,
        '--pair-output',
        pairOutput,
        '--control-plane-values-output',
        controlPlaneValuesOutput,
        '--worker-values-output',
        workerValuesOutput
      ])

      expect(result.exitCode).toBe(0)
      expect((await Bun.file(pairOutput).json()).revision).toBe(revision)
      expect(await Bun.file(controlPlaneValuesOutput).text()).toContain('rolloutPhase: "control-plane"')
      expect(await Bun.file(workerValuesOutput).text()).toContain('rolloutPhase: "worker"')
    } finally {
      rmSync(outputRoot, { recursive: true, force: true })
    }
  })

  test('has one main push workflow and no independent control-plane or worker publisher', async () => {
    const workflows = fileURLToPath(new URL('../../../.github/workflows/', import.meta.url))
    const pairedWorkflow = Bun.file(`${workflows}/runtime-images.yml`)
    const e2eRunner = Bun.file(fileURLToPath(new URL('../../../tools/e2e/run', import.meta.url)))
    const kernelSource = await Bun.file(
      fileURLToPath(new URL('../../../app/kernel/src/runtime_fabric/mod.rs', import.meta.url))
    ).text()

    expect(await pairedWorkflow.exists()).toBe(true)
    expect(await Bun.file(`${workflows}/control-plane-image.yml`).exists()).toBe(false)
    expect(await Bun.file(`${workflows}/agent-computer-images.yml`).exists()).toBe(false)

    const source = await pairedWorkflow.text()
    const kernelProtocol = kernelSource.match(/pub const PROTOCOL_VERSION: u32 = (\d+);/)?.[1]
    expect(kernelProtocol).toBe(runtimeFabricProtocolVersion)
    expect(source).toContain('branches: [main]')
    expect(source).toContain('Publish verified RuntimeFabric image pair')
    expect(source).toContain('needs:\n      - publish_control_plane\n      - publish_worker')
    expect(source).toContain('Read RuntimeFabric protocol version')
    expect(source).not.toContain('changed_files')
    expect(source).not.toContain('main-latest')

    const e2eSource = await e2eRunner.text()
    expect(e2eSource).toContain('app/agent_computer/base-image.lock')
    expect(e2eSource).toContain('--build-arg "BASE_IMAGE=$base_image"')
    expect(e2eSource).not.toContain('main-latest')
  })
})
