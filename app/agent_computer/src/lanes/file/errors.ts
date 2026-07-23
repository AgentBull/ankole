export type FileTransferErrorCode = 'file_changed' | 'file_not_found' | 'not_regular_file'

export class FileTransferError extends Error {
  constructor(
    readonly code: FileTransferErrorCode,
    message: string
  ) {
    super(message)
    this.name = 'FileTransferError'
  }
}
