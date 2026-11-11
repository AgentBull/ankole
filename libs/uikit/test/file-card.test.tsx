import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { FileCard, FileCardList, FileTypeMark, fileTypeKind } from '../src/components/file-card'
import { attributeOf, classesOf, tagWith } from './markup'

describe('fileTypeKind', () => {
  test('reads the extension before the media type, which uploads often leave generic', () => {
    expect(fileTypeKind('report.PDF', 'application/octet-stream')).toBe('pdf')
    expect(fileTypeKind('budget.xlsx')).toBe('table')
    expect(fileTypeKind('rebates.csv', 'text/csv')).toBe('table')
    expect(fileTypeKind('memo.m4a', 'audio/mp4')).toBe('audio')
    expect(fileTypeKind('worker.ts', 'video/mp2t')).toBe('text')
    expect(fileTypeKind('bundle.tar.gz')).toBe('archive')
  })

  test('falls back to the media type, and to a plain file when neither is known', () => {
    expect(fileTypeKind('scan', 'image/png')).toBe('image')
    expect(fileTypeKind(undefined, 'application/pdf')).toBe('pdf')
    expect(fileTypeKind('notes', 'text/markdown')).toBe('markdown')
    expect(fileTypeKind('.env')).toBe('file')
    expect(fileTypeKind('data.bin', 'application/octet-stream')).toBe('file')
  })
})

describe('FileTypeMark', () => {
  test('draws a 20px mark in the secondary colour for the kind of file, hidden from assistive technology', () => {
    const mark = tagWith(renderToStaticMarkup(<FileTypeMark fileName="report.pdf" />), 'data-slot="file-type-mark"')
    expect(attributeOf(mark, 'data-kind')).toBe('pdf')
    expect(attributeOf(mark, 'aria-hidden')).toBe('true')
    expect(classesOf(mark)).toEqual(expect.arrayContaining(['size-5', 'text-fg-secondary']))
    const large = tagWith(renderToStaticMarkup(<FileTypeMark fileName="report.pdf" className="size-10" />), 'data-kind')
    expect(classesOf(large)).toContain('size-10')
    expect(classesOf(large)).not.toContain('size-5')
  })
})

describe('FileCard', () => {
  test('is an outline card of one 40px row, 290px wide, that shrinks with its column', () => {
    const html = renderToStaticMarkup(
      <FileCard mark={<FileTypeMark fileName="a.pdf" />} name="a.pdf" description="PDF · 2 KB" />
    )
    const card = tagWith(html, 'data-slot="file-card"')
    expect(classesOf(card)).toEqual(
      expect.arrayContaining(['surface-outline', 'h-10', 'w-72.5', 'max-w-full', 'min-w-0', 'py-0'])
    )
    // The name speaks in the family's title step and the type line in its meta step.
    expect(classesOf(tagWith(html, 'data-slot="file-card-name"'))).toEqual(
      expect.arrayContaining(['text-75', 'font-medium', 'text-foreground'])
    )
    expect(classesOf(tagWith(html, 'data-slot="file-card-description"'))).toEqual(
      expect.arrayContaining(['text-50', 'text-fg-tertiary'])
    )
  })

  test('puts the mark and the text inside one open control with the caller’s name, and keeps actions beside it', () => {
    const html = renderToStaticMarkup(
      <FileCard
        mark={<FileTypeMark fileName="report.pdf" />}
        name="report.pdf"
        description="PDF · 31 KB"
        openLabel="Preview report.pdf"
        openTitle="report.pdf"
        onOpen={() => {}}
        action={<button type="button">Save report.pdf</button>}
      />
    )
    const open = /<button type="button" data-slot="file-card-open"[^>]*>[\s\S]*?<\/button>/.exec(html)?.[0] ?? ''
    expect(attributeOf(open, 'aria-label')).toBe('Preview report.pdf')
    expect(attributeOf(open, 'title')).toBe('report.pdf')
    expect(open).toContain('data-slot="file-type-mark"')
    expect(open).toContain('>report.pdf</span>')
    expect(open).toContain('PDF · 31 KB')
    expect(open).not.toContain('Save report.pdf')
    // The open control's hover wash and hit area stretch over the card beneath its end controls.
    expect(classesOf(tagWith(html, 'data-slot="file-card-open"'))).toEqual(
      expect.arrayContaining(['after:absolute', 'after:inset-0', 'after:-z-10', 'hover:after:bg-layer-hover'])
    )
    expect(html).toMatch(/data-slot="file-card-action"[^>]*><button type="button">Save report\.pdf<\/button>/)
  })

  test('renders static text without an open handler and draws an upload bar only while one runs', () => {
    const still = renderToStaticMarkup(<FileCard mark={null} name="a.txt" />)
    expect(still).not.toContain('<button')
    expect(still).not.toContain('scale:')

    const uploading = renderToStaticMarkup(<FileCard mark={null} name="a.txt" progress={0.42} />)
    expect(uploading).toContain('scale:0.42 1')
    expect(uploading).toContain('bg-info')

    const failed = renderToStaticMarkup(
      <FileCard mark={null} name="a.txt" description="Upload failed" progress={0.42} invalid />
    )
    expect(attributeOf(tagWith(failed, 'data-slot="file-card"'), 'data-invalid')).toBe('true')
    expect(classesOf(tagWith(failed, 'data-slot="file-card-description"'))).toContain('text-destructive-foreground')
    expect(failed).toContain('bg-destructive')
  })
})

describe('FileCardList', () => {
  test('wraps items 8px apart, and an item shrinks with a column narrower than itself', () => {
    const list = tagWith(renderToStaticMarkup(<FileCardList />), 'data-slot="file-card-list"')
    expect(classesOf(list)).toEqual(expect.arrayContaining(['flex', 'flex-wrap', 'gap-2', '*:min-w-0', '*:max-w-full']))
  })
})
