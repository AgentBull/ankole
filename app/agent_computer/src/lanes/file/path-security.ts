import { resolve } from 'node:path'
import { agentHomePaths } from '../../core/agent-home-paths'
import { relativePathWithin } from '../../core/path-boundary'
import {
  assertCreatablePathWithin,
  assertExistingPathWithin,
  canonicalExistingRoots
} from '../../core/real-path-boundary'
import type { AgentHomeConfig } from '../../worker/config'

const transferScratchRoot = '/tmp/ankole-file-transfer'

/**
 * The absolute path of one path inside the Agent Home of the bound Agent.
 *
 * The control plane names every transfer relative to the Agent Home of the
 * Worker that it calls, so the path never leaves that Agent Home.
 */
export function homePath(config: AgentHomeConfig, homeRelativePath: string): string {
  const home = agentHome(config)
  const path = resolve(home, normalizeRelativePath(homeRelativePath))
  const rel = relativePathWithin(home, path)

  if (rel === undefined || rel === '') {
    throw new Error(`home_relative_path escapes the Agent Home: ${homeRelativePath}`)
  }

  return path
}

export function assertExistingHomePath(config: AgentHomeConfig, path: string, homeRelativePath: string): string {
  return assertExistingPathWithin(
    canonicalExistingRoots([agentHome(config)]),
    path,
    `path resolves outside the Agent Home: ${homeRelativePath}`
  )
}

export function assertCreatableHomePath(config: AgentHomeConfig, path: string, homeRelativePath: string): string {
  return assertCreatablePathWithin(
    canonicalExistingRoots([agentHome(config)]),
    path,
    `path resolves outside the Agent Home: ${homeRelativePath}`
  )
}

export function scratchDirectoryFor(transferID: string): string {
  const scratchRoot = resolve(transferScratchRoot)
  const tempDir = resolve(scratchRoot, safeTransferID(transferID))
  const rel = relativePathWithin(scratchRoot, tempDir)

  if (rel === undefined || rel === '') {
    throw new Error(`transfer_id escapes scratch root: ${transferID}`)
  }

  return tempDir
}

export function normalizeRelativePath(value: unknown): string {
  if (typeof value !== 'string') {
    throw new Error('home_relative_path must be a string')
  }

  const withForwardSeparators = value.replaceAll('\\', '/')
  if (withForwardSeparators.startsWith('/')) {
    throw new Error(`home_relative_path must not be absolute: ${value}`)
  }

  const normalized = withForwardSeparators.replace(/\/+/g, '/')
  if (
    normalized.length === 0 ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`invalid home_relative_path: ${value}`)
  }
  return normalized
}

export function safeTransferID(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value
}

function agentHome(config: AgentHomeConfig): string {
  return resolve(agentHomePaths(config.agentHomeRoot).home)
}
