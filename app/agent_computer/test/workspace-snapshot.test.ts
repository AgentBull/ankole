import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { changedWorkspacePaths, snapshotWorkspace } from '../src/core/codex-runner/job/workspace-snapshot'

function workspace(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-snapshot-'))
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, '..'), { recursive: true })
    writeFileSync(join(root, path), content)
  }
  return root
}

describe('@ankole/agent-computer Job Workspace snapshot', () => {
  it('lists added, changed, and removed deliverables and skips runtime and dependency trees at any depth', async () => {
    const root = workspace({
      'report.md': 'draft',
      'data/raw.csv': 'a',
      'AGENTS.md': 'context',
      'temp/scratch.txt': 'x',
      '.codex/config.toml': '',
      'tools/node_modules/pkg/index.js': '',
      'src/target/debug/bin': '',
      'py/__pycache__/m.pyc': ''
    })
    try {
      const before = await snapshotWorkspace(root)
      if ('skipped' in before) throw new Error(before.skipped)
      expect([...before.files.keys()].sort()).toEqual(['data/raw.csv', 'report.md'])

      writeFileSync(join(root, 'report.md'), 'final report')
      mkdirSync(join(root, 'out'))
      writeFileSync(join(root, 'out/summary.json'), '{}')
      rmSync(join(root, 'data/raw.csv'))
      writeFileSync(join(root, 'temp/other.txt'), 'y')
      const after = await snapshotWorkspace(root)
      if ('skipped' in after) throw new Error(after.skipped)

      expect(changedWorkspacePaths(before.files, after.files)).toEqual([
        'data/raw.csv',
        'out/summary.json',
        'report.md'
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('does not report a file whose size and modification time are unchanged', async () => {
    const root = workspace({ 'notes.txt': 'same' })
    try {
      const before = await snapshotWorkspace(root)
      if ('skipped' in before) throw new Error(before.skipped)
      const epoch = new Date(1_700_000_000_000)
      utimesSync(join(root, 'notes.txt'), epoch, epoch)
      const touched = await snapshotWorkspace(root)
      if ('skipped' in touched) throw new Error(touched.skipped)
      expect(changedWorkspacePaths(before.files, touched.files)).toEqual(['notes.txt'])
      const same = await snapshotWorkspace(root)
      if ('skipped' in same) throw new Error(same.skipped)
      expect(changedWorkspacePaths(touched.files, same.files)).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skips a workspace above the entry bound or the time budget', async () => {
    const root = workspace({ 'a.txt': '1', 'b.txt': '2', 'c.txt': '3' })
    try {
      expect(await snapshotWorkspace(root, { maxEntries: 2 })).toEqual({ skipped: 'too_many_files' })
      expect(await snapshotWorkspace(root, { timeBudgetMs: -1 })).toEqual({ skipped: 'time_limit' })
      const within = await snapshotWorkspace(root, { maxEntries: 3 })
      if ('skipped' in within) throw new Error(within.skipped)
      expect(within.files.size).toBe(3)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
