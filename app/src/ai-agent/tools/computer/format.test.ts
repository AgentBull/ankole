import { describe, expect, it } from 'bun:test'
import { stripAnsi, truncateOutput } from './format'

describe('stripAnsi', () => {
  // Each input line is a different ANSI family (SGR color, erase-line, OSC title, OSC
  // hyperlink, cursor show/hide, DCS). Pins that every family is stripped while the
  // surrounding visible text (and a bare \r) survives.
  it('removes common terminal escape sequences', () => {
    const input = [
      '\u001B[31mERROR\u001B[0m',
      '\u001B[2K\rDownloading...',
      '\u001B]0;window title\u0007',
      '\u001B]8;;https://example.com\u001B\\link\u001B]8;;\u001B\\',
      '\u001B[?25lhidden cursor\u001B[?25h',
      '\u001BPignored-dcs\u001B\\'
    ].join('\n')

    expect(stripAnsi(input)).toBe(['ERROR', '\rDownloading...', '', 'link', 'hidden cursor', ''].join('\n'))
  })

  // Pins the ordering: ANSI is stripped BEFORE the length budget is applied, so the
  // truncation limit is spent on real text and no escape bytes survive into the output.
  it('cleans output before applying truncation', () => {
    const input = `ok \u001B[31m${'x'.repeat(20)}\u001B[0m tail`
    const output = truncateOutput(input, 12)

    expect(output).not.toContain('\u001B')
    expect(output).toContain('output truncated')
  })
})
