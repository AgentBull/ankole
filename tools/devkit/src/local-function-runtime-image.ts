import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'

import {
  ChildProcessExitError,
  loadAppDevelopmentEnv,
  repoRootPath,
  runChild,
  runChildCaptured,
  runCompose
} from './utils'

const upstreamFunctionRuntimeRepository = 'ghcr.io/agentbull/ankole-function-runtime'
const localFunctionRuntimeRepository = 'ankole-function-runtime'
const devFunctionRuntimeImage = `${localFunctionRuntimeRepository}:dev`
const inputHashLabel = 'io.ankole.local-function-runtime.input-hash'
const releaseRevisionLabel = 'org.opencontainers.image.revision'
const functionRuntimeDockerfile = 'app/function_runtime/Dockerfile'

export const functionRuntimeInputRoots = [
  '.dockerignore',
  functionRuntimeDockerfile,
  'app/function_runtime/native',
  'app/function_runtime/package.json',
  'app/function_runtime/main',
  'libs/applet-sdk/package.json',
  'libs/applet-sdk/src',
  'package.json',
  'bun.lock'
] as const

export type StartComposeServicesArgs = {
  pull?: boolean
  wait?: boolean
  waitTimeout?: number
  allowBuild?: boolean
}

/**
 * Brings up every service defined in the Compose file after resolving the
 * Function Runtime image from GHCR or a content-addressed local build.
 * Shared by `dev`, `external-services start`, and `app-db` so the startup paths
 * cannot drift.
 */
export async function startComposeServices({
  pull = false,
  wait = true,
  waitTimeout = 60,
  allowBuild = true
}: StartComposeServicesArgs = {}): Promise<void> {
  const devEnv = loadAppDevelopmentEnv()
  const functionRuntimeImage =
    devEnv.ANKOLE_DEV_FUNCTION_RUNTIME_IMAGE?.trim() || (await resolveLocalFunctionRuntimeImage({ allowBuild }))

  const args = ['up', '--detach', '--remove-orphans']
  if (pull) args.push('--pull', 'missing')
  if (wait) args.push('--wait', '--wait-timeout', String(waitTimeout))

  await runCompose(args, { ANKOLE_DEV_FUNCTION_RUNTIME_IMAGE: functionRuntimeImage })
}

/** Pre-pulls a matching published Function Runtime image when available. */
export async function prefetchFunctionRuntimeImage(): Promise<void> {
  await requireDocker()

  for (const revision of await candidatePublishedRevisions()) {
    if (!(await treeMatchesRevision(revision, functionRuntimeInputRoots))) continue
    const upstreamImage = `${upstreamFunctionRuntimeRepository}:${revision}`
    if (await pullAndVerifyUpstreamImage(upstreamImage, revision)) {
      await tagDevImage(upstreamImage)
      return
    }
  }
}

export async function resolveLocalFunctionRuntimeImage(options: { allowBuild: boolean }): Promise<string> {
  await requireDocker()

  const candidates = await candidatePublishedRevisions()
  for (const revision of candidates) {
    if (!(await treeMatchesRevision(revision, functionRuntimeInputRoots))) continue
    const upstreamImage = `${upstreamFunctionRuntimeRepository}:${revision}`
    if (await pullAndVerifyUpstreamImage(upstreamImage, revision)) {
      await tagDevImage(upstreamImage)
      return upstreamImage
    }
  }

  const inputHash = await functionRuntimeImageInputHash()
  const localImage = localFunctionRuntimeImageRef(inputHash)
  if (await localImageMatches(localImage, inputHash)) {
    await tagDevImage(localImage)
    return localImage
  }

  if (!options.allowBuild) {
    throw new Error(`Function Runtime image ${localImage} is missing and local builds are disabled.`)
  }

  const edgeRuntimeImage = await resolveEdgeRuntimeImage(candidates)
  await runChild('docker', buildFunctionRuntimeImageBuildArgs(localImage, inputHash, edgeRuntimeImage), {
    cwd: repoRootPath
  })
  if (!(await localImageMatches(localImage, inputHash))) {
    throw new Error(`Docker built ${localImage} without the requested Function Runtime input identity`)
  }

  await tagDevImage(localImage)
  return localImage
}

export function localFunctionRuntimeImageRef(inputHash: string): string {
  if (!/^[0-9a-f]{64}$/.test(inputHash)) throw new Error('Function Runtime image input hash must be sha256')
  return `${localFunctionRuntimeRepository}:local-${inputHash}`
}

export function buildFunctionRuntimeImageBuildArgs(
  image: string,
  inputHash: string,
  edgeRuntimeImage?: string
): string[] {
  return [
    'build',
    ...(edgeRuntimeImage ? ['--build-arg', `EDGE_RUNTIME_IMAGE=${edgeRuntimeImage}`] : []),
    '--label',
    `${inputHashLabel}=${inputHash}`,
    '-f',
    path.join(repoRootPath, functionRuntimeDockerfile),
    '-t',
    image,
    repoRootPath
  ]
}

export function extractNativeStageRecipe(dockerfile: string): string | null {
  const lines = dockerfile.replaceAll('\r\n', '\n').split('\n')
  const start = lines.findIndex(line => /^FROM\s+\S+\s+AS\s+native\s*$/i.test(line.trim()))
  if (start === -1) return null

  const end = lines.findIndex((line, index) => index > start && /^FROM\s+/i.test(line.trim()))
  const stageLines = end === -1 ? lines.slice(start) : lines.slice(start, end)
  return stageLines.join('\n').trim()
}

export function canReuseEdgeRuntimeBinary(committedDockerfile: string | null, currentDockerfile: string): boolean {
  if (!committedDockerfile) return false
  const committedStage = extractNativeStageRecipe(committedDockerfile)
  const currentStage = extractNativeStageRecipe(currentDockerfile)
  return Boolean(committedStage && currentStage && committedStage === currentStage)
}

export function assertPublishedFunctionRuntimeLabels(labels: Record<string, string>, revision: string): void {
  if (labels[releaseRevisionLabel] !== revision) {
    throw new Error(`Published Function Runtime image does not declare revision ${revision}`)
  }
}

async function resolveEdgeRuntimeImage(candidates: string[]): Promise<string | undefined> {
  const currentDockerfile = readFileSync(path.join(repoRootPath, functionRuntimeDockerfile), 'utf8')

  for (const revision of candidates) {
    const committedDockerfile = await gitOutput(['show', `${revision}:${functionRuntimeDockerfile}`])
    if (!canReuseEdgeRuntimeBinary(committedDockerfile, currentDockerfile)) continue
    if (!(await treeMatchesRevision(revision, ['app/function_runtime/native']))) continue

    const upstreamImage = `${upstreamFunctionRuntimeRepository}:${revision}`
    if (await pullAndVerifyUpstreamImage(upstreamImage, revision)) return upstreamImage
  }

  return undefined
}

async function functionRuntimeImageInputHash(): Promise<string> {
  const files = await functionRuntimeImageInputFiles()
  const hash = createHash('sha256')

  for (const file of files.toSorted()) {
    hash.update(file)
    hash.update('\0')
    hash.update(readFileSync(path.join(repoRootPath, file)))
    hash.update('\0')
  }

  return hash.digest('hex')
}

async function functionRuntimeImageInputFiles(): Promise<string[]> {
  const result = await runChildCaptured(
    'git',
    ['ls-files', '-co', '--exclude-standard', '-z', '--', ...functionRuntimeInputRoots],
    { cwd: repoRootPath }
  )
  if (result.status !== 0) {
    throw new Error(`git ls-files failed while hashing Function Runtime inputs: ${result.stderr || result.stdout}`)
  }

  return result.stdout
    .split('\0')
    .filter(Boolean)
    .filter(file => existsSync(path.join(repoRootPath, file)))
}

async function treeMatchesRevision(revision: string, roots: readonly string[]): Promise<boolean> {
  const changed = await runChildCaptured('git', ['diff', '--name-only', '-z', revision, '--', ...roots], {
    cwd: repoRootPath
  })
  if (changed.status !== 0) return false
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

async function candidatePublishedRevisions(): Promise<string[]> {
  const head = await gitOutput(['rev-parse', 'HEAD'])
  if (!head || !/^[0-9a-f]{40}$/.test(head)) {
    throw new Error('could not resolve the current Git revision')
  }

  const mergeBase = await gitOutput(['merge-base', 'HEAD', 'origin/main'])
  const latestReleaseTag = await gitOutput(['describe', '--tags', '--abbrev=0', '--match', 'v*', 'HEAD'])
  const releaseTagCommit = latestReleaseTag
    ? await gitOutput(['rev-parse', '--verify', '--quiet', `${latestReleaseTag}^{commit}`])
    : null

  const seen = new Set<string>()
  for (const candidate of [mergeBase, releaseTagCommit, head]) {
    if (candidate && /^[0-9a-f]{40}$/.test(candidate)) seen.add(candidate)
  }
  return [...seen]
}

async function pullAndVerifyUpstreamImage(image: string, revision: string): Promise<boolean> {
  let labels = await dockerImageLabels(image)
  if (!labels) {
    try {
      await runChild('docker', ['pull', image], { cwd: repoRootPath })
    } catch (error) {
      if (error instanceof ChildProcessExitError) return false
      throw error
    }
    labels = await dockerImageLabels(image)
  }
  if (!labels) throw new Error(`Docker pulled ${image} but cannot inspect it`)

  assertPublishedFunctionRuntimeLabels(labels, revision)
  return true
}

async function localImageMatches(image: string, inputHash: string): Promise<boolean> {
  const labels = await dockerImageLabels(image)
  return labels?.[inputHashLabel] === inputHash
}

async function tagDevImage(image: string): Promise<void> {
  if (image === devFunctionRuntimeImage) return
  await runChild('docker', ['tag', image, devFunctionRuntimeImage], { cwd: repoRootPath })
}

async function dockerImageLabels(image: string): Promise<Record<string, string> | null> {
  const result = await runChildCaptured('docker', ['image', 'inspect', '--format', '{{json .Config.Labels}}', image])
  if (result.status !== 0) return null

  const parsed: unknown = JSON.parse(result.stdout)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Function Runtime image ${image} has invalid labels`)
  }
  return parsed as Record<string, string>
}

async function gitOutput(args: string[]): Promise<string | null> {
  const result = await runChildCaptured('git', args, { cwd: repoRootPath })
  return result.status === 0 ? result.stdout.trim() : null
}

async function requireDocker(): Promise<void> {
  const result = await runChildCaptured('docker', ['info'])
  if (result.status !== 0) {
    throw new Error('Docker daemon is not reachable; local Function Runtime services need Docker.')
  }
}

async function runCLI(args: string[]): Promise<void> {
  let allowBuild = true
  let output: string | undefined

  for (let index = 0; index < args.length; index++) {
    const option = args[index]
    if (option === '--no-build') {
      allowBuild = false
      continue
    }
    if (option !== '--output') throw usageError()

    const value = args[++index]
    if (!value || value.startsWith('--') || output) throw usageError()
    output = value
  }

  const image = await resolveLocalFunctionRuntimeImage({ allowBuild })
  if (output) await Bun.write(output, `${image}\n`)
  else console.log(image)
}

function usageError(): Error {
  return new Error('usage: local-function-runtime-image.ts [--output FILE] [--no-build]')
}

if (import.meta.main) await runCLI(process.argv.slice(2))
