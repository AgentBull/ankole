import { isAbsolute, relative, resolve, sep } from 'node:path'
import { requiredTextFrame } from './codec'
import type { FileAddress } from './types'
import type { WorkerConfig } from '../../worker/config'

const transferScratchDir = '.ankole-file-transfer'

export function resolveFileAddress(
  config: WorkerConfig,
  address: FileAddress,
  opts: { allowRoot?: boolean } = {}
): string {
  const rootPath = rootPathFor(config, address.root)
  const relativePath = normalizeRelativePath(address.relativePath, opts)
  const resolvedRoot = resolve(rootPath)
  const resolvedPath = resolve(resolvedRoot, relativePath)
  const rel = relative(resolvedRoot, resolvedPath)

  if ((!opts.allowRoot && rel === '') || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`relative_path escapes root: ${address.relativePath}`)
  }

  return resolvedPath
}

export function scratchDirectoryFor(config: WorkerConfig, transferId: string): string {
  const scratchRoot = resolve(config.sharedFsRoot, transferScratchDir)
  const tempDir = resolve(scratchRoot, safeTransferId(transferId))
  const rel = relative(scratchRoot, tempDir)

  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`transfer_id escapes scratch root: ${transferId}`)
  }

  return tempDir
}

export function rootPathFor(config: WorkerConfig, root: string): string {
  switch (root) {
    case 'user_files':
      return config.userFilesRoot
    case 'agent_installed_skills':
      return config.agentInstalledSkillsRoot
    case 'workspace_sessions':
      return config.workspaceSessionsRoot
    case 'codex_accounts':
      return resolve(config.sharedFsRoot, '.ankole', 'codex')
    default:
      throw new Error(`unsupported file root: ${root}`)
  }
}

export function parseVirtualPathFrame(
  frame: Buffer | undefined,
  label: string,
  opts: { allowRoot?: boolean } = {}
): FileAddress {
  const virtualPath = requiredTextFrame(frame, label)
  if (!virtualPath.startsWith('/')) {
    throw new Error(`${label} must be an absolute worker virtual path`)
  }

  const [root, ...segments] = virtualPath.slice(1).split('/')
  if (
    root !== 'user_files' &&
    root !== 'agent_installed_skills' &&
    root !== 'workspace_sessions' &&
    root !== 'codex_accounts'
  ) {
    throw new Error(`unsupported file root: ${root}`)
  }

  const relativePath = normalizeRelativePath(segments.join('/'), opts)
  return {
    root,
    relativePath,
    virtualPath: relativePath ? `/${root}/${relativePath}` : `/${root}`
  }
}

export function normalizeRelativePath(value: unknown, opts: { allowRoot?: boolean } = {}): string {
  if (typeof value !== 'string') {
    throw new Error('relative_path must be a string')
  }

  const withForwardSeparators = value.replaceAll('\\', '/')
  if (withForwardSeparators.startsWith('/')) {
    throw new Error(`relative_path must not be absolute: ${value}`)
  }

  const normalized = withForwardSeparators.replace(/\/+/g, '/')
  if (opts.allowRoot && (normalized.length === 0 || normalized === '.')) {
    return ''
  }
  if (
    normalized.length === 0 ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`invalid relative_path: ${value}`)
  }
  return normalized
}

export function safeTransferId(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value
}
