import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { codexJobProjectLocation, prepareCodexJobProject } from '../src/core/codex-runner/job/job-project'

describe('@ankole/agent-computer Codex Job workspace', () => {
  it('uses one stable real path as host path, cwd, and model-visible path', () => {
    const agentHomeRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-job-'))
    try {
      const location = codexJobProjectLocation(agentHomeRoot, '1000')
      const project = prepareCodexJobProject({ jobProjectRoot: location.hostPath })
      expect(project.root).toBe(join(agentHomeRoot, 'jobs', '1000'))
      expect(existsSync(join(project.root, 'temp'))).toBeTrue()
      expect(location.agentHome).toBe(agentHomeRoot)
    } finally {
      rmSync(agentHomeRoot, { recursive: true, force: true })
    }
  })

  it('rejects unsafe IDs, Git workspaces, and symbolic-link workspace roots', () => {
    const agentHomeRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-job-boundary-'))
    const gitRoot = join(agentHomeRoot, 'git-job')
    mkdirSync(join(gitRoot, '.git'), { recursive: true })
    try {
      expect(() => codexJobProjectLocation(agentHomeRoot, '../escape')).toThrow('canonical decimal integer')
      expect(() => prepareCodexJobProject({ jobProjectRoot: gitRoot })).toThrow('must remain non-Git')
    } finally {
      rmSync(agentHomeRoot, { recursive: true, force: true })
    }
  })
})
