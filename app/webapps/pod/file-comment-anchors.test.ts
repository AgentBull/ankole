import { describe, expect, it } from 'bun:test'
import {
  clampCommentQuote,
  extractMarkdownSections,
  formatFileAnchorLabel,
  formatMediaTimestamp,
  parseDelimitedTable,
  parseFileCommentAnchor
} from './file-comment-anchors'

describe('file-comment-anchors', () => {
  it('parses all four valid multimodal anchor schemas and rejects malformed shapes', () => {
    expect(parseFileCommentAnchor({ kind: 'lines', start_line: 10, end_line: 18, object_id: 'obj-1' })).toEqual({
      kind: 'lines',
      start_line: 10,
      end_line: 18,
      object_id: 'obj-1'
    })
    expect(
      parseFileCommentAnchor({ kind: 'csv_rows', start_row: 2, end_row: 5, column: 'Amount', object_id: 'obj-2' })
    ).toEqual({
      kind: 'csv_rows',
      start_row: 2,
      end_row: 5,
      column: 'Amount',
      object_id: 'obj-2'
    })
    expect(
      parseFileCommentAnchor({
        kind: 'md_section',
        heading: 'Architecture',
        level: 2,
        start_line: 42,
        object_id: 'obj-3'
      })
    ).toEqual({
      kind: 'md_section',
      heading: 'Architecture',
      level: 2,
      start_line: 42,
      object_id: 'obj-3'
    })
    expect(
      parseFileCommentAnchor({
        kind: 'media_timestamp',
        time_sec: 84.25,
        end_time_sec: 96.5,
        object_id: 'obj-4'
      })
    ).toEqual({
      kind: 'media_timestamp',
      time_sec: 84.25,
      end_time_sec: 96.5,
      object_id: 'obj-4'
    })

    expect(parseFileCommentAnchor({ kind: 'lines', start_line: 20, end_line: 10 })).toBeNull()
    expect(parseFileCommentAnchor({ kind: 'lines', start_line: 0, end_line: 2 })).toBeNull()
    expect(parseFileCommentAnchor({ kind: 'md_section', heading: '   ', level: 2 })).toBeNull()
    expect(parseFileCommentAnchor({ kind: 'media_timestamp', time_sec: -1 })).toBeNull()
    expect(parseFileCommentAnchor({ kind: 'unknown' })).toBeNull()
  })

  it('formats human-readable labels for lines, CSV rows, Markdown sections, and media timestamps', () => {
    expect(formatFileAnchorLabel({ kind: 'lines', start_line: 7, end_line: 7 })).toBe('L7')
    expect(formatFileAnchorLabel({ kind: 'lines', start_line: 7, end_line: 14 })).toBe('L7–L14')
    expect(formatFileAnchorLabel({ kind: 'csv_rows', start_row: 3, end_row: 6, column: 'Revenue' })).toBe(
      'Rows 3–6 · Revenue'
    )
    expect(formatFileAnchorLabel({ kind: 'md_section', heading: 'Overview', level: 2 })).toBe('## Overview')
    expect(formatFileAnchorLabel({ kind: 'media_timestamp', time_sec: 84 })).toBe('01:24')
    expect(formatFileAnchorLabel({ kind: 'media_timestamp', time_sec: 3725, end_time_sec: 3730 })).toBe(
      '1:02:05–1:02:10'
    )
    expect(formatMediaTimestamp(5)).toBe('00:05')
  })

  it('extracts ATX Markdown sections while ignoring headings inside fenced code blocks', () => {
    const markdown = [
      '# Title',
      'Intro line',
      '```bash',
      '# shell comment not a heading',
      '```',
      '## Design',
      'Details here'
    ].join('\n')

    const sections = extractMarkdownSections(markdown)
    expect(sections.map(sec => ({ heading: sec.heading, level: sec.level, start_line: sec.start_line }))).toEqual([
      { heading: 'Title', level: 1, start_line: 1 },
      { heading: 'Design', level: 2, start_line: 6 }
    ])
  })

  it('uses CommonMark heading positions and never closes fences on trailing text', () => {
    const markdown = [
      '  ## Indented',
      'intro',
      '`````js',
      '`````not-a-close``',
      '## Still code',
      '`````',
      '### Real **heading** ###',
      'body',
      '',
      'Setext title',
      '------------'
    ].join('\n')

    expect(extractMarkdownSections(markdown)).toEqual([
      {
        heading: 'Indented',
        level: 2,
        start_line: 1,
        excerpt: markdown.split('\n').slice(0, 6).join('\n').trim()
      },
      { heading: 'Real **heading**', level: 3, start_line: 7, excerpt: '### Real **heading** ###\nbody' },
      { heading: 'Setext title', level: 2, start_line: 10, excerpt: 'Setext title\n------------' }
    ])
  })

  it('parses RFC-4180 CSV and TSV tables cleanly', () => {
    const csv = '\uFEFFName,Notes,Amount\r\n"Alice, Jr.","Line 1\nLine 2",120\r\nBob,"Quote ""ok""",80\r\n\r\n'
    const parsed = parseDelimitedTable(csv, ',')
    expect(parsed.headers).toEqual(['Name', 'Notes', 'Amount'])
    expect(parsed.rows).toEqual([
      ['Alice, Jr.', 'Line 1\nLine 2', '120'],
      ['Bob', 'Quote "ok"', '80']
    ])
  })

  it('clamps multi-byte comment quotes within 1000 code points and 4096 UTF-8 bytes', () => {
    const emojiFlood = '🚀'.repeat(1500)
    const clamped = clampCommentQuote(emojiFlood)
    expect(Array.from(clamped).length).toBeLessThanOrEqual(1000)
    expect(new TextEncoder().encode(clamped).byteLength).toBeLessThanOrEqual(4096)
  })
})
