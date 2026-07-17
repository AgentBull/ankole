import { existsSync, lstatSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { rename, unlink } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fingerprintMode, readBoolFrame, readU64Frame, requiredTextFrame } from './codec'
import { fileFingerprint, forgetFingerprint, forgetFingerprintTree } from './fingerprint'
import {
  assertCreatableFileAddress,
  assertExistingFileAddress,
  parseVirtualPathFrame,
  resolveFileAddress
} from './path-security'
import type { FileAddress, FileTransferState, ListEntry } from './types'
import type { WorkerConfig } from '../../worker/config'

export type StatResult = {
  address: FileAddress
  kind: 'file' | 'directory' | 'other'
  size: number
  modifiedUnixMs: number
  fingerprint: string
}

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

export function statPath(config: WorkerConfig, state: FileTransferState, frames: Buffer[]): StatResult {
  const address = parseVirtualPathFrame(frames[3], 'stat path')
  const fingerprint = fingerprintMode(requiredTextFrame(frames[4], 'fingerprint'))
  const lexicalFilePath = resolveFileAddress(config, address)
  const filePath = existsSync(lexicalFilePath)
    ? assertExistingFileAddress(config, address, lexicalFilePath)
    : lexicalFilePath
  if (!existsSync(filePath)) {
    throw new Error(`path does not exist: ${address.virtualPath}`)
  }

  const stat = statSync(filePath)
  const kind = stat.isFile() ? 'file' : stat.isDirectory() ? 'directory' : 'other'
  return {
    address,
    kind,
    size: stat.size,
    modifiedUnixMs: Math.floor(stat.mtimeMs),
    fingerprint:
      stat.isFile() && fingerprint === 'xxh3_128'
        ? fileFingerprint(state, address.root, address.relativePath, filePath)
        : ''
  }
}

export async function deletePath(
  config: WorkerConfig,
  state: FileTransferState,
  frames: Buffer[]
): Promise<DeleteResult> {
  const address = parseVirtualPathFrame(frames[3], 'delete path')
  const recursive = readBoolFrame(frames[4], 'recursive')
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
      throw new Error('DELETE requires recursive=true for directories')
    }
    rmSync(filePath, { recursive: true, force: true })
    forgetFingerprintTree(state, address.root, address.relativePath)
  } else {
    await unlink(filePath)
    forgetFingerprint(state, address.root, address.relativePath)
  }

  return { address }
}

export async function movePath(config: WorkerConfig, state: FileTransferState, frames: Buffer[]): Promise<MoveResult> {
  const from = parseVirtualPathFrame(frames[3], 'from path')
  const to = parseVirtualPathFrame(frames[4], 'to path')
  const overwrite = readBoolFrame(frames[5], 'overwrite')

  if (from.root !== to.root) {
    throw new Error('MOVE must stay inside one worker root')
  }

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

export function listPath(config: WorkerConfig, frames: Buffer[]): ListResult {
  const address = parseVirtualPathFrame(frames[3], 'list path', { allowRoot: true })
  const recursive = readBoolFrame(frames[4], 'recursive')
  const maxEntries = boundedMaxEntries(readU64Frame(frames[5], 'max_entries'))
  const lexicalDirectoryPath = resolveFileAddress(config, address, { allowRoot: true })
  const directoryPath = existsSync(lexicalDirectoryPath)
    ? assertExistingFileAddress(config, address, lexicalDirectoryPath)
    : lexicalDirectoryPath

  if (!existsSync(directoryPath) || !statSync(directoryPath).isDirectory()) {
    throw new Error(`directory does not exist: ${address.virtualPath}`)
  }

  const { entries, truncated } = listDirectory(directoryPath, address.relativePath, recursive, maxEntries)
  return { address, recursive, entries, truncated }
}

function boundedMaxEntries(value: number): number {
  if (value < 1) throw new Error('max_entries must be positive')
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
