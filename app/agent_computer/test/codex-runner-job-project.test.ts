import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { codexJobProjectLocation, prepareCodexJobProject } from '../src/core/codex-runner/job-project'

describe('@ankole/agent-computer Codex Job workspace', () => {
  it('uses one stable real path as host path, cwd, and model-visible path', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-job-'))
    try {
      const location = codexJobProjectLocation(agentsRoot, 'agent-1', '1000')
      const project = prepareCodexJobProject({ jobProjectRoot: location.hostPath })
      expect(project.root).toBe(join(agentsRoot, 'agent-1', 'jobs', '1000'))
      expect(project.codexCwd).toBe(project.root)
      expect(existsSync(join(project.root, 'temp'))).toBeTrue()
      expect(location.agentHome).toBe(join(agentsRoot, 'agent-1'))
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('rejects unsafe IDs, Git workspaces, and symbolic-link workspace roots', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-job-boundary-'))
    const gitRoot = join(agentsRoot, 'git-job')
    mkdirSync(join(gitRoot, '.git'), { recursive: true })
    try {
      expect(() => codexJobProjectLocation(agentsRoot, 'agent-1', '../escape')).toThrow('canonical decimal integer')
      expect(() => codexJobProjectLocation(agentsRoot, 'Agent 1', '1000')).toThrow('Agent UID must match')
      expect(() => prepareCodexJobProject({ jobProjectRoot: gitRoot })).toThrow('must remain non-Git')
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})
