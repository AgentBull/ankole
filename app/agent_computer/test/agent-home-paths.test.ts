import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  agentHomePaths,
  jobWorkspacePath,
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

  it('retains the shared safe segment helper for non-identity filenames', () => {
    expect(sanitizePathSegment(' report id! ')).toBe('report-id')
    expect(sanitizePathSegment('unsafe/id', { replacement: '_' })).toBe('unsafe_id')
  })
})
