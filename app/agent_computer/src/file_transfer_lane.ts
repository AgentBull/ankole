import { xxh3File128Hex } from '@ankole/kernel'
import { existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { appendFile, rename, unlink, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { Buffer } from 'node:buffer'
import type { WorkerConfig } from './runtime'

export const fileTransferProtocol = Buffer.from('ANKOLE_FILE/1')

const chunkSize = 1024 * 1024
const creditWindow = 4 * 1024 * 1024
const transferScratchDir = '.ankole-file-transfer'

type FileFrameSender = {
  sendFileFrame(frames: Buffer[]): string
}

type PutTransfer = {
  transferId: string
  address: FileAddress
  targetPath: string
  tempDir: string
  payloadPath: string
  nextSequence: number
  nextOffset: number
  expectedOriginalSize: number
}

type GetTransfer = {
  transferId: string
  address: FileAddress
  filePath: string
  process: ReturnType<typeof spawn>
  stdout: NonNullable<ReturnType<typeof spawn>['stdout']>
  pendingChunks: Buffer[]
  bufferedBytes: number
  nextSequence: number
  nextOffset: number
  credit: number
  chunksSent: number
  stdoutEnded: boolean
  processClosed: boolean
  exitCode: number | null
  stderr: string
  initialSize: number
  initialMtimeMs: number
  stable?: boolean
  finished?: boolean
}

export type FileTransferState = {
  puts: Map<string, PutTransfer>
  gets: Map<string, GetTransfer>
  fingerprints: Map<string, FingerprintCacheEntry>
}

type FileRoot = 'user_files' | 'agent_installed_skills'
type FingerprintMode = 'none' | 'xxh3_128'

type FileAddress = {
  root: FileRoot
  relativePath: string
  virtualPath: string
}

type FingerprintCacheEntry = {
  size: number
  mtimeMs: number
  xxh3_128: string
}

type ListEntry = {
  relative_path: string
  kind: 'file' | 'directory' | 'other'
  size: number
  modified_unix_ms: number
}

export function createFileTransferState(): FileTransferState {
  return { puts: new Map(), gets: new Map(), fingerprints: new Map() }
}

export function isFileTransferFrame(frames: Buffer[]): boolean {
  return frames.length > 0 && frames[0].equals(fileTransferProtocol)
}

export async function handleFileTransferFrame(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  frames: Buffer[]
): Promise<void> {
  const transferId = textFrame(frames[2]) || 'unknown'
  let command = 'unknown'

  try {
    if (!isFileTransferFrame(frames)) {
      throw new Error('invalid file-transfer protocol marker')
    }

    command = requiredTextFrame(frames[1], 'command')
    switch (command) {
      case 'WRITE_OPEN':
        await handleWriteOpen(config, sender, state, transferId, frames)
        return

      case 'DATA':
        await handleData(sender, state, transferId, frames)
        return

      case 'WRITE_COMMIT':
        await handleWriteCommit(sender, state, transferId)
        return

      case 'WRITE_ABORT':
        handleWriteAbort(sender, state, transferId)
        return

      case 'READ_OPEN':
        handleReadOpen(config, sender, state, transferId, frames)
        return

      case 'READ_ABORT':
        handleReadAbort(state, transferId)
        return

      case 'CREDIT':
        sendReadData(sender, state, transferId, frames)
        return

      case 'STAT':
        handleStat(config, sender, state, transferId, frames)
        return

      case 'DELETE':
        await handleDelete(config, sender, state, transferId, frames)
        return

      case 'MOVE':
        await handleMove(config, sender, state, transferId, frames)
        return

      case 'LIST':
        handleList(config, sender, transferId, frames)
        return

      default:
        throw new Error(`unsupported file lane command: ${command}`)
    }
  } catch (error) {
    if (command === 'DATA') {
      cleanupWriteTransfer(state, transferId)
    }
    sendError(sender, transferId, 'operation_failed', error instanceof Error ? error.message : String(error))
  }
}

async function handleWriteOpen(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  if (state.puts.has(transferId)) {
    throw new Error(`file transfer already exists: ${transferId}`)
  }

  assertZstdAvailable()
  const address = parseVirtualPathFrame(frames[3], 'write path')
  const expectedOriginalSize = readU64Frame(frames[4], 'original_size')
  const targetPath = resolveFileAddress(config, address)
  const tempDir = scratchDirectoryFor(config, transferId)
  const payloadPath = join(tempDir, 'payload.zst')

  try {
    rmSync(tempDir, { recursive: true, force: true })
    mkdirSync(tempDir, { recursive: true })
    await writeFile(payloadPath, Buffer.alloc(0))
  } catch (error) {
    rmSync(tempDir, { recursive: true, force: true })
    throw error
  }

  state.puts.set(transferId, {
    transferId,
    address,
    targetPath,
    tempDir,
    payloadPath,
    nextSequence: 0,
    nextOffset: 0,
    expectedOriginalSize
  })

  try {
    sendFrame(sender, ['WRITE_READY', transferId, u64Frame(creditWindow)])
  } catch (error) {
    cleanupWriteTransfer(state, transferId)
    throw error
  }
}

async function handleData(
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const transfer = getPutTransfer(state, transferId)
  const sequence = readU64Frame(frames[3], 'sequence')
  const offset = readU64Frame(frames[4], 'offset')
  readBoolFrame(frames[5], 'eof')
  const chunk = frames[6]

  if (sequence !== transfer.nextSequence) {
    throw new Error(`unexpected sequence ${sequence}, expected ${transfer.nextSequence}`)
  }
  if (offset !== transfer.nextOffset) {
    throw new Error(`unexpected offset ${offset}, expected ${transfer.nextOffset}`)
  }
  if (!chunk) {
    throw new Error('DATA requires a binary chunk frame')
  }

  await appendFile(transfer.payloadPath, chunk)
  transfer.nextSequence += 1
  transfer.nextOffset += chunk.byteLength
  sendFrame(sender, ['CREDIT', transferId, u64Frame(chunk.byteLength)])
}

async function handleWriteCommit(sender: FileFrameSender, state: FileTransferState, transferId: string): Promise<void> {
  const transfer = getPutTransfer(state, transferId)

  const finalTempPath = `${transfer.targetPath}.ankole-transfer-${safeTransferId(transferId)}.tmp`
  const decodedPath = join(transfer.tempDir, 'decoded')
  let fingerprint: string

  try {
    assertZstdAvailable()
    rmSync(decodedPath, { force: true })
    const result = spawnSync('zstd', ['-q', '-d', '-f', '-o', decodedPath, transfer.payloadPath], {
      encoding: 'utf8'
    })
    if (result.status !== 0) {
      throw new Error(`zstd decode failed: ${result.stderr || result.error?.message || 'unknown error'}`)
    }

    await verifyFinalFile(decodedPath, transfer)
    mkdirSync(dirname(transfer.targetPath), { recursive: true })
    rmSync(finalTempPath, { force: true })
    await rename(decodedPath, finalTempPath)
    await rename(finalTempPath, transfer.targetPath)
    fingerprint = fileFingerprint(state, transfer.address.root, transfer.address.relativePath, transfer.targetPath)
    state.puts.delete(transferId)
    rmSync(transfer.tempDir, { recursive: true, force: true })
  } catch (error) {
    removePathBestEffort(decodedPath)
    removePathBestEffort(finalTempPath)
    cleanupWriteTransfer(state, transferId)
    throw error
  }

  sendFrame(sender, [
    'WRITE_COMMITTED',
    transferId,
    transfer.address.virtualPath,
    u64Frame(statSync(transfer.targetPath).size),
    fingerprint
  ])
}

function handleWriteAbort(sender: FileFrameSender, state: FileTransferState, transferId: string): void {
  const transfer = state.puts.get(transferId)
  if (transfer) {
    rmSync(transfer.tempDir, { recursive: true, force: true })
    state.puts.delete(transferId)
  }

  sendFrame(sender, ['WRITE_ABORTED', transferId])
}

function handleReadOpen(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): void {
  if (state.gets.has(transferId)) {
    throw new Error(`file transfer already exists: ${transferId}`)
  }

  assertZstdAvailable()
  const address = parseVirtualPathFrame(frames[3], 'read path')
  const fingerprint = fingerprintMode(requiredTextFrame(frames[4], 'fingerprint'))
  const filePath = resolveFileAddress(config, address)
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    throw new Error(`file does not exist: ${address.virtualPath}`)
  }

  const stableStat = statSync(filePath)
  const zstd = spawn('zstd', ['-q', '-c', filePath], { stdio: ['ignore', 'pipe', 'pipe'] })
  const stdout = zstd.stdout
  const stderr = zstd.stderr
  if (!stdout || !stderr) {
    zstd.kill('SIGTERM')
    throw new Error('zstd encode pipes unavailable')
  }
  stdout.pause()

  const transfer: GetTransfer = {
    transferId,
    address,
    filePath,
    process: zstd,
    stdout,
    pendingChunks: [],
    bufferedBytes: 0,
    nextSequence: 0,
    nextOffset: 0,
    credit: 0,
    chunksSent: 0,
    stdoutEnded: false,
    processClosed: false,
    exitCode: null,
    stderr: '',
    initialSize: stableStat.size,
    initialMtimeMs: stableStat.mtimeMs
  }
  state.gets.set(transferId, transfer)

  stdout.on('data', chunk => {
    transfer.pendingChunks.push(Buffer.from(chunk))
    transfer.bufferedBytes += chunk.byteLength
    drainReadTransfer(sender, state, transfer)
  })
  stdout.on('end', () => {
    transfer.stdoutEnded = true
    drainReadTransfer(sender, state, transfer)
  })
  stderr.on('data', chunk => {
    transfer.stderr += Buffer.from(chunk).toString('utf8')
  })
  zstd.on('error', error => {
    finishReadTransferWithError(sender, state, transfer, `zstd encode failed: ${error.message}`)
  })
  zstd.on('close', code => {
    transfer.processClosed = true
    transfer.exitCode = code
    if (code !== 0) {
      finishReadTransferWithError(sender, state, transfer, `zstd encode failed: ${transfer.stderr.trim() || code}`)
      return
    }
    drainReadTransfer(sender, state, transfer)
  })

  try {
    sendFrame(sender, [
      'READ_READY',
      transferId,
      address.virtualPath,
      u64Frame(stableStat.size),
      fingerprint === 'none' ? '' : fileFingerprint(state, address.root, address.relativePath, filePath)
    ])
  } catch (error) {
    handleReadAbort(state, transferId)
    throw error
  }
}

function sendReadData(sender: FileFrameSender, state: FileTransferState, transferId: string, frames: Buffer[]): void {
  const transfer = state.gets.get(transferId)
  if (!transfer) {
    throw new Error(`unknown read transfer: ${transferId}`)
  }

  transfer.credit += readU64Frame(frames[3], 'credit')
  drainReadTransfer(sender, state, transfer)
}

function handleReadAbort(state: FileTransferState, transferId: string): void {
  const transfer = state.gets.get(transferId)
  if (!transfer) return

  state.gets.delete(transferId)
  transfer.finished = true
  transfer.process.kill('SIGTERM')
}

function drainReadTransfer(sender: FileFrameSender, state: FileTransferState, transfer: GetTransfer): void {
  if (transfer.finished) return

  while (transfer.credit > 0) {
    const terminal = transfer.stdoutEnded && transfer.processClosed && transfer.exitCode === 0
    const sendableBytes = terminal ? transfer.bufferedBytes : Math.max(0, transfer.bufferedBytes - 1)
    if (sendableBytes <= 0) break

    const chunk = takeReadChunk(transfer, Math.min(chunkSize, transfer.credit, sendableBytes))
    const eof = terminal && transfer.bufferedBytes === 0

    sendFrame(sender, [
      'DATA',
      transfer.transferId,
      u64Frame(transfer.nextSequence),
      u64Frame(transfer.nextOffset),
      boolFrame(eof),
      chunk
    ])

    transfer.nextSequence += 1
    transfer.nextOffset += chunk.byteLength
    transfer.credit -= chunk.byteLength
    transfer.chunksSent += 1
  }

  if (transfer.credit > 0 && !transfer.stdoutEnded) {
    transfer.stdout.resume()
  } else {
    transfer.stdout.pause()
  }

  maybeFinishReadTransfer(sender, state, transfer)
}

function takeReadChunk(transfer: GetTransfer, size: number): Buffer {
  const chunks: Buffer[] = []
  let remaining = size

  while (remaining > 0) {
    const chunk = transfer.pendingChunks.shift()
    if (!chunk) break

    if (chunk.byteLength <= remaining) {
      chunks.push(chunk)
      remaining -= chunk.byteLength
      transfer.bufferedBytes -= chunk.byteLength
      continue
    }

    chunks.push(chunk.subarray(0, remaining))
    transfer.pendingChunks.unshift(chunk.subarray(remaining))
    transfer.bufferedBytes -= remaining
    remaining = 0
  }

  return Buffer.concat(chunks)
}

function maybeFinishReadTransfer(sender: FileFrameSender, state: FileTransferState, transfer: GetTransfer): void {
  if (
    transfer.finished ||
    !transfer.stdoutEnded ||
    !transfer.processClosed ||
    transfer.exitCode !== 0 ||
    transfer.bufferedBytes > 0
  ) {
    return
  }

  if (!readSourceStillStable(transfer)) {
    finishReadTransferWithError(sender, state, transfer, `file changed during read: ${transfer.address.virtualPath}`)
    return
  }

  transfer.finished = true
  state.gets.delete(transfer.transferId)
  sendFrame(sender, ['READ_DONE', transfer.transferId, u64Frame(transfer.chunksSent), u64Frame(transfer.nextOffset)])
}

function readSourceStillStable(transfer: GetTransfer): boolean {
  if (!existsSync(transfer.filePath)) return false
  const current = statSync(transfer.filePath)
  return current.isFile() && current.size === transfer.initialSize && current.mtimeMs === transfer.initialMtimeMs
}

function finishReadTransferWithError(
  sender: FileFrameSender,
  state: FileTransferState,
  transfer: GetTransfer,
  message: string
): void {
  if (transfer.finished) return

  transfer.finished = true
  state.gets.delete(transfer.transferId)
  if (!transfer.process.killed && !transfer.processClosed) {
    transfer.process.kill('SIGTERM')
  }
  sendError(sender, transfer.transferId, 'operation_failed', message)
}

function handleStat(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): void {
  const address = parseVirtualPathFrame(frames[3], 'stat path')
  const fingerprint = fingerprintMode(requiredTextFrame(frames[4], 'fingerprint'))
  const filePath = resolveFileAddress(config, address)
  if (!existsSync(filePath)) {
    throw new Error(`path does not exist: ${address.virtualPath}`)
  }

  const stat = statSync(filePath)
  sendFrame(sender, [
    'STAT_OK',
    transferId,
    address.virtualPath,
    stat.isFile() ? 'file' : stat.isDirectory() ? 'directory' : 'other',
    u64Frame(stat.size),
    u64Frame(Math.floor(stat.mtimeMs)),
    stat.isFile() && fingerprint === 'xxh3_128'
      ? fileFingerprint(state, address.root, address.relativePath, filePath)
      : ''
  ])
}

async function handleDelete(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const address = parseVirtualPathFrame(frames[3], 'delete path')
  const recursive = readBoolFrame(frames[4], 'recursive')
  const filePath = resolveFileAddress(config, address)
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

  sendFrame(sender, ['DELETE_OK', transferId, address.virtualPath])
}

async function handleMove(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const from = parseVirtualPathFrame(frames[3], 'from path')
  const to = parseVirtualPathFrame(frames[4], 'to path')
  const overwrite = readBoolFrame(frames[5], 'overwrite')

  if (from.root !== to.root) {
    throw new Error('MOVE must stay inside one worker root')
  }

  const fromPath = resolveFileAddress(config, from)
  const toPath = resolveFileAddress(config, to)

  if (!existsSync(fromPath)) {
    throw new Error(`path does not exist: ${from.virtualPath}`)
  }
  if (existsSync(toPath) && !overwrite) {
    throw new Error(`target path already exists: ${to.virtualPath}`)
  }

  mkdirSync(dirname(toPath), { recursive: true })
  if (existsSync(toPath)) rmSync(toPath, { recursive: true, force: true })
  const movingDirectory = statSync(fromPath).isDirectory()
  await rename(fromPath, toPath)
  if (movingDirectory) {
    forgetFingerprintTree(state, from.root, from.relativePath)
    forgetFingerprintTree(state, to.root, to.relativePath)
  } else {
    forgetFingerprint(state, from.root, from.relativePath)
    forgetFingerprint(state, to.root, to.relativePath)
  }

  sendFrame(sender, ['MOVE_OK', transferId, from.virtualPath, to.virtualPath])
}

function handleList(config: WorkerConfig, sender: FileFrameSender, transferId: string, frames: Buffer[]): void {
  const address = parseVirtualPathFrame(frames[3], 'list path', { allowRoot: true })
  const recursive = readBoolFrame(frames[4], 'recursive')
  const maxEntries = boundedMaxEntries(readU64Frame(frames[5], 'max_entries'))
  const directoryPath = resolveFileAddress(config, address, { allowRoot: true })

  if (!existsSync(directoryPath) || !statSync(directoryPath).isDirectory()) {
    throw new Error(`directory does not exist: ${address.virtualPath}`)
  }

  const { entries, truncated } = listDirectory(directoryPath, address.relativePath, recursive, maxEntries)

  sendFrame(sender, [
    'LIST_OK',
    transferId,
    address.virtualPath,
    boolFrame(recursive),
    boolFrame(truncated),
    encodeEntries(entries)
  ])
}

async function verifyFinalFile(path: string, transfer: PutTransfer): Promise<void> {
  const stat = statSync(path)
  if (stat.size !== transfer.expectedOriginalSize) {
    throw new Error(`size mismatch after file transfer: expected ${transfer.expectedOriginalSize}, got ${stat.size}`)
  }
}

function resolveFileAddress(config: WorkerConfig, address: FileAddress, opts: { allowRoot?: boolean } = {}): string {
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

function scratchDirectoryFor(config: WorkerConfig, transferId: string): string {
  const scratchRoot = resolve(config.sharedFsRoot, transferScratchDir)
  const tempDir = resolve(scratchRoot, safeTransferId(transferId))
  const rel = relative(scratchRoot, tempDir)

  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`transfer_id escapes scratch root: ${transferId}`)
  }

  return tempDir
}

function cleanupWriteTransfer(state: FileTransferState, transferId: string): void {
  const transfer = state.puts.get(transferId)
  if (!transfer) return

  rmSync(transfer.tempDir, { recursive: true, force: true })
  state.puts.delete(transferId)
}

function removePathBestEffort(path: string): void {
  try {
    rmSync(path, { force: true })
  } catch {
    // Parent-path conflicts can make best-effort temp cleanup itself fail.
  }
}

function rootPathFor(config: WorkerConfig, root: string): string {
  switch (root) {
    case 'user_files':
      return config.userFilesRoot
    case 'agent_installed_skills':
      return config.agentInstalledSkillsRoot
    default:
      throw new Error(`unsupported file root: ${root}`)
  }
}

function parseVirtualPathFrame(
  frame: Buffer | undefined,
  label: string,
  opts: { allowRoot?: boolean } = {}
): FileAddress {
  const virtualPath = requiredTextFrame(frame, label)
  if (!virtualPath.startsWith('/')) {
    throw new Error(`${label} must be an absolute worker virtual path`)
  }

  const [root, ...segments] = virtualPath.slice(1).split('/')
  if (root !== 'user_files' && root !== 'agent_installed_skills') {
    throw new Error(`unsupported file root: ${root}`)
  }

  const relativePath = normalizeRelativePath(segments.join('/'), opts)
  return {
    root,
    relativePath,
    virtualPath: relativePath ? `/${root}/${relativePath}` : `/${root}`
  }
}

function normalizeRelativePath(value: unknown, opts: { allowRoot?: boolean } = {}): string {
  if (typeof value !== 'string') {
    throw new Error('relative_path must be a string')
  }

  const normalized = value.replaceAll('\\', '/').replace(/^\/+/, '').replace(/\/+/g, '/')
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

function fingerprintMode(value: unknown): FingerprintMode {
  if (value === undefined || value === null || value === '') return 'xxh3_128'
  if (value === 'none' || value === 'xxh3_128') return value
  throw new Error(`unsupported fingerprint: ${String(value)}`)
}

function readU64Frame(frame: Buffer | undefined, label: string): number {
  if (!frame || frame.byteLength !== 8) {
    throw new Error(`${label} must be a u64 frame`)
  }

  const value = frame.readBigUInt64BE()
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${label} exceeds JavaScript safe integer range`)
  }
  return Number(value)
}

function u64Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`invalid u64 value: ${value}`)
  }

  const frame = Buffer.alloc(8)
  frame.writeBigUInt64BE(BigInt(value))
  return frame
}

function readBoolFrame(frame: Buffer | undefined, label: string): boolean {
  if (!frame || frame.byteLength !== 1 || (frame[0] !== 0 && frame[0] !== 1)) {
    throw new Error(`${label} must be a bool frame`)
  }
  return frame[0] === 1
}

function boolFrame(value: boolean): Buffer {
  return Buffer.from([value ? 1 : 0])
}

function requiredTextFrame(frame: Buffer | undefined, label: string): string {
  const text = textFrame(frame)
  if (!text) {
    throw new Error(`${label} frame is required`)
  }
  return text
}

function textFrame(frame: Buffer | undefined): string | undefined {
  if (!frame) return undefined
  return frame.toString('utf8')
}

function safeTransferId(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value
}

function fileFingerprint(state: FileTransferState, root: FileRoot, relativePath: string, filePath: string): string {
  const stat = statSync(filePath)
  const key = fingerprintCacheKey(root, relativePath)
  const cached = state.fingerprints.get(key)
  if (cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
    return cached.xxh3_128
  }

  const xxh3_128 = xxh3File128Hex(filePath)
  state.fingerprints.set(key, { size: stat.size, mtimeMs: stat.mtimeMs, xxh3_128 })
  return xxh3_128
}

function forgetFingerprint(state: FileTransferState, root: FileRoot, relativePath: string): void {
  state.fingerprints.delete(fingerprintCacheKey(root, normalizeRelativePath(relativePath)))
}

function forgetFingerprintTree(state: FileTransferState, root: FileRoot, relativePath: string): void {
  const prefix = `${root}:${normalizeRelativePath(relativePath)}`
  for (const key of state.fingerprints.keys()) {
    if (key === prefix || key.startsWith(`${prefix}/`)) {
      state.fingerprints.delete(key)
    }
  }
}

function fingerprintCacheKey(root: FileRoot, relativePath: string): string {
  return `${root}:${normalizeRelativePath(relativePath)}`
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
      const stat = statSync(childPath)
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

function encodeEntries(entries: ListEntry[]): Buffer {
  return Buffer.concat([u32Frame(entries.length), ...entries.flatMap(encodeEntry)])
}

function encodeEntry(entry: ListEntry): Buffer[] {
  return [
    sizedStringFrame(entry.relative_path),
    sizedStringFrame(entry.kind),
    u64Frame(entry.size),
    u64Frame(entry.modified_unix_ms)
  ]
}

function sizedStringFrame(value: string): Buffer {
  const bytes = Buffer.from(value)
  return Buffer.concat([u32Frame(bytes.byteLength), bytes])
}

function u32Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffffffff) {
    throw new Error(`invalid u32 value: ${value}`)
  }

  const frame = Buffer.alloc(4)
  frame.writeUInt32BE(value)
  return frame
}

function assertZstdAvailable(): void {
  const result = spawnSync('zstd', ['--version'], { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`zstd is required for file transfer: ${result.stderr || result.error?.message || 'not found'}`)
  }
}

function sendError(sender: FileFrameSender, transferId: string, code: string, message: string): void {
  sendFrame(sender, ['ERROR', transferId, code, message])
}

function sendFrame(sender: FileFrameSender, parts: Array<string | Buffer>): void {
  sender.sendFileFrame([
    fileTransferProtocol,
    ...parts.map(part => (typeof part === 'string' ? Buffer.from(part) : part))
  ])
}

function getPutTransfer(state: FileTransferState, transferId: string): PutTransfer {
  const transfer = state.puts.get(transferId)
  if (!transfer) {
    throw new Error(`unknown file transfer: ${transferId}`)
  }
  return transfer
}
