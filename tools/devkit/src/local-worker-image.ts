import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'

import { repoRootPath, runChild, runChildCaptured } from './utils'

export type LocalWorkerImageScope = 'source-mounted' | 'complete'

const upstreamWorkerRepository = 'ghcr.io/agentbull/ankole-agent-computer-worker'
const localWorkerRepository = 'ankole-agent-computer'
const inputHashLabel = 'io.ankole.local-worker.input-hash'
const inputScopeLabel = 'io.ankole.local-worker.input-scope'
const internalInputHashLabel = 'io.ankole.local-worker.internal-input-hash'
const internalBaseImageLabel = 'io.ankole.local-worker.internal-base-image'
const releaseRevisionLabel = 'org.opencontainers.image.revision'
const baseDigestLabel = 'io.ankole.agent-os-base.digest'
const workerBaseImageLock = path.join(repoRootPath, 'app', 'agent_computer', 'base-image.lock')
const internalRoot = path.join(repoRootPath, 'internals')
const internalWorkerDockerfile = path.join(internalRoot, 'Dockerfile.financial-data-computer')

const sharedInputRoots = [
  '.dockerignore',
  'app/agent_computer/Dockerfile',
  'app/agent_computer/base-image.lock',
  'app/agent_computer/matplotlibrc',
  'app/agent_computer/package.json',
  'app/agent_computer/tsconfig.json',
  'app/ankole-browser',
  'app/kernel',
  'app/library',
  'package.json',
  'bun.lock',
  'tsconfig.base.json'
]

export async function resolveLocalWorkerImage(options: {
  scope: LocalWorkerImageScope
  allowBuild: boolean
}): Promise<string> {
  await requireDocker()

  const baseImage = await resolveBaseWorkerImage(options)
  if (!existsSync(internalWorkerDockerfile)) return baseImage

  return resolveInternalWorkerImage(baseImage, options)
}

async function resolveBaseWorkerImage(options: { scope: LocalWorkerImageScope; allowBuild: boolean }): Promise<string> {
  const baseImage = readWorkerBaseImageLock()
  if (await workerInputsMatchHEAD(options.scope)) {
    const revision = await headRevision()
    const upstreamImage = `${upstreamWorkerRepository}:${revision}`
    if (await pullAndVerifyUpstreamImage(upstreamImage, revision)) return upstreamImage
  }

  const inputHash = await workerImageInputHash(options.scope)
  const localImage = localWorkerImageRef(options.scope, inputHash)
  if (await localImageMatches(localImage, options.scope, inputHash)) return localImage

  if (!options.allowBuild) {
    throw new Error(`Worker image ${localImage} is missing and local builds are disabled.`)
  }

  await runChild('docker', buildWorkerImageBuildArgs(localImage, options.scope, inputHash, baseImage), {
    cwd: repoRootPath
  })
  if (!(await localImageMatches(localImage, options.scope, inputHash))) {
    throw new Error(`Docker built ${localImage} without the requested Worker input identity`)
  }
  return localImage
}

async function resolveInternalWorkerImage(
  baseImage: string,
  options: { scope: LocalWorkerImageScope; allowBuild: boolean }
): Promise<string> {
  const inputHash = await internalWorkerInputHash(baseImage)
  const image = internalWorkerImageRef(options.scope, inputHash)
  if (await internalImageMatches(image, baseImage, inputHash)) return image

  if (!options.allowBuild) {
    throw new Error(`Internal Worker image ${image} is missing and local builds are disabled.`)
  }

  await runChild('docker', buildInternalWorkerImageBuildArgs(image, baseImage, inputHash), {
    cwd: repoRootPath
  })
  if (!(await internalImageMatches(image, baseImage, inputHash))) {
    throw new Error(`Docker built ${image} without the requested internal Worker input identity`)
  }
  return image
}

export async function workerImageInputHash(scope: LocalWorkerImageScope): Promise<string> {
  const files = await workerImageInputFiles(scope)
  const hash = createHash('sha256')

  for (const file of files.toSorted()) {
    hash.update(file)
    hash.update('\0')
    hash.update(readFileSync(path.join(repoRootPath, file)))
    hash.update('\0')
  }

  return hash.digest('hex')
}

export function localWorkerImageRef(scope: LocalWorkerImageScope, inputHash: string): string {
  if (!/^[0-9a-f]{64}$/.test(inputHash)) throw new Error('Worker image input hash must be sha256')
  return `${localWorkerRepository}:local-${scope}-${inputHash}`
}

export function internalWorkerImageRef(scope: LocalWorkerImageScope, inputHash: string): string {
  if (!/^[0-9a-f]{64}$/.test(inputHash)) throw new Error('Internal Worker image input hash must be sha256')
  return `${localWorkerRepository}:local-internal-${scope}-${inputHash}`
}

export function buildWorkerImageBuildArgs(
  image: string,
  scope: LocalWorkerImageScope,
  inputHash: string,
  baseImage: string
): string[] {
  return [
    'build',
    '--build-arg',
    `BASE_IMAGE=${baseImage}`,
    '--label',
    `${inputHashLabel}=${inputHash}`,
    '--label',
    `${inputScopeLabel}=${scope}`,
    '-f',
    path.join(repoRootPath, 'app', 'agent_computer', 'Dockerfile'),
    '-t',
    image,
    repoRootPath
  ]
}

export function buildInternalWorkerImageBuildArgs(image: string, baseImage: string, inputHash: string): string[] {
  return [
    'build',
    '--build-arg',
    `ANKOLE_AGENT_COMPUTER_BASE_IMAGE=${baseImage}`,
    '--label',
    `${internalInputHashLabel}=${inputHash}`,
    '--label',
    `${internalBaseImageLabel}=${baseImage}`,
    '-f',
    internalWorkerDockerfile,
    '-t',
    image,
    repoRootPath
  ]
}

async function internalWorkerInputHash(baseImage: string): Promise<string> {
  const result = await runChildCaptured('git', ['ls-files', '-co', '--exclude-standard', '-z'], {
    cwd: internalRoot
  })
  if (result.status !== 0) {
    throw new Error(`git ls-files failed while hashing internal Worker inputs: ${result.stderr || result.stdout}`)
  }

  const files = result.stdout
    .split('\0')
    .filter(Boolean)
    .filter(file => existsSync(path.join(internalRoot, file)))
  const hash = createHash('sha256')
  hash.update(baseImage)
  hash.update('\0')

  for (const file of files.toSorted()) {
    hash.update(file)
    hash.update('\0')
    hash.update(readFileSync(path.join(internalRoot, file)))
    hash.update('\0')
  }

  return hash.digest('hex')
}

async function workerImageInputFiles(scope: LocalWorkerImageScope): Promise<string[]> {
  const result = await runChildCaptured(
    'git',
    ['ls-files', '-co', '--exclude-standard', '-z', '--', ...workerInputRoots(scope)],
    { cwd: repoRootPath }
  )
  if (result.status !== 0) {
    throw new Error(`git ls-files failed while hashing Worker image inputs: ${result.stderr || result.stdout}`)
  }

  return result.stdout
    .split('\0')
    .filter(Boolean)
    .filter(file => existsSync(path.join(repoRootPath, file)))
}

async function workerInputsMatchHEAD(scope: LocalWorkerImageScope): Promise<boolean> {
  const roots = workerInputRoots(scope).filter(root => root !== 'app/agent_computer/base-image.lock')
  const changed = await runChildCaptured('git', ['diff', '--name-only', '-z', 'HEAD', '--', ...roots], {
    cwd: repoRootPath
  })
  if (changed.status !== 0) throw new Error(`git diff failed: ${changed.stderr || changed.stdout}`)
  if (changed.stdout.length > 0) return false

  const untracked = await runChildCaptured(
    'git',
    ['ls-files', '--others', '--exclude-standard', '-z', '--', ...roots],
    {
      cwd: repoRootPath
    }
  )
  if (untracked.status !== 0) throw new Error(`git ls-files failed: ${untracked.stderr || untracked.stdout}`)
  return untracked.stdout.length === 0
}

function workerInputRoots(scope: LocalWorkerImageScope): string[] {
  return scope === 'complete' ? [...sharedInputRoots, 'app/agent_computer/src'] : sharedInputRoots
}

async function headRevision(): Promise<string> {
  const result = await runChildCaptured('git', ['rev-parse', 'HEAD'], { cwd: repoRootPath })
  const revision = result.stdout.trim()
  if (result.status !== 0 || !/^[0-9a-f]{40}$/.test(revision)) {
    throw new Error(`could not resolve the current Git revision: ${result.stderr || result.stdout}`)
  }
  return revision
}

export function assertPublishedWorkerLabels(labels: Record<string, string>, revision: string): void {
  if (labels[releaseRevisionLabel] !== revision) {
    throw new Error(`Published Worker image does not declare revision ${revision}`)
  }
  if (!/^sha256:[0-9a-f]{64}$/.test(labels[baseDigestLabel] ?? '')) {
    throw new Error('Published Worker image does not declare its Agent OS base digest')
  }
}

async function pullAndVerifyUpstreamImage(image: string, revision: string): Promise<boolean> {
  let labels = await dockerImageLabels(image)
  if (!labels) {
    const pull = await runChildCaptured('docker', ['pull', image], { cwd: repoRootPath })
    if (pull.status !== 0) return false
    labels = await dockerImageLabels(image)
  }
  if (!labels) throw new Error(`Docker pulled ${image} but cannot inspect it`)

  assertPublishedWorkerLabels(labels, revision)
  return true
}

async function localImageMatches(image: string, scope: LocalWorkerImageScope, inputHash: string): Promise<boolean> {
  const labels = await dockerImageLabels(image)
  return labels?.[inputHashLabel] === inputHash && labels[inputScopeLabel] === scope
}

async function internalImageMatches(image: string, baseImage: string, inputHash: string): Promise<boolean> {
  const labels = await dockerImageLabels(image)
  return labels?.[internalInputHashLabel] === inputHash && labels[internalBaseImageLabel] === baseImage
}

async function dockerImageLabels(image: string): Promise<Record<string, string> | null> {
  const result = await runChildCaptured('docker', ['image', 'inspect', '--format', '{{json .Config.Labels}}', image])
  if (result.status !== 0) return null

  const parsed: unknown = JSON.parse(result.stdout)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Worker image ${image} has invalid labels`)
  }
  return parsed as Record<string, string>
}

function readWorkerBaseImageLock(): string {
  const image = readFileSync(workerBaseImageLock, 'utf8').trim()
  if (!/^ghcr\.io\/agentbull\/ankole-agent-os-base@sha256:[0-9a-f]{64}$/.test(image)) {
    throw new Error(`Worker base image lock is invalid: ${workerBaseImageLock}`)
  }
  return image
}

async function requireDocker(): Promise<void> {
  const result = await runChildCaptured('docker', ['info'])
  if (result.status !== 0) {
    throw new Error('Docker daemon is not reachable; local Agent Computer work needs Docker.')
  }
}

async function runCLI(args: string[]): Promise<void> {
  const values = new Map<string, string>()
  let allowBuild = true

  for (let index = 0; index < args.length; index++) {
    const option = args[index]
    if (option === '--no-build') {
      allowBuild = false
      continue
    }
    if (option !== '--scope' && option !== '--output') throw usageError()

    const value = args[++index]
    if (!value || value.startsWith('--') || values.has(option)) throw usageError()
    values.set(option, value)
  }

  const scope = values.get('--scope')
  const output = values.get('--output')
  if ((scope !== 'source-mounted' && scope !== 'complete') || !output) throw usageError()

  const image = await resolveLocalWorkerImage({ scope, allowBuild })
  await Bun.write(output, `${image}\n`)
}

function usageError(): Error {
  return new Error('usage: local-worker-image.ts --scope source-mounted|complete --output FILE [--no-build]')
}

if (import.meta.main) await runCLI(process.argv.slice(2))
