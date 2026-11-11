import { describe, expect, it } from 'bun:test'
import { isOfficeSpreadsheetFile, isPresentationFile } from '../../common/file-preview'
import { officeFileFormat } from './office-files'

describe('officeFileFormat', () => {
  it('classifies spreadsheet, word, and presentation extensions including upload duplicate suffixes', () => {
    expect(officeFileFormat('Budget.xlsx')).toBe('spreadsheet')
    expect(officeFileFormat('Macro.XLSM (2)')).toBe('spreadsheet')
    expect(officeFileFormat('Proposal.docx')).toBe('word')
    expect(officeFileFormat('Template.docm (3)')).toBe('word')
    expect(officeFileFormat('Roadmap.pptx')).toBe('presentation')
    expect(officeFileFormat('Roadmap.PPTX (1)')).toBe('presentation')
  })

  it('rejects legacy binary Office formats, compound extensions, and non-Office files', () => {
    expect(officeFileFormat('Legacy.xls')).toBeUndefined()
    expect(officeFileFormat('Legacy.xlsb')).toBeUndefined()
    expect(officeFileFormat('Legacy.ods')).toBeUndefined()
    expect(officeFileFormat('Legacy.doc')).toBeUndefined()
    expect(officeFileFormat('Legacy.ppt')).toBeUndefined()
    expect(officeFileFormat('Report.pdf')).toBeUndefined()
    expect(officeFileFormat('Budget.xlsx.pdf')).toBeUndefined()
    expect(officeFileFormat('data.csv')).toBeUndefined()
  })

  it('keeps Office files identified by MIME alone in read-only previews', () => {
    const powerpoint = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
    const excel = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    expect(officeFileFormat('Roadmap')).toBeUndefined()
    expect(isPresentationFile('Roadmap', powerpoint)).toBe(true)
    expect(officeFileFormat('Budget')).toBeUndefined()
    expect(isOfficeSpreadsheetFile('Budget', excel)).toBe(true)
  })
})
