/**
 * Shared value types for External Gateway adapter I/O.
 *
 * Runtime delivery uses `core/events.ts`; this module only keeps the small
 * structures shared by outbound payload assembly.
 */

/**
 * One file attachment handed to an adapter for outbound delivery.
 *
 * `data` accepts the three in-memory binary shapes producers already have, so
 * callers do not have to convert before handing bytes to the adapter. The
 * adapter decides how to upload them to its platform.
 */
export interface FileUpload {
  data: Buffer | Blob | ArrayBuffer
  filename: string
  mimeType?: string
}
