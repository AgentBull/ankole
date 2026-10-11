import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  agentHomePaths,
  insideAgentHome,
  jobWorkspacePath,
  resolveAgentHomePath,
  sanitizePathSegment,
  sessionWorkspacePath
} from '../src/core/agent-home-paths'

describe('Agent Home paths', () => {
  it('matches the shared Elixir and TypeScript path vectors', () => {
    const vectors = JSON.parse(
      readFileSync(
        join(import.meta.dir, '../../kernel/proto/ankole/runtime_fabric/v1/agent_home_path_vectors.json'),
        'utf8'
      )
    ) as {
      agent_home: string
      valid: Array<{
        workspace_id: number
        job_id: number
        home: string
        session_workspace: string
        job_workspace: string
      }>
      invalid_workspace_ids: Array<string | number>
      invalid_job_ids: Array<string | number>
    }

    for (const vector of vectors.valid) {
      const paths = agentHomePaths(vectors.agent_home)
      expect(paths.home).toBe(vector.home)
      expect(sessionWorkspacePath(vectors.agent_home, vector.workspace_id)).toBe(vector.session_workspace)
      expect(jobWorkspacePath(vectors.agent_home, String(vector.job_id))).toBe(vector.job_workspace)
    }

    for (const workspaceID of vectors.invalid_workspace_ids) {
      expect(() => sessionWorkspacePath(vectors.agent_home, workspaceID as number)).toThrow('Session workspace ID')
    }
    for (const jobID of vectors.invalid_job_ids) {
      expect(() => jobWorkspacePath(vectors.agent_home, String(jobID))).toThrow('background Agent Job id')
    }
  })

  it('constructs direct real paths with uppercase document names', () => {
    const paths = agentHomePaths('/workspace')
    expect(paths.home).toBe('/workspace')
    expect(paths.codexHome).toBe('/workspace/.codex')
    expect(paths.soul).toBe('/workspace/SOUL.md')
    expect(paths.mission).toBe('/workspace/MISSION.md')
    expect(paths.design).toBe('/workspace/DESIGN.md')
    expect(jobWorkspacePath('/workspace', '1000')).toBe('/workspace/jobs/1000')
  })

  it('uses the PostgreSQL-owned numeric Session workspace ID', () => {
    expect(sessionWorkspacePath('/workspace', 10_000)).toBe('/workspace/sessions/10000')
  })

  it('rejects traversal and absolute paths outside Agent Home', () => {
    expect(() => jobWorkspacePath('/workspace', '../job')).toThrow('background Agent Job id')
    expect(() => resolveAgentHomePath('/agents/agent-1', '../outside')).toThrow('escapes Agent Home')
    expect(() => resolveAgentHomePath('/agents/agent-1', '/agents/agent-2/file')).toThrow('escapes Agent Home')
    expect(insideAgentHome('/agents/agent-1', '/agents/agent-1/user-files/a')).toBeTrue()
  })

  it('resolves relative paths from the real current workspace', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'ankole-agent-home-')))
    try {
      const cwd = join(root, 'sessions', 'session-1')
      expect(resolveAgentHomePath(root, 'child.txt', { cwd })).toBe(join(cwd, 'child.txt'))
      expect(resolveAgentHomePath(root, '~/user-files/report.txt', { cwd })).toBe(join(root, 'user-files/report.txt'))
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('retains the shared safe segment helper for non-identity filenames', () => {
    expect(sanitizePathSegment(' report id! ')).toBe('report-id')
    expect(sanitizePathSegment('unsafe/id', { replacement: '_' })).toBe('unsafe_id')
  })

  it('accepts the former Home symlink and rejects links outside the Home', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'ankole-home-links-')))
    const home = join(root, 'workspace')
    const legacy = join(root, 'agents', 'agent-1')
    mkdirSync(home)
    mkdirSync(join(root, 'agents'))
    writeFileSync(join(home, 'existing.txt'), 'kept')
    symlinkSync(home, legacy)
    symlinkSync('/etc', join(home, 'outside'))
    symlinkSync(join(root, 'missing'), join(home, 'dangling'))
    try {
      expect(resolveAgentHomePath(home, join(legacy, 'existing.txt'))).toBe(join(home, 'existing.txt'))
      expect(resolveAgentHomePath(home, join(legacy, 'new', 'file.txt'))).toBe(join(home, 'new', 'file.txt'))
      expect(resolveAgentHomePath(home, 'child.txt', { cwd: legacy })).toBe(join(home, 'child.txt'))
      expect(() => resolveAgentHomePath(home, 'outside/passwd')).toThrow('escapes Agent Home')
      expect(() => resolveAgentHomePath(home, 'dangling/file')).toThrow()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
