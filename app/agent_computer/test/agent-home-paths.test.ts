import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
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
      agents_root: string
      valid: Array<{
        agent_uid: string
        workspace_id: number
        job_id: number
        home: string
        codex_home: string
        session_workspace: string
        job_workspace: string
      }>
      invalid_agent_uids: string[]
      invalid_workspace_ids: Array<string | number>
      invalid_job_ids: Array<string | number>
    }

    for (const vector of vectors.valid) {
      const paths = agentHomePaths(vectors.agents_root, vector.agent_uid)
      expect(paths.home).toBe(vector.home)
      expect(paths.codexHome).toBe(vector.codex_home)
      expect(sessionWorkspacePath(vectors.agents_root, vector.agent_uid, vector.workspace_id)).toBe(
        vector.session_workspace
      )
      expect(jobWorkspacePath(vectors.agents_root, vector.agent_uid, String(vector.job_id))).toBe(vector.job_workspace)
    }

    for (const agentUID of vectors.invalid_agent_uids) {
      expect(() => agentHomePaths(vectors.agents_root, agentUID)).toThrow('Agent UID must match')
    }
    for (const workspaceID of vectors.invalid_workspace_ids) {
      expect(() => sessionWorkspacePath(vectors.agents_root, 'agent-1', workspaceID as number)).toThrow(
        'Session workspace ID'
      )
    }
    for (const jobID of vectors.invalid_job_ids) {
      expect(() => jobWorkspacePath(vectors.agents_root, 'agent-1', String(jobID))).toThrow('background Agent Job id')
    }
  })

  it('constructs direct real paths with uppercase document names', () => {
    const paths = agentHomePaths('/agents', 'agent-1')
    expect(paths.home).toBe('/agents/agent-1')
    expect(paths.codexHome).toBe('/agents/agent-1/.codex')
    expect(paths.soul).toBe('/agents/agent-1/SOUL.md')
    expect(paths.mission).toBe('/agents/agent-1/MISSION.md')
    expect(paths.design).toBe('/agents/agent-1/DESIGN.md')
    expect(jobWorkspacePath('/agents', 'agent-1', '1000')).toBe('/agents/agent-1/jobs/1000')
  })

  it('uses the PostgreSQL-owned numeric Session workspace ID', () => {
    expect(sessionWorkspacePath('/agents', 'agent-1', 10_000)).toBe('/agents/agent-1/sessions/10000')
  })

  it('rejects unsafe Agent UIDs, traversal, and absolute paths outside Agent Home', () => {
    expect(() => agentHomePaths('/agents', 'Agent 1')).toThrow('Agent UID must match')
    expect(() => jobWorkspacePath('/agents', 'agent-1', '../job')).toThrow('background Agent Job id')
    expect(() => resolveAgentHomePath('/agents/agent-1', '../outside')).toThrow('escapes Agent Home')
    expect(() => resolveAgentHomePath('/agents/agent-1', '/agents/agent-2/file')).toThrow('escapes Agent Home')
    expect(insideAgentHome('/agents/agent-1', '/agents/agent-1/user-files/a')).toBeTrue()
  })

  it('resolves relative paths from the real current workspace', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-home-'))
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
})
