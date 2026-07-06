import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  insideWorkspace,
  isWorkspacePath,
  resolveWorkspacePath,
  sanitizePathSegment,
  toWorkspacePath
} from '../src/core/workspace-paths'

describe('workspace path projection', () => {
  it('maps model-facing /workspace paths into the real workspace root', () => {
    withWorkspace(root => {
      expect(resolveWorkspacePath(root, '/workspace')).toBe(root)
      expect(resolveWorkspacePath(root, '/workspace/user-files/report.txt')).toBe(join(root, 'user-files/report.txt'))
      expect(toWorkspacePath(root, join(root, 'user-files/report.txt'))).toBe('/workspace/user-files/report.txt')
    })
  })

  it('rejects traversal after preserving the /workspace virtual-root boundary', () => {
    withWorkspace(root => {
      expect(() => resolveWorkspacePath(root, '/workspace/../outside.txt')).toThrow('path escapes workspace root')
      expect(() => resolveWorkspacePath(root, '../outside.txt')).toThrow('path escapes workspace root')
    })
  })

  it('makes non-workspace absolute path handling explicit per caller', () => {
    withWorkspace(root => {
      expect(resolveWorkspacePath(root, '/tmp/file.txt')).toBe(join(root, 'tmp/file.txt'))
      expect(() =>
        resolveWorkspacePath(root, '/tmp/file.txt', {
          nonWorkspaceAbsolute: 'reject',
          errorMessage: 'workdir must stay inside workspace'
        })
      ).toThrow('workdir must stay inside workspace')
    })
  })

  it('resolves relative paths from a model-facing cwd inside the workspace', () => {
    withWorkspace(root => {
      expect(resolveWorkspacePath(root, 'child.txt', { cwd: '/workspace/projects/demo' })).toBe(
        join(root, 'projects/demo/child.txt')
      )
    })
  })

  it('recognizes only the exact model workspace root and its descendants', () => {
    expect(isWorkspacePath('/workspace')).toBe(true)
    expect(isWorkspacePath('/workspace/file.txt')).toBe(true)
    expect(isWorkspacePath('/workspace-other/file.txt')).toBe(false)
  })

  it('checks real paths against the real workspace root', () => {
    withWorkspace(root => {
      expect(insideWorkspace(root, join(root, 'nested/file.txt'))).toBe(true)
      expect(insideWorkspace(root, join(root, '../outside.txt'))).toBe(false)
    })
  })

  it('sanitizes path segments with one fallback-aware signature', () => {
    expect(sanitizePathSegment(' report id! ')).toBe('report-id')
    expect(sanitizePathSegment('!!!', { fallback: 'browser-task' })).toBe('browser-task')
    expect(sanitizePathSegment('unsafe/id', { replacement: '_', fallback: 'delegation' })).toBe('unsafe_id')
  })
})

function withWorkspace(run: (root: string) => void): void {
  const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-paths-'))
  try {
    run(root)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}
