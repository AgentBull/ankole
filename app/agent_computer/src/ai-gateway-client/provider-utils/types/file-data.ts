import type { SharedFileDataReference, SharedFileDataText, SharedFileDataUrl } from '@/ai-gateway-client/provider'
import type { DataContent } from './data-content'

/**
 * File data variant containing raw bytes (`Uint8Array`, `ArrayBuffer`, or
 * `Buffer`) or a base64-encoded string.
 *
 * This is slightly more permissive than `SharedFileDataData`.
 */
export interface FileDataData {
  type: 'data'
  data: DataContent
}

/**
 * File data variant containing a URL that points to the file.
 */
export type FileDataUrl = SharedFileDataUrl

/**
 * File data variant containing a provider reference (`{ [provider]: id }`).
 */
export type FileDataReference = SharedFileDataReference

/**
 * File data variant containing inline text content (e.g. an inline text
 * document).
 */
export type FileDataText = SharedFileDataText

/**
 * File data as a tagged discriminated union:
 *
 * - `{ type: 'data', data }`: raw bytes (`Uint8Array`, `ArrayBuffer`, or
 *   `Buffer`) or a base64-encoded string.
 * - `{ type: 'url', url }`: a URL that points to the file.
 * - `{ type: 'reference', reference }`: a provider reference (`{ [provider]: id }`).
 * - `{ type: 'text', text }`: inline text content (e.g. an inline text document).
 */
export type FileData = FileDataData | FileDataUrl | FileDataReference | FileDataText
