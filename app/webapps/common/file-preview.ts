export const TEXT_PREVIEW_BYTES = 64 * 1024
export const CODE_SOURCE_PREVIEW_BYTES = 256 * 1024
export const HTML_PREVIEW_BYTES = 16 * 1024 * 1024

// Pod guesses a media type from the extension only for the formats that it previews by media type. The control plane
// applies its own `MIME.from_path/1` fallback when it serves such a file, so a PDF without a recorded type still
// arrives inline.
const MEDIA_TYPE_BY_EXTENSION: Record<string, string> = {
  pdf: 'application/pdf',
  html: 'text/html',
  htm: 'text/html',
  xhtml: 'application/xhtml+xml',
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
  const base = stripDuplicateSuffix(name)
  return Boolean(
    mime?.startsWith('text/') ||
    ['application/json', 'application/xml', 'application/xhtml+xml', 'application/javascript'].includes(mime ?? '') ||
    /^(?:dockerfile|makefile)$/i.test(base) ||
    /\.(txt|md|markdown|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html?|xhtml|sql|toml)$/i.test(base)
  )
}

export function isHtmlFile(name: string, mime?: string) {
  const base = stripDuplicateSuffix(name)
  const normalizedMime = mime?.split(';')[0]?.trim().toLowerCase()
  return /\.(html?|xhtml)$/i.test(base) || normalizedMime === 'text/html' || normalizedMime === 'application/xhtml+xml'
}

export function isMarkdownFile(name: string, mime?: string) {
  const base = stripDuplicateSuffix(name)
  return /\.(md|markdown)$/i.test(base) || mime === 'text/markdown'
}

const CODE_LANGUAGE_ALIASES: Record<string, string> = {
  htm: 'html',
  xhtml: 'html',
  ex: 'elixir',
  exs: 'elixir',
  markdown: 'md',
  yml: 'yaml'
}

export function codeLanguageFromFileName(name: string): string | undefined {
  const base = stripDuplicateSuffix(name)
  const lower = base.toLowerCase()
  if (lower === 'dockerfile' || lower === 'makefile') return lower
  const extension = base.includes('.') ? base.split('.').at(-1)?.toLowerCase() : undefined
  if (!extension || extension === 'txt' || extension === 'text') return undefined
  return CODE_LANGUAGE_ALIASES[extension] ?? extension
}

export function isDelimitedTextTable(name: string, mime?: string) {
  return /\.(csv|tsv)$/i.test(name) || mime === 'text/csv' || mime === 'text/tab-separated-values'
}

const DUPLICATE_SUFFIX = /(?: \(\d+\))?$/

function stripDuplicateSuffix(name: string) {
  return name.replace(DUPLICATE_SUFFIX, '')
}

/** OOXML workbook formats (`.xlsx`, `.xlsm`) rendered and edited by `ankole_spreadsheet_wasm`. */
export function isOfficeSpreadsheetFile(name: string, mime?: string) {
  const base = stripDuplicateSuffix(name)
  return (
    /\.(xlsx|xlsm)$/i.test(base) ||
    mime === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
    mime === 'application/vnd.ms-excel.sheet.macroenabled.12'
  )
}

/** Legacy or OpenDocument workbooks (`.xls`, `.xlsb`, `.ods`) read into a SheetJS table preview. */
export function isLegacyWorkbookFile(name: string, mime?: string) {
  if (isOfficeSpreadsheetFile(name, mime)) return false
  const base = stripDuplicateSuffix(name)
  return (
    /\.(xls|xlsb|ods)$/i.test(base) ||
    Boolean(mime?.includes('spreadsheet') || mime?.startsWith('application/vnd.ms-excel'))
  )
}

/** Any spreadsheet workbook format supported by either WASM or SheetJS preview. */
export function isWorkbookFile(name: string, mime?: string) {
  return isOfficeSpreadsheetFile(name, mime) || isLegacyWorkbookFile(name, mime)
}

/** OOXML Word document formats (`.docx`, `.docm`) rendered and edited by `ankole_word_wasm`. */
export function isWordFile(name: string, mime?: string) {
  const base = stripDuplicateSuffix(name)
  return (
    /\.(docx|docm)$/i.test(base) ||
    mime === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
    mime === 'application/vnd.ms-word.document.macroenabled.12'
  )
}

/** OOXML presentation format (`.pptx`) rendered and edited by `ankole_presentation_wasm`. */
export function isPresentationFile(name: string, mime?: string) {
  const base = stripDuplicateSuffix(name)
  return (
    /\.pptx$/i.test(base) ||
    mime === 'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
    Boolean(mime?.includes('presentationml.presentation'))
  )
}
