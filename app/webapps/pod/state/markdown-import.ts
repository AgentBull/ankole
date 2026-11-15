import { importMarkdownDocument } from '@ankole/block-editor/document'
import { sanitizeRenameValue } from '../../common/bidi'
import { isMarkdownFile, previewMediaType } from '../../common/file-preview'
import type { PodPageCreateResponse } from '../api/generated/types.gen'
import { limitPageTitle, pageAPI } from '../content-api'
import { createFilePage } from '../native-transfers'

export type UploadDestination = { parent_id?: string; private_owner_uid?: string }

const MARKDOWN_EXTENSION_RE = /(?:\._a(?:doc|wiki))?\.(?:md|markdown)$/i

export function isMarkdownUpload(file: Pick<File, 'name' | 'type'>): boolean {
  return isMarkdownFile(file.name, previewMediaType(file.name, file.type))
}

export function markdownFilenameStem(filename: string): string {
  const base = filename.split(/[\\/]/).at(-1) ?? filename
  return sanitizeRenameValue(base.replace(MARKDOWN_EXTENSION_RE, ''))
}

function decodeMarkdownBytes(bytes: Uint8Array): string {
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return new TextDecoder('utf-16le').decode(bytes.subarray(2))
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return new TextDecoder('utf-16be').decode(bytes.subarray(2))
  }
  return new TextDecoder('utf-8').decode(bytes)
}

export async function parseUploadedMarkdownFile(file: File): Promise<{ title: string; xml: string }> {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const source = decodeMarkdownBytes(bytes)
  const parsed = importMarkdownDocument(source, markdownFilenameStem(file.name))
  return {
    title: limitPageTitle(sanitizeRenameValue(parsed.title)),
    xml: parsed.xml
  }
}

/**
 * Creates a Document Page from a Markdown file in collaboration trees, or a File Page otherwise
 * (non-Markdown files and Brain knowledge attachments).
 */
export async function createUploadedPage(
  file: File,
  destination: UploadDestination,
  options?: { allowMarkdownDoc?: boolean }
): Promise<PodPageCreateResponse> {
  if ((options?.allowMarkdownDoc ?? true) && isMarkdownUpload(file)) {
    const { title, xml } = await parseUploadedMarkdownFile(file)
    return pageAPI.create({
      type: 'doc',
      title,
      xml,
      ...destination
    })
  }
  return createFilePage(file, destination)
}
