import { isOfficeSpreadsheetFile, isPresentationFile, isWordFile } from '../../common/file-preview'

export type OfficeFormat = 'spreadsheet' | 'word' | 'presentation'

/**
 * Classifies a file Page name into one of Pod's three collaborative Office
 * formats. Upload deduplication may append ` (2)` after the extension, so duplicate suffixes are
 * stripped before checking the extension.
 */
export function officeFileFormat(name?: string | null): OfficeFormat | undefined {
  if (!name) return undefined
  if (isOfficeSpreadsheetFile(name)) return 'spreadsheet'
  if (isWordFile(name)) return 'word'
  if (isPresentationFile(name)) return 'presentation'
  return undefined
}
