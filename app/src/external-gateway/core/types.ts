/**
 * Shared value types for External Gateway adapter I/O.
 *
 * Runtime delivery uses `core/events.ts`; this module only keeps the small
 * structures shared by outbound payload assembly.
 */

export interface FileUpload {
  data: Buffer | Blob | ArrayBuffer
  filename: string
  mimeType?: string
}
