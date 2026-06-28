import type { SharedProviderReference } from './shared-provider-reference'

/**
 * File data variant containing raw bytes (`Uint8Array`) or a base64-encoded
 * string.
 */
export interface SharedFileDataData {
  type: 'data'
  data: Uint8Array | string
}

/**
 * File data variant containing a URL that points to the file.
 */
export interface SharedFileDataUrl {
  type: 'url'
  url: URL
}

/**
 * File data variant containing a provider reference (`{ [provider]: id }`).
 */
export interface SharedFileDataReference {
  type: 'reference'
  reference: SharedProviderReference
}

/**
 * File data variant containing inline text content (e.g. an inline text
 * document).
 */
export interface SharedFileDataText {
  type: 'text'
  text: string
}

/**
 * File data as a tagged discriminated union:
 *
 * - `{ type: 'data', data }`: raw bytes (`Uint8Array`) or base64-encoded string.
 * - `{ type: 'url', url }`: a URL that points to the file.
 * - `{ type: 'reference', reference }`: a provider reference (`{ [provider]: id }`).
 * - `{ type: 'text', text }`: inline text content (e.g. an inline text document).
 */
export type SharedFileData = SharedFileDataData | SharedFileDataUrl | SharedFileDataReference | SharedFileDataText
