import { xxh3File128Hex } from '@ankole/kernel'
import { createReadStream, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { appendFile, copyFile, rename, unlink, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { Buffer } from 'node:buffer'
import type { WorkerConfig } from './runtime'

export const fileTransferProtocol = Buffer.from('ANKOLE_FILE/1')

const chunkSize = 1024 * 1024
const transferScratchDir = '.ankole-file-transfer'
const defaultContentEncoding: ContentEncoding = 'zstd'
const supportedContentEncodings = new Set(['identity', 'zstd'])

type FileFrameSender = {
  sendFileFrame(frames: Buffer[]): string
}

type PutTransfer = {
  transferId: string
  root: FileRoot
  relativePath: string
  targetPath: string
  tempDir: string
  payloadPath: string
  contentEncoding: ContentEncoding
  nextChunkIndex: number
  bytesReceived: number
  expectedOriginalSize?: number
}

export type FileTransferState = {
  puts: Map<string, PutTransfer>
  fingerprints: Map<string, FingerprintCacheEntry>
}

type FileRoot = 'user_files' | 'agent_installed_skills'
type ContentEncoding = 'identity' | 'zstd'
type FingerprintMode = 'none' | 'xxh3_128'

type FileAddress = {
  root: FileRoot
  relative_path: string
}

type PutBeginMetadata = FileAddress & {
  content_encoding?: ContentEncoding
  original_size?: number
}

type GetMetadata = FileAddress & {
  content_encoding?: ContentEncoding
  fingerprint?: FingerprintMode
}

type StatMetadata = FileAddress & {
  fingerprint?: FingerprintMode
}

type DeleteMetadata = FileAddress & {
  recursive?: boolean
}

type MoveMetadata = {
  root: FileRoot
  from_relative_path: string
  to_relative_path: string
  overwrite?: boolean
}

type ListMetadata = {
  root: FileRoot
  relative_path?: string
  recursive?: boolean
  max_entries?: number
}

type FingerprintCacheEntry = {
  size: number
  mtimeMs: number
  xxh3_128: string
}

type ListEntry = {
  relative_path: string
  kind: 'file' | 'directory' | 'other'
  size?: number
  modified_unix_ms: number
}

export function createFileTransferState(): FileTransferState {
  return { puts: new Map(), fingerprints: new Map() }
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

  try {
    if (!isFileTransferFrame(frames)) {
      throw new Error('invalid file-transfer protocol marker')
    }

    const command = requiredTextFrame(frames[1], 'command')
    switch (command) {
      case 'PUT_BEGIN':
        await handlePutBegin(config, sender, state, transferId, frames)
        return

      case 'PUT_CHUNK':
        await handlePutChunk(sender, state, transferId, frames)
        return

      case 'PUT_COMMIT':
        await handlePutCommit(sender, state, transferId)
        return

      case 'PUT_ABORT':
        handlePutAbort(sender, state, transferId)
        return

      case 'GET':
        await handleGet(config, sender, state, transferId, frames)
        return

      case 'STAT':
        await handleStat(config, sender, state, transferId, frames)
        return

      case 'DELETE':
        await handleDelete(config, sender, state, transferId, frames)
        return

      case 'MOVE':
        await handleMove(config, sender, state, transferId, frames)
        return

      case 'LIST':
        await handleList(config, sender, transferId, frames)
        return

      default:
        throw new Error(`unsupported file lane command: ${command}`)
    }
  } catch (error) {
    sendError(sender, transferId, error instanceof Error ? error.message : String(error))
  }
}

async function handlePutBegin(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  if (state.puts.has(transferId)) {
    throw new Error(`file transfer already exists: ${transferId}`)
  }

  const metadata = parseMetadata<PutBeginMetadata>(frames[3], 'put metadata')
  const contentEncoding = normalizeContentEncoding(metadata.content_encoding)
  if (contentEncoding === 'zstd') assertZstdAvailable()

  const targetPath = resolveFileAddress(config, metadata)
  const tempDir = join(config.sharedFsRoot, transferScratchDir, safeTransferId(transferId))
  const payloadPath = join(tempDir, contentEncoding === 'zstd' ? 'payload.zst' : 'payload.bin')

  rmSync(tempDir, { recursive: true, force: true })
  mkdirSync(tempDir, { recursive: true })
  await writeFile(payloadPath, Buffer.alloc(0))

  state.puts.set(transferId, {
    transferId,
    root: metadata.root,
    relativePath: metadata.relative_path,
    targetPath,
    tempDir,
    payloadPath,
    contentEncoding,
    nextChunkIndex: 0,
    bytesReceived: 0,
    expectedOriginalSize: optionalNonNegativeInteger(metadata.original_size, 'original_size')
  })

  sendAck(sender, transferId, { command: 'PUT_BEGIN', root: metadata.root, relative_path: metadata.relative_path })
}

async function handlePutChunk(
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const transfer = getPutTransfer(state, transferId)
  const chunkIndex = parseFrameInteger(frames[3], 'chunk_index')
  const chunk = frames[4]

  if (!chunk) {
    throw new Error('PUT_CHUNK requires a binary chunk frame')
  }
  if (chunkIndex !== transfer.nextChunkIndex) {
    throw new Error(`unexpected chunk_index ${chunkIndex}, expected ${transfer.nextChunkIndex}`)
  }

  await appendFile(transfer.payloadPath, chunk)
  transfer.nextChunkIndex += 1
  transfer.bytesReceived += chunk.byteLength
  sendAck(sender, transferId, { command: 'PUT_CHUNK', chunk_index: chunkIndex })
}

async function handlePutCommit(sender: FileFrameSender, state: FileTransferState, transferId: string): Promise<void> {
  const transfer = getPutTransfer(state, transferId)
  mkdirSync(dirname(transfer.targetPath), { recursive: true })

  const finalTempPath = `${transfer.targetPath}.ankole-transfer-${safeTransferId(transferId)}.tmp`
  rmSync(finalTempPath, { force: true })

  if (transfer.contentEncoding === 'zstd') {
    assertZstdAvailable()
    const result = spawnSync('zstd', ['-q', '-d', '-f', '-o', finalTempPath, transfer.payloadPath], {
      encoding: 'utf8'
    })
    if (result.status !== 0) {
      throw new Error(`zstd decode failed: ${result.stderr || result.error?.message || 'unknown error'}`)
    }
  } else {
    await copyFile(transfer.payloadPath, finalTempPath)
  }

  await verifyFinalFile(finalTempPath, transfer)
  await rename(finalTempPath, transfer.targetPath)
  const fingerprint = fileFingerprint(state, transfer.root, transfer.relativePath, transfer.targetPath)
  state.puts.delete(transferId)
  rmSync(transfer.tempDir, { recursive: true, force: true })

  sendAck(sender, transferId, {
    command: 'PUT_COMMIT',
    root: transfer.root,
    relative_path: transfer.relativePath,
    size: statSync(transfer.targetPath).size,
    xxh3_128: fingerprint
  })
}

function handlePutAbort(sender: FileFrameSender, state: FileTransferState, transferId: string): void {
  const transfer = state.puts.get(transferId)
  if (transfer) {
    rmSync(transfer.tempDir, { recursive: true, force: true })
    state.puts.delete(transferId)
  }

  sendAck(sender, transferId, { command: 'PUT_ABORT' })
}

async function handleGet(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const metadata = parseMetadata<GetMetadata>(frames[3], 'get metadata')
  const filePath = resolveFileAddress(config, metadata)
  const contentEncoding = normalizeContentEncoding(metadata.content_encoding)
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    throw new Error(`file does not exist: ${metadata.root}/${metadata.relative_path}`)
  }
  if (contentEncoding === 'zstd') assertZstdAvailable()

  sendFrame(sender, [
    'GET_BEGIN',
    transferId,
    jsonFrame({
      root: metadata.root,
      relative_path: metadata.relative_path,
      content_encoding: contentEncoding,
      original_size: statSync(filePath).size,
      xxh3_128:
        fingerprintMode(metadata.fingerprint) === 'none'
          ? undefined
          : fileFingerprint(state, metadata.root, metadata.relative_path, filePath)
    })
  ])

  const chunks =
    contentEncoding === 'zstd'
      ? await streamZstdFile(sender, transferId, filePath)
      : await streamIdentityFile(sender, transferId, filePath)

  sendFrame(sender, ['GET_END', transferId, jsonFrame({ chunks, content_encoding: contentEncoding })])
}

async function handleStat(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const metadata = parseMetadata<StatMetadata>(frames[3], 'stat metadata')
  const filePath = resolveFileAddress(config, metadata)
  if (!existsSync(filePath)) {
    throw new Error(`path does not exist: ${metadata.root}/${metadata.relative_path}`)
  }

  const stat = statSync(filePath)
  const payload: Record<string, unknown> = {
    command: 'STAT',
    root: metadata.root,
    relative_path: metadata.relative_path,
    kind: stat.isFile() ? 'file' : stat.isDirectory() ? 'directory' : 'other',
    size: stat.size,
    modified_unix_ms: Math.floor(stat.mtimeMs)
  }

  if (stat.isFile() && fingerprintMode(metadata.fingerprint) === 'xxh3_128') {
    payload.xxh3_128 = fileFingerprint(state, metadata.root, metadata.relative_path, filePath)
  }

  sendAck(sender, transferId, payload)
}

async function handleDelete(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const metadata = parseMetadata<DeleteMetadata>(frames[3], 'delete metadata')
  const filePath = resolveFileAddress(config, metadata)
  if (!existsSync(filePath)) {
    throw new Error(`path does not exist: ${metadata.root}/${metadata.relative_path}`)
  }

  const stat = statSync(filePath)
  if (stat.isDirectory()) {
    if (metadata.recursive !== true) {
      throw new Error('DELETE requires recursive=true for directories')
    }
    rmSync(filePath, { recursive: true, force: true })
    forgetFingerprintTree(state, metadata.root, metadata.relative_path)
  } else {
    await unlink(filePath)
    forgetFingerprint(state, metadata.root, metadata.relative_path)
  }

  sendAck(sender, transferId, {
    command: 'DELETE',
    root: metadata.root,
    relative_path: metadata.relative_path,
    deleted: true
  })
}

async function handleMove(
  config: WorkerConfig,
  sender: FileFrameSender,
  state: FileTransferState,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const metadata = parseMetadata<MoveMetadata>(frames[3], 'move metadata')
  const fromPath = resolveFileAddress(config, {
    root: metadata.root,
    relative_path: metadata.from_relative_path
  })
  const toRelativePath = normalizeRelativePath(metadata.to_relative_path)
  const toPath = resolveFileAddress(config, {
    root: metadata.root,
    relative_path: toRelativePath
  })

  if (!existsSync(fromPath)) {
    throw new Error(`path does not exist: ${metadata.root}/${metadata.from_relative_path}`)
  }
  if (existsSync(toPath) && metadata.overwrite !== true) {
    throw new Error(`target path already exists: ${metadata.root}/${toRelativePath}`)
  }

  mkdirSync(dirname(toPath), { recursive: true })
  if (existsSync(toPath)) rmSync(toPath, { recursive: true, force: true })
  const movingDirectory = statSync(fromPath).isDirectory()
  await rename(fromPath, toPath)
  if (movingDirectory) {
    forgetFingerprintTree(state, metadata.root, metadata.from_relative_path)
    forgetFingerprintTree(state, metadata.root, toRelativePath)
  } else {
    forgetFingerprint(state, metadata.root, metadata.from_relative_path)
    forgetFingerprint(state, metadata.root, toRelativePath)
  }

  sendAck(sender, transferId, {
    command: 'MOVE',
    root: metadata.root,
    from_relative_path: metadata.from_relative_path,
    to_relative_path: toRelativePath,
    moved: true
  })
}

async function handleList(
  config: WorkerConfig,
  sender: FileFrameSender,
  transferId: string,
  frames: Buffer[]
): Promise<void> {
  const metadata = parseMetadata<ListMetadata>(frames[3], 'list metadata')
  const relativePath = normalizeRelativePath(metadata.relative_path ?? '', { allowRoot: true })
  const directoryPath = resolveFileAddress(
    config,
    {
      root: metadata.root,
      relative_path: relativePath
    },
    { allowRoot: true }
  )

  if (!existsSync(directoryPath) || !statSync(directoryPath).isDirectory()) {
    throw new Error(`directory does not exist: ${metadata.root}/${relativePath}`)
  }

  const maxEntries = boundedMaxEntries(metadata.max_entries)
  const { entries, truncated } = listDirectory(directoryPath, relativePath, metadata.recursive === true, maxEntries)

  sendFrame(sender, [
    'LIST_RESULT',
    transferId,
    jsonFrame({
      command: 'LIST',
      root: metadata.root,
      relative_path: relativePath,
      recursive: metadata.recursive === true,
      entries,
      truncated
    })
  ])
}

async function streamIdentityFile(sender: FileFrameSender, transferId: string, filePath: string): Promise<number> {
  let chunkIndex = 0
  for await (const chunk of createReadStream(filePath, { highWaterMark: chunkSize })) {
    sendFrame(sender, ['GET_CHUNK', transferId, Buffer.from(String(chunkIndex)), Buffer.from(chunk)])
    chunkIndex += 1
  }
  return chunkIndex
}

async function streamZstdFile(sender: FileFrameSender, transferId: string, filePath: string): Promise<number> {
  const child = spawn('zstd', ['-q', '-c', filePath], {
    stdio: ['ignore', 'pipe', 'pipe']
  })
  let stderr = ''
  child.stderr?.setEncoding('utf8')
  child.stderr?.on('data', chunk => {
    stderr += chunk
  })

  let chunkIndex = 0
  for await (const chunk of child.stdout) {
    sendFrame(sender, ['GET_CHUNK', transferId, Buffer.from(String(chunkIndex)), Buffer.from(chunk)])
    chunkIndex += 1
  }

  await waitForSuccessfulExit(child, stderr, 'zstd encode')
  return chunkIndex
}

async function verifyFinalFile(path: string, transfer: PutTransfer): Promise<void> {
  const stat = statSync(path)
  if (transfer.expectedOriginalSize !== undefined && stat.size !== transfer.expectedOriginalSize) {
    throw new Error(`size mismatch after file transfer: expected ${transfer.expectedOriginalSize}, got ${stat.size}`)
  }
}

function resolveFileAddress(config: WorkerConfig, address: FileAddress, opts: { allowRoot?: boolean } = {}): string {
  const rootPath = rootPathFor(config, address.root)
  const relativePath = normalizeRelativePath(address.relative_path, opts)
  const resolvedRoot = resolve(rootPath)
  const resolvedPath = resolve(resolvedRoot, relativePath)
  const rel = relative(resolvedRoot, resolvedPath)

  if ((!opts.allowRoot && rel === '') || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`relative_path escapes root: ${address.relative_path}`)
  }

  return resolvedPath
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

function normalizeContentEncoding(value: unknown): ContentEncoding {
  const encoding = typeof value === 'string' && value.length > 0 ? value : defaultContentEncoding
  if (!supportedContentEncodings.has(encoding)) {
    throw new Error(`unsupported content_encoding: ${encoding}`)
  }
  return encoding as ContentEncoding
}

function fingerprintMode(value: unknown): FingerprintMode {
  if (value === undefined || value === null || value === '') return 'xxh3_128'
  if (value === 'none' || value === 'xxh3_128') return value
  throw new Error(`unsupported fingerprint: ${String(value)}`)
}

function parseMetadata<T>(frame: Buffer | undefined, label: string): T {
  if (!frame) {
    throw new Error(`${label} frame is required`)
  }

  const parsed = JSON.parse(frame.toString('utf8'))
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON object`)
  }

  return parsed as T
}

function parseFrameInteger(frame: Buffer | undefined, label: string): number {
  const text = requiredTextFrame(frame, label)
  if (!/^(0|[1-9][0-9]*)$/.test(text)) {
    throw new Error(`${label} must be a non-negative integer`)
  }
  return Number(text)
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

function optionalNonNegativeInteger(value: unknown, label: string): number | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${label} must be a non-negative safe integer`)
  }
  return value
}

function safeTransferId(value: string): string {
  if (!/^[a-zA-Z0-9._:-]{1,128}$/.test(value)) {
    throw new Error(`invalid transfer_id: ${value}`)
  }
  return value.replaceAll(':', '_')
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

function boundedMaxEntries(value: unknown): number {
  if (value === undefined || value === null) return 1000
  const maxEntries = optionalNonNegativeInteger(value, 'max_entries')
  if (maxEntries === undefined || maxEntries < 1) throw new Error('max_entries must be positive')
  return Math.min(maxEntries, 10_000)
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
        size: entry.isFile() ? stat.size : undefined,
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

function assertZstdAvailable(): void {
  const result = spawnSync('zstd', ['--version'], { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`zstd is required for file transfer: ${result.stderr || result.error?.message || 'not found'}`)
  }
}

function sendAck(sender: FileFrameSender, transferId: string, payload: Record<string, unknown>): void {
  sendFrame(sender, ['ACK', transferId, jsonFrame(payload)])
}

function sendError(sender: FileFrameSender, transferId: string, message: string): void {
  sendFrame(sender, ['ERROR', transferId, jsonFrame({ message })])
}

function sendFrame(sender: FileFrameSender, parts: Array<string | Buffer>): void {
  sender.sendFileFrame([
    fileTransferProtocol,
    ...parts.map(part => (typeof part === 'string' ? Buffer.from(part) : part))
  ])
}

function jsonFrame(payload: Record<string, unknown>): Buffer {
  return Buffer.from(JSON.stringify(payload))
}

function getPutTransfer(state: FileTransferState, transferId: string): PutTransfer {
  const transfer = state.puts.get(transferId)
  if (!transfer) {
    throw new Error(`unknown file transfer: ${transferId}`)
  }
  return transfer
}

async function waitForSuccessfulExit(child: ReturnType<typeof spawn>, stderr: string, label: string): Promise<void> {
  const code = await new Promise<number | null>((resolve, reject) => {
    child.once('error', reject)
    child.once('close', resolve)
  })

  if (code !== 0) {
    throw new Error(`${label} failed: ${stderr || `exit ${code}`}`)
  }
}
