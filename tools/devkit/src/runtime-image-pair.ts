import { dirname } from 'node:path'
import { mkdir } from 'node:fs/promises'

export const runtimeFabricProtocolVersion = '2'
export const releaseRevisionLabel = 'org.opencontainers.image.revision'
export const pairRevisionLabel = 'io.ankole.runtime-image-pair.revision'
export const protocolVersionLabel = 'io.ankole.runtime-fabric.protocol-version'

const requiredPlatforms = ['linux/amd64', 'linux/arm64'] as const
const revisionPattern = /^[0-9a-f]{40}$/
const digestPattern = /^sha256:[0-9a-f]{64}$/

export type RuntimeImageComponent = 'control-plane' | 'worker'

export type VerifiedRuntimeImage = {
  component: RuntimeImageComponent
  source_ref: string
  pinned_ref: string
  digest: string
}

export type RuntimeImagePair = {
  schema_version: 1
  revision: string
  runtime_fabric_protocol_version: typeof runtimeFabricProtocolVersion
  control_plane: VerifiedRuntimeImage
  worker: VerifiedRuntimeImage
}

export type RuntimeImagePairStatus =
  | { ready: false; missing: RuntimeImageComponent[] }
  | { ready: true; pair: RuntimeImagePair }

export function runtimeImagePairStatus(input: {
  revision: string
  controlPlane?: { ref: string; metadata: unknown }
  worker?: { ref: string; metadata: unknown }
}): RuntimeImagePairStatus {
  assertRevision(input.revision)

  const controlPlane = input.controlPlane
    ? verifyRuntimeImage('control-plane', input.controlPlane.ref, input.controlPlane.metadata, input.revision)
    : undefined
  const worker = input.worker
    ? verifyRuntimeImage('worker', input.worker.ref, input.worker.metadata, input.revision)
    : undefined

  if (!controlPlane || !worker) {
    const missing: RuntimeImageComponent[] = []
    if (!controlPlane) missing.push('control-plane')
    if (!worker) missing.push('worker')
    return { ready: false, missing }
  }

  return {
    ready: true,
    pair: {
      schema_version: 1,
      revision: input.revision,
      runtime_fabric_protocol_version: runtimeFabricProtocolVersion,
      control_plane: controlPlane,
      worker
    }
  }
}

export function renderRuntimePairHelmValues(pair: RuntimeImagePair, rolloutPhase: 'control-plane' | 'worker'): string {
  return [
    'runtimeFabric:',
    `  releaseRevision: ${JSON.stringify(pair.revision)}`,
    `  rolloutPhase: ${JSON.stringify(rolloutPhase)}`,
    'controlPlane:',
    '  image:',
    `    name: ${JSON.stringify(pair.control_plane.pinned_ref)}`,
    'worker:',
    '  image:',
    `    name: ${JSON.stringify(pair.worker.pinned_ref)}`,
    ''
  ].join('\n')
}

function verifyRuntimeImage(
  component: RuntimeImageComponent,
  ref: string,
  metadata: unknown,
  expectedRevision: string
): VerifiedRuntimeImage {
  const repository = repositoryForReleaseRef(ref, expectedRevision)
  const document = requireRecord(metadata, `${component} metadata`)
  const manifest = requireRecord(document.manifest, `${component} manifest`)
  const digest = requireString(manifest.digest, `${component} manifest digest`)
  if (!digestPattern.test(digest)) throw new Error(`${component} manifest digest is not sha256`)

  const images = requireRecord(document.image, `${component} platform images`)
  for (const platform of requiredPlatforms) {
    const platformImage = requireRecord(images[platform], `${component} ${platform} image`)
    const config = requireRecord(platformImage.config, `${component} ${platform} config`)
    const labels = requireRecord(config.Labels, `${component} ${platform} labels`)

    requireExpectedLabel(component, platform, labels, releaseRevisionLabel, expectedRevision)
    requireExpectedLabel(component, platform, labels, pairRevisionLabel, expectedRevision)
    requireExpectedLabel(component, platform, labels, protocolVersionLabel, runtimeFabricProtocolVersion)
  }

  return {
    component,
    source_ref: ref,
    pinned_ref: `${repository}@${digest}`,
    digest
  }
}

function repositoryForReleaseRef(ref: string, revision: string): string {
  const suffix = `:${revision}`
  if (ref.includes('@') || !ref.endsWith(suffix)) {
    throw new Error(`runtime image ref must use the paired revision tag ${suffix}`)
  }

  const repository = ref.slice(0, -suffix.length)
  if (!repository || repository.endsWith(':')) throw new Error('runtime image repository is invalid')
  return repository
}

function requireExpectedLabel(
  component: RuntimeImageComponent,
  platform: string,
  labels: Record<string, unknown>,
  key: string,
  expected: string
): void {
  const actual = labels[key]
  if (actual !== expected) {
    throw new Error(`${component} ${platform} label ${key} must be ${expected}; got ${String(actual)}`)
  }
}

function assertRevision(revision: string): void {
  if (!revisionPattern.test(revision)) throw new Error('release revision must be a 40-character lowercase Git SHA')
}

function requireRecord(value: unknown, name: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${name} is missing`)
  return value as Record<string, unknown>
}

function requireString(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${name} is missing`)
  return value
}

type CliOptions = {
  revision: string
  controlPlaneRef: string
  controlPlaneMetadata: string
  workerRef: string
  workerMetadata: string
  pairOutput: string
  controlPlaneValuesOutput: string
  workerValuesOutput: string
}

async function runCli(args: string[]): Promise<void> {
  const [command, ...rest] = args
  if (command !== 'verify') throw new Error('usage: runtime-image-pair.ts verify [options]')

  const options = parseCliOptions(rest)
  const status = runtimeImagePairStatus({
    revision: options.revision,
    controlPlane: {
      ref: options.controlPlaneRef,
      metadata: await Bun.file(options.controlPlaneMetadata).json()
    },
    worker: {
      ref: options.workerRef,
      metadata: await Bun.file(options.workerMetadata).json()
    }
  })

  if (!status.ready) throw new Error(`runtime image pair is incomplete: ${status.missing.join(', ')}`)

  await Promise.all([
    writeOutput(options.pairOutput, `${JSON.stringify(status.pair, null, 2)}\n`),
    writeOutput(options.controlPlaneValuesOutput, renderRuntimePairHelmValues(status.pair, 'control-plane')),
    writeOutput(options.workerValuesOutput, renderRuntimePairHelmValues(status.pair, 'worker'))
  ])
}

function parseCliOptions(args: string[]): CliOptions {
  const values = new Map<string, string>()
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index]
    const value = args[index + 1]
    if (!key?.startsWith('--') || !value) throw new Error(`invalid option near ${key ?? '<end>'}`)
    values.set(key.slice(2), value)
  }

  return {
    revision: requiredOption(values, 'revision'),
    controlPlaneRef: requiredOption(values, 'control-plane-ref'),
    controlPlaneMetadata: requiredOption(values, 'control-plane-metadata'),
    workerRef: requiredOption(values, 'worker-ref'),
    workerMetadata: requiredOption(values, 'worker-metadata'),
    pairOutput: requiredOption(values, 'pair-output'),
    controlPlaneValuesOutput: requiredOption(values, 'control-plane-values-output'),
    workerValuesOutput: requiredOption(values, 'worker-values-output')
  }
}

function requiredOption(values: Map<string, string>, key: string): string {
  const value = values.get(key)
  if (!value) throw new Error(`--${key} is required`)
  return value
}

async function writeOutput(path: string, content: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  await Bun.write(path, content)
}

if (import.meta.main) {
  await runCli(process.argv.slice(2))
}
