export const TEXT_PREVIEW_BYTES = 64 * 1024

// Pod guesses a media type from the extension only for the formats that it previews by media type. The control plane
// applies its own `MIME.from_path/1` fallback when it serves such a file, so a PDF without a recorded type still
// arrives inline.
const MEDIA_TYPE_BY_EXTENSION: Record<string, string> = {
  pdf: 'application/pdf',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  avif: 'image/avif',
  bmp: 'image/bmp',
  svg: 'image/svg+xml',
  mp4: 'video/mp4',
  m4v: 'video/mp4',
  webm: 'video/webm',
  ogv: 'video/ogg',
  mov: 'video/quicktime',
  mp3: 'audio/mpeg',
  m4a: 'audio/mp4',
  aac: 'audio/aac',
  wav: 'audio/wav',
  oga: 'audio/ogg',
  ogg: 'audio/ogg',
  opus: 'audio/ogg',
  flac: 'audio/flac'
}

/**
 * Returns the lowercase media type that decides a file preview. A missing or generic `application/octet-stream`
 * type, which uploads and external channels often record, falls back to the type that the file extension implies.
 */
export function previewMediaType(name: string, type?: string | null): string | undefined {
  const mime = type?.split(';')[0]?.trim().toLowerCase()
  if (mime && mime !== 'application/octet-stream') return mime
  const extension = name.includes('.') ? name.split('.').at(-1)?.toLowerCase() : undefined
  return (extension && MEDIA_TYPE_BY_EXTENSION[extension]) || mime || undefined
}

export function isTextFile(name: string, mime?: string) {
  return Boolean(
    mime?.startsWith('text/') ||
    ['application/json', 'application/xml', 'application/javascript'].includes(mime ?? '') ||
    /\.(txt|md|markdown|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html|sql|toml)$/i.test(name)
  )
}

export function isMarkdownFile(name: string, mime?: string) {
  return /\.(md|markdown)$/i.test(name) || mime === 'text/markdown'
}

export function isDelimitedTextTable(name: string, mime?: string) {
  return /\.(csv|tsv)$/i.test(name) || mime === 'text/csv' || mime === 'text/tab-separated-values'
}

/** Workbook formats that SheetJS reads into a read-only table preview. */
export function isWorkbookFile(name: string, mime?: string) {
  return (
    /\.(xlsx|xlsm|xls|xlsb|ods)$/i.test(name) ||
    Boolean(mime?.includes('spreadsheet') || mime?.startsWith('application/vnd.ms-excel'))
  )
}

export function isPresentationFile(name: string, mime?: string) {
  return /\.pptx$/i.test(name) || Boolean(mime?.includes('presentationml'))
}
