import type { FileFrameSender } from '../../fabric/fabric'
import type { WorkerConfig } from '../../worker/config'

export type FileRoot = 'user_files' | 'agent_installed_skills' | 'workspace_sessions' | 'codex_accounts'

export type FingerprintMode = 'none' | 'xxh3_128'

export type FileAddress = {
  root: FileRoot
  relativePath: string
  virtualPath: string
}

export type FingerprintCacheEntry = {
  size: number
  mtimeMs: number
  xxh3_128: string
}

export type PutTransfer = {
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

export type GetTransfer = {
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

export type FileTransferContext = {
  config: WorkerConfig
  sender: FileFrameSender
  state: FileTransferState
}

export type ListEntry = {
  relative_path: string
  kind: 'file' | 'directory' | 'other'
  size: number
  modified_unix_ms: number
}
