import { resolve } from 'node:path'
import { relativePathWithin } from '../../core/path-boundary'
import {
  assertCreatablePathWithin,
  assertExistingPathWithin,
  canonicalExistingRoots
} from '../../core/real-path-boundary'
import { requiredTextFrame } from './codec'
import { assertFileRootContract, isFileRoot, rootPathFor } from './roots'
import type { FileAddress } from './types'
import type { WorkerConfig } from '../../worker/config'

const transferScratchRoot = '/tmp/ankole-file-transfer'

export function resolveFileAddress(
  config: WorkerConfig,
  address: FileAddress,
  opts: { allowRoot?: boolean } = {}
): string {
  const rootPath = rootPathFor(config, address.root)
  const relativePath = normalizeRelativePath(address.relativePath, opts)
  if (!relativePath) throw new Error(`${address.root} requires an Agent-scoped path`)
  assertFileRootContract(address.root, relativePath)
  const resolvedRoot = resolve(rootPath)
  const resolvedPath = resolve(resolvedRoot, relativePath)
  const rel = relativePathWithin(resolvedRoot, resolvedPath)

  if (rel === undefined || (!opts.allowRoot && rel === '')) {
    throw new Error(`relative_path escapes root: ${address.relativePath}`)
  }

  return resolvedPath
}

export function assertExistingFileAddress(config: WorkerConfig, address: FileAddress, path: string): string {
  return assertExistingPathWithin(
    canonicalExistingRoots([rootPathFor(config, address.root)]),
    path,
    `path resolves outside root: ${address.virtualPath}`
  )
}

export function assertCreatableFileAddress(config: WorkerConfig, address: FileAddress, path: string): string {
  return assertCreatablePathWithin(
    canonicalExistingRoots([rootPathFor(config, address.root)]),
    path,
    `path resolves outside root: ${address.virtualPath}`
  )
}

export function scratchDirectoryFor(config: WorkerConfig, transferID: string): string {
  const scratchRoot = resolve(transferScratchRoot)
  const tempDir = resolve(scratchRoot, safeTransferID(transferID))
  const rel = relativePathWithin(scratchRoot, tempDir)

  if (rel === undefined || rel === '') {
    throw new Error(`transfer_id escapes scratch root: ${transferID}`)
  }

  return tempDir
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
  if (!isFileRoot(root)) {
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

export function safeTransferID(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value
}
