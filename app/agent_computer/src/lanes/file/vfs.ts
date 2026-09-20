import { existsSync, lstatSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { rename, unlink } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { forgetFingerprint, forgetFingerprintTree } from './fingerprint'
import { assertCreatableFileAddress, assertExistingFileAddress, fileAddress, resolveFileAddress } from './path-security'
import type { FileAddress, FileLaneState, ListEntry } from './types'
import type { WorkerConfig } from '../../worker/config'

export type DeleteResult = {
  address: FileAddress
}

export type MoveResult = {
  from: FileAddress
  to: FileAddress
}

export type ListResult = {
  address: FileAddress
  recursive: boolean
  truncated: boolean
  entries: ListEntry[]
}

export async function deletePath(
  config: WorkerConfig,
  state: FileLaneState,
  root: string,
  relativePath: string,
  recursive: boolean
): Promise<DeleteResult> {
  const address = fileAddress(root, relativePath)
  const lexicalFilePath = resolveFileAddress(config, address)
  const filePath = existsSync(lexicalFilePath)
    ? assertExistingFileAddress(config, address, lexicalFilePath)
    : lexicalFilePath
  if (!existsSync(filePath)) {
    throw new Error(`path does not exist: ${address.virtualPath}`)
  }

  const stat = statSync(filePath)
  if (stat.isDirectory()) {
    if (!recursive) {
      throw new Error('delete requires recursive=true for directories')
    }
    rmSync(filePath, { recursive: true, force: true })
    forgetFingerprintTree(state, address.root, address.relativePath)
  } else {
    await unlink(filePath)
    forgetFingerprint(state, address.root, address.relativePath)
  }

  return { address }
}

export async function movePath(
  config: WorkerConfig,
  state: FileLaneState,
  root: string,
  fromRelativePath: string,
  toRelativePath: string,
  overwrite: boolean
): Promise<MoveResult> {
  const from = fileAddress(root, fromRelativePath)
  const to = fileAddress(root, toRelativePath)

  const lexicalFromPath = resolveFileAddress(config, from)
  const fromPath = existsSync(lexicalFromPath)
    ? assertExistingFileAddress(config, from, lexicalFromPath)
    : lexicalFromPath
  const toPath = assertCreatableFileAddress(config, to, resolveFileAddress(config, to))

  if (!existsSync(fromPath)) {
    throw new Error(`path does not exist: ${from.virtualPath}`)
  }
  if (existsSync(toPath) && !overwrite) {
    throw new Error(`target path already exists: ${to.virtualPath}`)
  }

  mkdirSync(dirname(toPath), { recursive: true })
  const movingDirectory = statSync(fromPath).isDirectory()
  await rename(fromPath, toPath)
  if (movingDirectory) {
    forgetFingerprintTree(state, from.root, from.relativePath)
    forgetFingerprintTree(state, to.root, to.relativePath)
  } else {
    forgetFingerprint(state, from.root, from.relativePath)
    forgetFingerprint(state, to.root, to.relativePath)
  }

  return { from, to }
}

export function listPath(
  config: WorkerConfig,
  root: string,
  relativePath: string,
  recursive: boolean,
  maxEntries: number
): ListResult {
  const address = fileAddress(root, relativePath, { allowRoot: true })
  const boundedEntries = boundedMaxEntries(maxEntries)
  const lexicalDirectoryPath = resolveFileAddress(config, address, { allowRoot: true })
  const directoryPath = existsSync(lexicalDirectoryPath)
    ? assertExistingFileAddress(config, address, lexicalDirectoryPath)
    : lexicalDirectoryPath

  if (!existsSync(directoryPath) || !statSync(directoryPath).isDirectory()) {
    throw new Error(`directory does not exist: ${address.virtualPath}`)
  }

  const { entries, truncated } = listDirectory(directoryPath, address.relativePath, recursive, boundedEntries)
  return { address, recursive, entries, truncated }
}

function boundedMaxEntries(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('max_entries must be positive')
  return Math.min(value, 10_000)
}

function listDirectory(
  rootPath: string,
  baseRelativePath: string,
  recursive: boolean,
  maxEntries: number
): { entries: ListEntry[]; truncated: boolean } {
  const entries: ListEntry[] = []
  let truncated = false

  const visit = (directoryPath: string, directoryRelativePath: string) => {
    for (const entry of readdirSync(directoryPath, { withFileTypes: true }).sort((a, b) =>
      a.name.localeCompare(b.name)
    )) {
      if (entries.length >= maxEntries) {
        truncated = true
        return
      }

      const childRelativePath = directoryRelativePath ? `${directoryRelativePath}/${entry.name}` : entry.name
      const childPath = join(directoryPath, entry.name)
      const stat = lstatSync(childPath)
      const kind = entry.isFile() ? 'file' : entry.isDirectory() ? 'directory' : 'other'
      entries.push({
        relative_path: childRelativePath,
        kind,
        size: entry.isFile() ? stat.size : 0,
        modified_unix_ms: Math.floor(stat.mtimeMs)
      })

      if (recursive && entry.isDirectory()) {
        visit(childPath, childRelativePath)
        if (truncated) return
      }
    }
  }

  visit(rootPath, baseRelativePath)
  return { entries, truncated }
}
