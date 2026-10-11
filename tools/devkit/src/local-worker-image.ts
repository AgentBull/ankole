import { createHash } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { isRecord } from '@agentbull/active-support'

import { ChildProcessExitError, repoRootPath, runChild, runChildCaptured, styledWarn } from './utils'

export type LocalWorkerImageScope = 'source-mounted' | 'complete'

/** The Agent OS base of local Worker builds, and the commit whose Dockerfile.base built it. */
export type WorkerBaseImageLock = { image: string; revision: string }

const upstreamWorkerRepository = 'ghcr.io/agentbull/ankole-agent-computer-worker'
const localWorkerRepository = 'ankole-agent-computer'
const baseImageRepository = 'ghcr.io/agentbull/ankole-agent-os-base'
const inputHashLabel = 'io.ankole.local-worker.input-hash'
const inputScopeLabel = 'io.ankole.local-worker.input-scope'
const releaseRevisionLabel = 'org.opencontainers.image.revision'
const baseDigestLabel = 'io.ankole.agent-os-base.digest'
const workerBaseImageLock = path.join(repoRootPath, 'app', 'agent_computer', 'base-image.lock')
const workerBaseDockerfile = 'app/agent_computer/Dockerfile.base'

const sharedInputRoots = [
  '.dockerignore',
  'app/agent_computer/Dockerfile',
  'app/agent_computer/base-image.lock',
  'app/agent_computer/matplotlibrc',
  'app/agent_computer/package.json',
  'app/agent_computer/scripts',
  'app/agent_computer/tsconfig.json',
  'app/ankole-browser',
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

  const baseImage = readWorkerBaseImageLock()
  if (await workerInputsMatchHEAD(options.scope)) {
    const revision = await headRevision()
    const upstreamImage = `${upstreamWorkerRepository}:${revision}`
    if (await pullAndVerifyUpstreamImage(upstreamImage, revision)) return upstreamImage
  }

  await warnIfBaseImageLockIsStale(baseImage)
  const inputHash = await workerImageInputHash(options.scope)
  const localImage = localWorkerImageRef(options.scope, inputHash)
  if (await localImageMatches(localImage, options.scope, inputHash)) return localImage

  if (!options.allowBuild) {
    throw new Error(`Worker image ${localImage} is missing and local builds are disabled.`)
  }

  await runChild('docker', buildWorkerImageBuildArgs(localImage, options.scope, inputHash, baseImage.image), {
    cwd: repoRootPath
  })
  if (!(await localImageMatches(localImage, options.scope, inputHash))) {
    throw new Error(`Docker built ${localImage} without the requested Worker input identity`)
  }
  return localImage
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

export function workerInputRoots(scope: LocalWorkerImageScope): string[] {
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
    // The published Worker image is gigabytes, so a captured pull prints
    // nothing for minutes and reads as a hung startup. Stream Docker's own
    // progress. A failed pull stays a normal outcome: the caller builds the
    // local image instead.
    try {
      await runChild('docker', ['pull', image], { cwd: repoRootPath })
    } catch (error) {
      if (error instanceof ChildProcessExitError) return false
      throw error
    }
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

async function dockerImageLabels(image: string): Promise<Record<string, string> | null> {
  const result = await runChildCaptured('docker', ['image', 'inspect', '--format', '{{json .Config.Labels}}', image])
  if (result.status !== 0) return null

  const parsed: unknown = JSON.parse(result.stdout)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Worker image ${image} has invalid labels`)
  }
  return parsed as Record<string, string>
}

function readWorkerBaseImageLock(): WorkerBaseImageLock {
  const image = readFileSync(workerBaseImageLock, 'utf8').trim()
  const revision = /^ghcr\.io\/agentbull\/ankole-agent-os-base:([0-9a-f]{40})@sha256:[0-9a-f]{64}$/.exec(image)?.[1]
  if (!revision) throw new Error(`Worker base image lock is invalid: ${workerBaseImageLock}`)
  return { image, revision }
}

/**
 * Pins the Agent OS base that the runtime-images workflow published for a
 * commit. The commit must be in the history of HEAD and have the
 * Dockerfile.base of HEAD, so the lock cannot name a base of another recipe.
 */
export async function pinWorkerBaseImage(revisionName: string): Promise<WorkerBaseImageLock> {
  const revision = await gitOutput(['rev-parse', '--verify', '--quiet', `${revisionName}^{commit}`])
  if (!revision) throw new Error(`${revisionName} is not a commit`)
  if ((await gitOutput(['merge-base', '--is-ancestor', revision, 'HEAD'])) === null) {
    throw new Error(`${revision} is not in the history of HEAD`)
  }

  const [recipe, headRecipe] = await Promise.all([committedBaseRecipe(revision), committedBaseRecipe('HEAD')])
  if (recipe !== headRecipe) {
    throw new Error(
      `${revision} has a different ${workerBaseDockerfile} than HEAD; pin a commit that has the current one`
    )
  }

  const lock = { image: `${baseImageRepository}:${revision}@${await publishedBaseDigest(revision)}`, revision }
  writeFileSync(workerBaseImageLock, `${lock.image}\n`)
  return lock
}

/** Warns when the pinned base was built from a Dockerfile.base other than the one in the working tree. */
export async function warnIfBaseImageLockIsStale(lock: WorkerBaseImageLock): Promise<void> {
  const [pinnedRecipe, currentRecipe] = await Promise.all([
    committedBaseRecipe(lock.revision),
    gitOutput(['hash-object', '--', workerBaseDockerfile])
  ])
  if (pinnedRecipe === currentRecipe) return

  const pin = `app/agent_computer/base-image.lock pins the Agent OS base of commit ${lock.revision.slice(0, 9)}`
  console.warn(
    styledWarn(
      pinnedRecipe === null
        ? `${pin}, which is not in the local Git history, so devkit cannot compare it with ${workerBaseDockerfile}.`
        : `${pin}, which has a different ${workerBaseDockerfile}. Local Worker images build on that base until ` +
            `\`bun run kit pin-base-image\` pins the base that CI publishes for the current one.`
    )
  )
}

function committedBaseRecipe(revision: string): Promise<string | null> {
  return gitOutput(['rev-parse', '--verify', '--quiet', `${revision}:${workerBaseDockerfile}`])
}

async function publishedBaseDigest(revision: string): Promise<string> {
  const image = `${baseImageRepository}:${revision}`
  const result = await runChildCaptured('docker', [
    'buildx',
    'imagetools',
    'inspect',
    image,
    '--format',
    '{{json .Manifest}}'
  ])
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || result.error?.message || '').trim()
    throw new Error(
      `cannot read ${image}; CI publishes it when its runtime-images workflow builds that commit: ${detail}`
    )
  }

  const manifest: unknown = JSON.parse(result.stdout)
  const digest = isRecord(manifest) ? manifest.digest : undefined
  if (typeof digest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(digest)) {
    throw new Error(`${image} has no sha256 manifest digest`)
  }
  return digest
}

async function gitOutput(args: string[]): Promise<string | null> {
  const result = await runChildCaptured('git', args, { cwd: repoRootPath })
  return result.status === 0 ? result.stdout.trim() : null
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
