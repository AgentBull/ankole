import { xxh3File128Hex, zstdCompressBlock, zstdDecompressBlock } from '@ankole/kernel'
import { match } from '@pleisto/active-support'
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readSync, rmSync, statSync } from 'node:fs'
import { appendFile, rename, unlink, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { Buffer } from 'node:buffer'
import type { WorkerConfig } from '../worker/config'

/**
 * Handles the worker side of RuntimeFabric's binary file lane.
 *
 * The lane is intentionally not JSON: large file content travels as multipart
 * frames, while PostgreSQL/control-plane state still owns durable turn truth.
 */
export const fileTransferProtocol = Buffer.from('ANKOLE_FILE/1')

const chunkSize = 2 * 1024 * 1024
const creditWindow = 4 * 1024 * 1024
const zstdLevel = 3
const transferScratchDir = '.ankole-file-transfer'

type FileFrameSender = {
  sendFileFrame(frames: Buffer[]): string
}

type PutTransfer = {
  transferId: string
  address: FileAddress
  targetPath: string
  tempDir: string
  decodedPath: string
  nextSequence: number
  nextOffset: number
  expectedOriginalSize: number
  decodedSize: number
}

type GetTransfer = {
  transferId: string
  address: FileAddress
  filePath: string
  fd: number
  fileSize: number
  readOffset: number
  nextSequence: number
  nextOffset: number
  credit: number
  chunksSent: number
  initialSize: number
  initialMtimeMs: number
  draining: boolean
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

/**
 * Creates the in-memory transfer state owned by one worker process.
 *
 * Transfers are recoverable from the control-plane side by retrying operations;
 * partial local state is process-local scratch and is not durable truth.
 */
export function createFileTransferState(): FileTransferState {
  return { puts: new Map(), gets: new Map(), fingerprints: new Map() }
}

/**
 * Checks whether raw RuntimeFabric frames belong to the file lane.
 */
export function isFileTransferFrame(frames: Buffer[]): boolean {
  return frames.length > 0 && frames[0].equals(fileTransferProtocol)
}

/**
 * Dispatches one file-lane frame and converts protocol/local filesystem errors
 * into file-lane ERROR replies.
 *
 * DATA failures clean up the open write transfer immediately because the decoded
 * scratch file can no longer be trusted after an out-of-order or corrupt chunk.
 */
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
    await match(command)
      .with('WRITE_OPEN', () => handleWriteOpen(config, sender, state, transferId, frames))
      .with('DATA', () => handleData(sender, state, transferId, frames))
      .with('WRITE_COMMIT', () => handleWriteCommit(sender, state, transferId))
      .with('WRITE_ABORT', () => handleWriteAbort(sender, state, transferId))
      .with('READ_OPEN', () => handleReadOpen(config, sender, state, transferId, frames))
      .with('READ_ABORT', () => handleReadAbort(state, transferId))
      .with('CREDIT', () => sendReadData(sender, state, transferId, frames))
      .with('STAT', () => handleStat(config, sender, state, transferId, frames))
      .with('DELETE', () => handleDelete(config, sender, state, transferId, frames))
      .with('MOVE', () => handleMove(config, sender, state, transferId, frames))
      .with('LIST', () => handleList(config, sender, transferId, frames))
      .otherwise(() => {
        throw new Error(`unsupported file lane command: ${command}`)
      })
    return
  } catch (error) {
    if (command === 'DATA') {
      cleanupWriteTransfer(state, transferId)
    }
    sendError(sender, transferId, 'operation_failed', error instanceof Error ? error.message : String(error))
  }
}

/**
 * Opens a write transfer into a scratch decoded file.
 *
 * The target file is not touched until WRITE_COMMIT, which keeps failed or
 * aborted uploads from leaving half-written user-visible files behind.
 */
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

  const address = parseVirtualPathFrame(frames[3], 'write path')
  const expectedOriginalSize = readU64Frame(frames[4], 'original_size')
  const targetPath = resolveFileAddress(config, address)
  const tempDir = scratchDirectoryFor(config, transferId)
  const decodedPath = join(tempDir, 'decoded')

  try {
    rmSync(tempDir, { recursive: true, force: true })
    mkdirSync(tempDir, { recursive: true })
    await writeFile(decodedPath, Buffer.alloc(0))
  } catch (error) {
    rmSync(tempDir, { recursive: true, force: true })
    throw error
  }

  state.puts.set(transferId, {
    transferId,
    address,
    targetPath,
    tempDir,
    decodedPath,
    nextSequence: 0,
    nextOffset: 0,
    expectedOriginalSize,
    decodedSize: 0
  })

  try {
    sendFrame(sender, ['WRITE_READY', transferId, u64Frame(creditWindow)])
  } catch (error) {
    cleanupWriteTransfer(state, transferId)
    throw error
  }
}

/**
 * Appends one compressed DATA chunk to the decoded scratch file.
 *
 * Both sequence and compressed-wire offset are checked so retries or duplicate
 * frames fail closed instead of silently corrupting the reconstructed file.
 */
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

  const decoded = await zstdDecompressBlock(chunk, chunkSize)
  await appendFile(transfer.decodedPath, decoded)
  transfer.nextSequence += 1
  transfer.nextOffset += chunk.byteLength
  transfer.decodedSize += decoded.byteLength
  sendFrame(sender, ['CREDIT', transferId, u64Frame(chunk.byteLength)])
}

/**
 * Atomically commits a completed write transfer into its final path.
 *
 * The double rename keeps the target either old-or-new from the filesystem
 * observer's point of view and removes scratch state once the fingerprint is
 * refreshed.
 */
async function handleWriteCommit(sender: FileFrameSender, state: FileTransferState, transferId: string): Promise<void> {
  const transfer = getPutTransfer(state, transferId)

  const finalTempPath = `${transfer.targetPath}.ankole-transfer-${safeTransferId(transferId)}.tmp`
  let fingerprint: string

  try {
    if (transfer.decodedSize !== transfer.expectedOriginalSize) {
      throw new Error(
        `size mismatch after file transfer: expected ${transfer.expectedOriginalSize}, got ${transfer.decodedSize}`
      )
    }

    mkdirSync(dirname(transfer.targetPath), { recursive: true })
    rmSync(finalTempPath, { force: true })
    await rename(transfer.decodedPath, finalTempPath)
    await rename(finalTempPath, transfer.targetPath)
    fingerprint = fileFingerprint(state, transfer.address.root, transfer.address.relativePath, transfer.targetPath)
    state.puts.delete(transferId)
    rmSync(transfer.tempDir, { recursive: true, force: true })
  } catch (error) {
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

/**
 * Aborts an open write transfer and removes its scratch directory.
 */
function handleWriteAbort(sender: FileFrameSender, state: FileTransferState, transferId: string): void {
  const transfer = state.puts.get(transferId)
  if (transfer) {
    rmSync(transfer.tempDir, { recursive: true, force: true })
    state.puts.delete(transferId)
  }

  sendFrame(sender, ['WRITE_ABORTED', transferId])
}

/**
 * Opens a read transfer against a stable file descriptor.
 *
 * Size and mtime are captured at open time; the final stability check catches a
 * file that changed while the worker was streaming it.
 */
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

  const address = parseVirtualPathFrame(frames[3], 'read path')
  const fingerprint = fingerprintMode(requiredTextFrame(frames[4], 'fingerprint'))
  const filePath = resolveFileAddress(config, address)
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    throw new Error(`file does not exist: ${address.virtualPath}`)
  }

  const stableStat = statSync(filePath)
  const fd = openSync(filePath, 'r')

  const transfer: GetTransfer = {
    transferId,
    address,
    filePath,
    fd,
    fileSize: stableStat.size,
    readOffset: 0,
    nextSequence: 0,
    nextOffset: 0,
    credit: 0,
    chunksSent: 0,
    initialSize: stableStat.size,
    initialMtimeMs: stableStat.mtimeMs,
    draining: false
  }
  state.gets.set(transferId, transfer)

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

/**
 * Adds remote read credit and starts draining data if no drain is active.
 */
function sendReadData(sender: FileFrameSender, state: FileTransferState, transferId: string, frames: Buffer[]): void {
  const transfer = state.gets.get(transferId)
  if (!transfer) {
    throw new Error(`unknown read transfer: ${transferId}`)
  }

  transfer.credit += readU64Frame(frames[3], 'credit')
  void drainReadTransfer(sender, state, transfer)
}

/**
 * Stops a read transfer without sending a terminal frame.
 *
 * The control plane asked to abort, so the important action is closing the file
 * descriptor and forgetting process-local state.
 */
function handleReadAbort(state: FileTransferState, transferId: string): void {
  const transfer = state.gets.get(transferId)
  if (!transfer) return

  closeTransferFile(transfer)
  state.gets.delete(transferId)
  transfer.finished = true
}

/**
 * Sends compressed read DATA frames while remote credit is available.
 *
 * Credit is tracked in wire bytes, but compression ratio is unknown until after
 * a block is encoded. The loop allows a one-block overshoot and expects the
 * receiver to restore credit for each received compressed chunk.
 */
async function drainReadTransfer(
  sender: FileFrameSender,
  state: FileTransferState,
  transfer: GetTransfer
): Promise<void> {
  if (transfer.finished || transfer.draining) return

  transfer.draining = true
  try {
    // Credit is a wire-byte budget. A block's compressed size is only known after
    // compression, so an incompressible block can overshoot the budget and drive
    // credit negative by up to one block. The control plane returns CREDIT equal
    // to each received chunk's wire size, so credit recovers on the next drain.
    // EOF chunks never receive a top-up, so finishing must not depend on credit.
    while (transfer.credit > 0 && transfer.readOffset < transfer.fileSize && !transfer.finished) {
      const bytesToRead = Math.min(chunkSize, transfer.credit, transfer.fileSize - transfer.readOffset)
      const block = readTransferBlock(transfer, bytesToRead)
      if (!block) break

      let compressed: Buffer
      try {
        compressed = await zstdCompressBlock(block, zstdLevel)
      } catch (error) {
        finishReadTransferWithError(
          sender,
          state,
          transfer,
          `zstd encode failed: ${error instanceof Error ? error.message : String(error)}`
        )
        return
      }

      const eof = transfer.readOffset === transfer.fileSize
      sendFrame(sender, [
        'DATA',
        transfer.transferId,
        u64Frame(transfer.nextSequence),
        u64Frame(transfer.nextOffset),
        boolFrame(eof),
        compressed
      ])

      transfer.nextSequence += 1
      transfer.nextOffset += compressed.byteLength
      transfer.credit -= compressed.byteLength
      transfer.chunksSent += 1
    }

    maybeFinishReadTransfer(sender, state, transfer)
  } finally {
    transfer.draining = false
    // Credit may have arrived while this drain was in flight (sendReadData would
    // have bailed on `draining`). Re-kick if there is still work to do.
    if (!transfer.finished && transfer.credit > 0 && transfer.readOffset < transfer.fileSize) {
      void drainReadTransfer(sender, state, transfer)
    }
  }
}

/**
 * Reads a block from the open read file descriptor at the transfer offset.
 *
 * A read error returns null instead of throwing so the caller can emit a
 * protocol ERROR frame and close transfer state exactly once.
 */
function readTransferBlock(transfer: GetTransfer, size: number): Buffer | null {
  const buffer = Buffer.alloc(size)
  let totalRead = 0
  while (totalRead < size) {
    let bytesRead: number
    try {
      bytesRead = readSync(transfer.fd, buffer, totalRead, size - totalRead, transfer.readOffset)
    } catch {
      return null
    }
    if (bytesRead === 0) break
    totalRead += bytesRead
    transfer.readOffset += bytesRead
  }

  return totalRead === 0 ? null : buffer.subarray(0, totalRead)
}

/**
 * Emits READ_DONE once all bytes have been sent and the source still matches
 * the stat captured at READ_OPEN.
 */
function maybeFinishReadTransfer(sender: FileFrameSender, state: FileTransferState, transfer: GetTransfer): void {
  if (transfer.finished || transfer.readOffset < transfer.fileSize) {
    return
  }

  if (!readSourceStillStable(transfer)) {
    finishReadTransferWithError(sender, state, transfer, `file changed during read: ${transfer.address.virtualPath}`)
    return
  }

  transfer.finished = true
  closeTransferFile(transfer)
  state.gets.delete(transfer.transferId)
  sendFrame(sender, ['READ_DONE', transfer.transferId, u64Frame(transfer.chunksSent), u64Frame(transfer.nextOffset)])
}

/**
 * Detects source-file mutation during an active read.
 *
 * This is a cheap guard rather than a lock: the worker refuses to claim a clean
 * read if size or mtime changed while chunks were in flight.
 */
function readSourceStillStable(transfer: GetTransfer): boolean {
  if (!existsSync(transfer.filePath)) return false
  const current = statSync(transfer.filePath)
  return current.isFile() && current.size === transfer.initialSize && current.mtimeMs === transfer.initialMtimeMs
}

/**
 * Closes a transfer file descriptor at most once.
 */
function closeTransferFile(transfer: GetTransfer): void {
  if (transfer.fd !== -1) {
    try {
      closeSync(transfer.fd)
    } catch {
      // Best-effort close; the transfer is ending either way.
    }
    transfer.fd = -1
  }
}

/**
 * Ends a read transfer with a protocol ERROR reply and releases local state.
 */
function finishReadTransferWithError(
  sender: FileFrameSender,
  state: FileTransferState,
  transfer: GetTransfer,
  message: string
): void {
  if (transfer.finished) return

  transfer.finished = true
  closeTransferFile(transfer)
  state.gets.delete(transfer.transferId)
  sendError(sender, transfer.transferId, 'operation_failed', message)
}

/**
 * Returns metadata for a worker-visible file path.
 *
 * Fingerprints are optional because large files can be inspected without paying
 * the hash cost when the caller only needs size and mtime.
 */
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

/**
 * Deletes a file or, when explicitly requested, a directory tree.
 *
 * Directory deletion requires `recursive=true` so a malformed frame cannot
 * remove a tree through the single-file path by accident.
 */
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

/**
 * Moves a file or directory within the same worker root.
 *
 * Cross-root moves are rejected to keep user files and installed-skill storage
 * as separate ownership domains even though both are local filesystem paths.
 */
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

/**
 * Lists a directory with a hard entry cap.
 *
 * The cap protects the file lane from accidentally serializing an unbounded
 * subtree into one response frame.
 */
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

/**
 * Resolves a virtual file address to an absolute path under its declared root.
 *
 * Both normalization and `relative()` checks are used because string-prefix
 * checks alone are easy to bypass with `..`, absolute paths, or separators.
 */
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

/**
 * Builds the scratch directory for one write transfer and verifies it stays
 * under the shared transfer scratch root.
 */
function scratchDirectoryFor(config: WorkerConfig, transferId: string): string {
  const scratchRoot = resolve(config.sharedFsRoot, transferScratchDir)
  const tempDir = resolve(scratchRoot, safeTransferId(transferId))
  const rel = relative(scratchRoot, tempDir)

  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`transfer_id escapes scratch root: ${transferId}`)
  }

  return tempDir
}

/**
 * Removes all local state for an incomplete write transfer.
 */
function cleanupWriteTransfer(state: FileTransferState, transferId: string): void {
  const transfer = state.puts.get(transferId)
  if (!transfer) return

  rmSync(transfer.tempDir, { recursive: true, force: true })
  state.puts.delete(transferId)
}

/**
 * Removes a temporary path while preserving the original failure.
 */
function removePathBestEffort(path: string): void {
  try {
    rmSync(path, { force: true })
  } catch {
    // Parent-path conflicts can make best-effort temp cleanup itself fail.
  }
}

/**
 * Maps the protocol's virtual roots to worker-owned filesystem roots.
 */
function rootPathFor(config: WorkerConfig, root: string): string {
  return match(root)
    .with('user_files', () => config.userFilesRoot)
    .with('agent_installed_skills', () => config.agentInstalledSkillsRoot)
    .otherwise(() => {
      throw new Error(`unsupported file root: ${root}`)
    })
}

/**
 * Parses the virtual path frame used by file-lane commands.
 *
 * The protocol exposes stable worker paths like `/user_files/a.txt`; this
 * helper separates the protocol root from the normalized root-relative path.
 */
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

/**
 * Normalizes and validates root-relative paths from wire frames.
 */
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

/**
 * Parses the optional fingerprint mode requested by the caller.
 */
function fingerprintMode(value: unknown): FingerprintMode {
  if (value === undefined || value === null || value === '') return 'xxh3_128'
  if (value === 'none' || value === 'xxh3_128') return value
  throw new Error(`unsupported fingerprint: ${String(value)}`)
}

/**
 * Reads an unsigned 64-bit integer frame into JavaScript's safe integer range.
 */
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

/**
 * Encodes a JavaScript safe integer as a big-endian u64 frame.
 */
function u64Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`invalid u64 value: ${value}`)
  }

  const frame = Buffer.alloc(8)
  frame.writeBigUInt64BE(BigInt(value))
  return frame
}

/**
 * Reads a one-byte boolean frame.
 */
function readBoolFrame(frame: Buffer | undefined, label: string): boolean {
  if (!frame || frame.byteLength !== 1 || (frame[0] !== 0 && frame[0] !== 1)) {
    throw new Error(`${label} must be a bool frame`)
  }
  return frame[0] === 1
}

/**
 * Encodes a boolean frame.
 */
function boolFrame(value: boolean): Buffer {
  return Buffer.from([value ? 1 : 0])
}

/**
 * Reads a required UTF-8 text frame.
 */
function requiredTextFrame(frame: Buffer | undefined, label: string): string {
  const text = textFrame(frame)
  if (!text) {
    throw new Error(`${label} frame is required`)
  }
  return text
}

/**
 * Reads an optional UTF-8 text frame.
 */
function textFrame(frame: Buffer | undefined): string | undefined {
  if (!frame) return undefined
  return frame.toString('utf8')
}

/**
 * Validates a transfer id before using it in scratch filesystem paths.
 */
function safeTransferId(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value
}

/**
 * Computes or reuses an XXH3 fingerprint for a file.
 *
 * The cache key is invalidated on known local mutations; size+mtime are checked
 * to avoid returning a stale hash after out-of-band changes.
 */
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

/**
 * Invalidates one cached fingerprint.
 */
function forgetFingerprint(state: FileTransferState, root: FileRoot, relativePath: string): void {
  state.fingerprints.delete(fingerprintCacheKey(root, normalizeRelativePath(relativePath)))
}

/**
 * Invalidates cached fingerprints below a moved or deleted directory.
 */
function forgetFingerprintTree(state: FileTransferState, root: FileRoot, relativePath: string): void {
  const prefix = `${root}:${normalizeRelativePath(relativePath)}`
  for (const key of state.fingerprints.keys()) {
    if (key === prefix || key.startsWith(`${prefix}/`)) {
      state.fingerprints.delete(key)
    }
  }
}

/**
 * Builds the cache key for a root-relative fingerprint.
 */
function fingerprintCacheKey(root: FileRoot, relativePath: string): string {
  return `${root}:${normalizeRelativePath(relativePath)}`
}

/**
 * Caps directory-list responses to a defensible maximum.
 */
function boundedMaxEntries(value: number): number {
  if (value < 1) throw new Error('max_entries must be positive')
  return Math.min(value, 10_000)
}

/**
 * Walks a directory in deterministic name order and stops at the caller's cap.
 */
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

/**
 * Encodes list entries as length-prefixed binary frames.
 */
function encodeEntries(entries: ListEntry[]): Buffer {
  return Buffer.concat([u32Frame(entries.length), ...entries.flatMap(encodeEntry)])
}

/**
 * Encodes one directory entry for the LIST response payload.
 */
function encodeEntry(entry: ListEntry): Buffer[] {
  return [
    sizedStringFrame(entry.relative_path),
    sizedStringFrame(entry.kind),
    u64Frame(entry.size),
    u64Frame(entry.modified_unix_ms)
  ]
}

/**
 * Encodes a string with a u32 byte-length prefix.
 */
function sizedStringFrame(value: string): Buffer {
  const bytes = Buffer.from(value)
  return Buffer.concat([u32Frame(bytes.byteLength), bytes])
}

/**
 * Encodes a JavaScript safe integer as a big-endian u32 frame.
 */
function u32Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffffffff) {
    throw new Error(`invalid u32 value: ${value}`)
  }

  const frame = Buffer.alloc(4)
  frame.writeUInt32BE(value)
  return frame
}

/**
 * Sends a file-lane ERROR frame.
 */
function sendError(sender: FileFrameSender, transferId: string, code: string, message: string): void {
  sendFrame(sender, ['ERROR', transferId, code, message])
}

/**
 * Prepends the file-lane protocol marker and sends a multipart frame.
 */
function sendFrame(sender: FileFrameSender, parts: Array<string | Buffer>): void {
  sender.sendFileFrame([
    fileTransferProtocol,
    ...parts.map(part => (typeof part === 'string' ? Buffer.from(part) : part))
  ])
}

/**
 * Reads an open write transfer or fails with a protocol error.
 */
function getPutTransfer(state: FileTransferState, transferId: string): PutTransfer {
  const transfer = state.puts.get(transferId)
  if (!transfer) {
    throw new Error(`unknown file transfer: ${transferId}`)
  }
  return transfer
}
