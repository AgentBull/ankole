import { afterEach, beforeAll, describe, expect, spyOn, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import { loadLocale } from '../../common/i18n'
import { contentKeys, pageAPI, type PageDetail } from '../content-api'
import * as nativeTransfers from '../native-transfers'
import { uploadFileSubpages } from '../page-create-menu'
import { documentFilename, documentMarkdown } from './document-tools'
import {
  createUploadedPage,
  isMarkdownUpload,
  markdownFilenameStem,
  parseUploadedMarkdownFile
} from './markdown-import'

beforeAll(() => loadLocale('en-US'))

type CreatedPage = PageDetail['page']

function fakePage(overrides: Partial<CreatedPage> & Pick<CreatedPage, 'id' | 'type' | 'title'>): CreatedPage {
  return {
    name: overrides.title || 'untitled',
    icon: null,
    position: 'a0',
    inherit_permissions: true,
    metadata: {},
    revision: 1,
    children_view: {},
    created_at: '2026-11-15T00:00:00Z',
    updated_at: '2026-11-15T00:00:00Z',
    deleted_at: null,
    actions: ['node_view', 'node_edit'],
    role: 'edit',
    ...overrides
  }
}

describe('Markdown file upload conversion', () => {
  afterEach(() => {
    // Restore any spies registered during individual tests.
  })

  test('identifies Markdown uploads by extension or media type and extracts clean filename stems', () => {
    expect(isMarkdownUpload({ name: 'Quarterly report.md', type: '' })).toBe(true)
    expect(isMarkdownUpload({ name: 'README.MD', type: 'text/plain' })).toBe(true)
    expect(isMarkdownUpload({ name: 'guide.markdown', type: 'application/octet-stream' })).toBe(true)
    expect(isMarkdownUpload({ name: 'exported', type: 'text/markdown; charset=utf-8' })).toBe(true)
    expect(isMarkdownUpload({ name: 'notes.txt', type: 'text/plain' })).toBe(false)
    expect(isMarkdownUpload({ name: 'data.csv', type: 'text/csv' })).toBe(false)
    expect(isMarkdownUpload({ name: 'slides.pptx', type: '' })).toBe(false)

    expect(markdownFilenameStem('my.v2.spec.md')).toBe('my.v2.spec')
    expect(markdownFilenameStem('guide._adoc.md')).toBe('guide')
    expect(markdownFilenameStem('entity._awiki.markdown')).toBe('entity')
    expect(markdownFilenameStem('\u202EReport\u202C.MD')).toBe('Report')
  })

  test('round-trips Ankole exported Markdown and decodes UTF-16 BOM and grapheme-capped titles', async () => {
    const originalXml = '<page><h2>Milestones</h2><ul><li task="done"><p>Ship parser</p></li></ul></page>'
    const exported = documentMarkdown(originalXml, 'Quarterly Review 2026')
    const exportedFile = new File([exported], documentFilename('Quarterly Review 2026'), {
      type: 'text/markdown;charset=utf-8'
    })

    const roundTripped = await parseUploadedMarkdownFile(exportedFile)
    expect(roundTripped).toEqual({
      title: 'Quarterly Review 2026',
      xml: originalXml
    })

    // UTF-16 LE BOM file with emoji title exceeding 255 code points.
    const longHeading = `# ${'😀'.repeat(260)}\n\nUTF-16 body paragraph.`
    const utf16Bytes = new Uint8Array(2 + longHeading.length * 2)
    utf16Bytes[0] = 0xff
    utf16Bytes[1] = 0xfe
    for (let i = 0; i < longHeading.length; i++) {
      const unit = longHeading.charCodeAt(i)
      utf16Bytes[2 + i * 2] = unit & 0xff
      utf16Bytes[2 + i * 2 + 1] = unit >> 8
    }
    const utf16File = new File([utf16Bytes], 'utf16-notes.md', { type: 'text/markdown' })
    const parsedUtf16 = await parseUploadedMarkdownFile(utf16File)
    expect([...parsedUtf16.title]).toHaveLength(255)
    expect(parsedUtf16.title).toBe('😀'.repeat(255))
    expect(parsedUtf16.xml).toBe('<page><p>UTF-16 body paragraph.</p></page>')
  })

  test('creates Document Pages for Markdown uploads in collaboration trees and File Pages for non-Markdown or Brain uploads', async () => {
    const createDocSpy = spyOn(pageAPI, 'create').mockImplementation(async body => ({
      page: fakePage({
        id: `doc-${body.title || 'untitled'}`,
        type: 'doc',
        title: body.title ?? '',
        parent_id: body.parent_id ?? null,
        private_owner_uid: body.private_owner_uid ?? null
      })
    }))
    const createFileSpy = spyOn(nativeTransfers, 'createFilePage').mockImplementation(async (file, destination) => ({
      page: fakePage({
        id: `file-${file.name}`,
        type: 'file',
        title: file.name,
        parent_id: destination.parent_id ?? null,
        private_owner_uid: destination.private_owner_uid ?? null
      })
    }))

    try {
      // Space root Markdown upload -> Document Page
      const spaceMd = new File(['# Architecture\n\nPostgreSQL owns durable state.'], 'arch.md', {
        type: 'text/markdown'
      })
      const createdSpaceDoc = await createUploadedPage(spaceMd, {})
      expect(createdSpaceDoc.page.type).toBe('doc')
      expect(createDocSpy).toHaveBeenCalledWith({
        type: 'doc',
        title: 'Architecture',
        xml: '<page><p>PostgreSQL owns durable state.</p></page>'
      })
      expect(createFileSpy).not.toHaveBeenCalled()

      // Mixed subpage batch under a Document Page -> Doc Page for `.md`, File Page for `.txt`
      const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
      const parentDocID = '019a2b00-0000-7000-8000-000000000100'
      client.setQueryData(contentKeys.children('space', parentDocID), {
        pages: [{ pages: [], next_cursor: null }],
        pageParams: [undefined]
      })

      await uploadFileSubpages(client, parentDocID, [
        new File(['- [x] Ready'], 'rollout-notes.md', { type: 'text/plain' }),
        new File(['raw text'], 'appendix.txt', { type: 'text/plain' })
      ])

      expect(createDocSpy).toHaveBeenLastCalledWith({
        type: 'doc',
        title: 'rollout-notes',
        xml: '<page><ul><li task="done"><p>Ready</p></li></ul></page>',
        parent_id: parentDocID
      })
      expect(createFileSpy).toHaveBeenCalledTimes(1)
      expect(createFileSpy).toHaveBeenLastCalledWith(expect.any(File), { parent_id: parentDocID })

      // Brain knowledge parent -> keeps `.md` upload as a File Page attachment
      const brainParentID = '019a2b00-0000-7000-8000-000000000200'
      const brainDetail: PageDetail = {
        page: fakePage({ id: brainParentID, type: 'knowledge', title: 'Customer Entity' }),
        ancestors: [],
        actions: ['node_view', 'node_edit'],
        role: 'edit',
        child_count: 0
      }
      client.setQueryData(contentKeys.page(brainParentID), brainDetail)

      await uploadFileSubpages(client, brainParentID, [
        new File(['# Source Transcript\n\nVerbatim attachment.'], 'transcript.md', { type: 'text/markdown' })
      ])
      expect(createDocSpy).toHaveBeenCalledTimes(2)
      expect(createFileSpy).toHaveBeenCalledTimes(2)
      expect(createFileSpy).toHaveBeenLastCalledWith(expect.any(File), { parent_id: brainParentID })
      client.clear()
    } finally {
      createDocSpy.mockRestore()
      createFileSpy.mockRestore()
    }
  })
})
