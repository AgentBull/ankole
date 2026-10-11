import { describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { writeFileAtomic, writeFileAtomicSync } from '../src/common/atomic-write'

for (const [name, write] of [
  ['sync', async (path: string, content: string, mode: number) => writeFileAtomicSync(path, content, mode)],
  ['async', writeFileAtomic]
] as const) {
  describe(`${name} atomic write`, () => {
    for (const mode of [0o600, 0o444]) {
      test(`replaces the complete file with mode ${mode.toString(8)}`, async () => {
        const root = mkdtempSync(join(tmpdir(), 'ankole-atomic-'))
        try {
          const path = join(root, 'document')
          writeFileSync(path, 'old', { mode: 0o600 })
          await write(path, 'complete new content', mode)
          expect(readFileSync(path, 'utf8')).toBe('complete new content')
          expect(statSync(path).mode & 0o777).toBe(mode)
          expect(readdirSync(root)).toEqual(['document'])
        } finally {
          rmSync(root, { recursive: true, force: true })
        }
      })
    }

    test('removes its temporary file when rename fails', async () => {
      const root = mkdtempSync(join(tmpdir(), 'ankole-atomic-'))
      try {
        const path = join(root, 'directory')
        mkdirSync(path)
        writeFileSync(join(path, 'retained'), 'old content')
        await expect(write(path, 'new content', 0o600)).rejects.toThrow()
        expect(readFileSync(join(path, 'retained'), 'utf8')).toBe('old content')
        expect(readdirSync(root)).toEqual(['directory'])
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    })
  })
}
