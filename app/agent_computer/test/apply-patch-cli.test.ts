import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runApplyPatch } from '../src/tools/computer/apply-patch-cli'

const originalCwd = process.cwd()
let workspace: string

beforeEach(() => {
  workspace = mkdtempSync(join(tmpdir(), 'ankole-apply-patch-'))
  process.chdir(workspace)
})

afterEach(() => {
  process.chdir(originalCwd)
  rmSync(workspace, { force: true, recursive: true })
})

function envelope(...body: string[]): string {
  return ['*** Begin Patch', ...body, '*** End Patch', ''].join('\n')
}

describe('apply_patch CLI', () => {
  it('adds, updates, and deletes files from one envelope', () => {
    writeFileSync(join(workspace, 'report.md'), '# Title\n\nold line\n')
    writeFileSync(join(workspace, 'stale.md'), 'drop me\n')

    const result = runApplyPatch(
      [
        envelope(
          '*** Add File: notes/new.md',
          '+first',
          '+second',
          '*** Update File: report.md',
          '@@',
          '-old line',
          '+new line',
          '*** Delete File: stale.md'
        )
      ],
      () => ''
    )

    expect(result.ok).toBe(true)
    expect(result.text).toContain('Success. Updated the following files:')
    expect(readFileSync(join(workspace, 'report.md'), 'utf8')).toBe('# Title\n\nnew line\n')
    expect(readFileSync(join(workspace, 'notes/new.md'), 'utf8')).toBe('first\nsecond\n')
    expect(existsSync(join(workspace, 'stale.md'))).toBe(false)
  })

  it('renames and edits in one Update through *** Move to:', () => {
    writeFileSync(join(workspace, 'draft.md'), 'title\nbody\n')

    const result = runApplyPatch(
      [envelope('*** Update File: draft.md', '*** Move to: final/report.md', '@@', '-body', '+final body')],
      () => ''
    )

    expect(result.ok).toBe(true)
    expect(existsSync(join(workspace, 'draft.md'))).toBe(false)
    expect(readFileSync(join(workspace, 'final/report.md'), 'utf8')).toBe('title\nfinal body\n')
  })

  it('renames without changes when the Update carries no hunk', () => {
    writeFileSync(join(workspace, 'draft.md'), 'kept\n')

    const result = runApplyPatch([envelope('*** Update File: draft.md', '*** Move to: kept.md')], () => '')

    expect(result.ok).toBe(true)
    expect(existsSync(join(workspace, 'draft.md'))).toBe(false)
    expect(readFileSync(join(workspace, 'kept.md'), 'utf8')).toBe('kept\n')
  })

  it('reads the envelope from standard input when no argument is given', () => {
    writeFileSync(join(workspace, 'a.txt'), 'alpha\n')

    const result = runApplyPatch([], () => envelope('*** Update File: a.txt', '@@', '-alpha', '+beta'))

    expect(result.ok).toBe(true)
    expect(readFileSync(join(workspace, 'a.txt'), 'utf8')).toBe('beta\n')
  })

  it('preserves CRLF line endings', () => {
    writeFileSync(join(workspace, 'crlf.txt'), 'one\r\ntwo\r\n')

    const result = runApplyPatch([envelope('*** Update File: crlf.txt', '@@', '-two', '+three')], () => '')

    expect(result.ok).toBe(true)
    expect(readFileSync(join(workspace, 'crlf.txt'), 'utf8')).toBe('one\r\nthree\r\n')
  })

  it('writes nothing when one hunk fails to match', () => {
    writeFileSync(join(workspace, 'kept.txt'), 'kept\n')

    const result = runApplyPatch(
      [
        envelope(
          '*** Update File: kept.txt',
          '@@',
          '-kept',
          '+changed',
          '*** Update File: kept.txt',
          '@@',
          '-absent line',
          '+ignored'
        )
      ],
      () => ''
    )

    expect(result.ok).toBe(false)
    expect(result.text).toContain('patch hunk did not match')
    expect(readFileSync(join(workspace, 'kept.txt'), 'utf8')).toBe('kept\n')
  })

  it('reports a missing target instead of creating it', () => {
    const result = runApplyPatch([envelope('*** Update File: missing.txt', '@@', '-x', '+y')], () => '')

    expect(result.ok).toBe(false)
    expect(result.text).toContain('file not found: missing.txt')
  })
})
