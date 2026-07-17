import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { codexJobProjectLocation, prepareCodexJobProject } from '../src/core/codex-runner/job-project'

describe('@ankole/agent-computer Codex job project', () => {
  it('keeps Codex in a private project and orders stable read-only/read-write mounts', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-project-'))
    const jobProjectRoot = join(root, 'job-session', 'project')
    const ownerWorkspaceRoot = join(root, 'owner-workspace')
    mkdirSync(join(ownerWorkspaceRoot, 'source'), { recursive: true })

    try {
      const project = prepareCodexJobProject({
        jobProjectRoot,
        ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
        ownerWorkspaceRoot,
        workspaceMounts: [
          { id: 'output', source: '/workspace/output', access: 'read_write' },
          { id: 'source', source: '/workspace/source', access: 'read_only' }
        ]
      })

      expect(project).toEqual({
        root: jobProjectRoot,
        ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
        codexCwd: '/workspace',
        workspaceMounts: [
          {
            id: 'output',
            sourcePath: realpathSync(join(ownerWorkspaceRoot, 'output')),
            projectPath: join(jobProjectRoot, 'workspaces', 'output'),
            modelPath: '/workspace/workspaces/output',
            ownerModelPath: '/workspace/output',
            access: 'read_write'
          },
          {
            id: 'source',
            sourcePath: realpathSync(join(ownerWorkspaceRoot, 'source')),
            projectPath: join(jobProjectRoot, 'workspaces', 'source'),
            modelPath: '/workspace/workspaces/source',
            ownerModelPath: '/workspace/source',
            access: 'read_only'
          }
        ]
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects Git roots, unsafe or duplicate mounts, escaping paths, and missing read-only sources', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-project-boundary-'))
    const ownerWorkspaceRoot = join(root, 'owner-workspace')
    const gitProjectRoot = join(root, 'git-project')
    mkdirSync(ownerWorkspaceRoot, { recursive: true })
    mkdirSync(join(gitProjectRoot, '.git'), { recursive: true })

    try {
      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: gitProjectRoot,
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: []
        })
      ).toThrow('Background agent job project root must remain non-Git')

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(root, 'job-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [{ id: '../escape', source: '/workspace/output', access: 'read_write' }]
        })
      ).toThrow('workspace mount id is not a safe path segment')

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(root, 'job-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [
            { id: 'source', source: '/workspace/source', access: 'read_write' },
            { id: 'source', source: '/workspace/other', access: 'read_write' }
          ]
        })
      ).toThrow('workspace mount id is duplicated')

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(root, 'job-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [{ id: 'outside', source: '/tmp/outside', access: 'read_write' }]
        })
      ).toThrow('workspace mount outside must stay inside the owner workspace')

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(root, 'job-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [{ id: 'missing', source: '/workspace/missing', access: 'read_only' }]
        })
      ).toThrow('read-only workspace mount does not exist')

      const outsideRoot = join(root, 'outside')
      mkdirSync(outsideRoot, { recursive: true })
      symlinkSync(outsideRoot, join(ownerWorkspaceRoot, 'escaped-link'))
      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(root, 'symlink-source-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [{ id: 'escaped', source: '/workspace/escaped-link', access: 'read_only' }]
        })
      ).toThrow('workspace mount escaped resolves outside the owner workspace')

      const poisonedProject = join(root, 'poisoned-project')
      const poisonedMountpoint = join(poisonedProject, 'workspaces', 'source')
      mkdirSync(join(poisonedProject, 'workspaces'), { recursive: true })
      symlinkSync(outsideRoot, poisonedMountpoint)
      mkdirSync(join(ownerWorkspaceRoot, 'source'), { recursive: true })
      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: poisonedProject,
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot,
          workspaceMounts: [{ id: 'source', source: '/workspace/source', access: 'read_only' }]
        })
      ).toThrow('workspace mountpoint source must be a real directory')

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: join(ownerWorkspaceRoot, 'private-project'),
          ownerModelPath: '/workspace/user-files/background-agent-jobs/job-1/project',
          ownerWorkspaceRoot: join(ownerWorkspaceRoot, 'private-project'),
          workspaceMounts: [{ id: 'self', source: '/workspace', access: 'read_write' }]
        })
      ).toThrow('workspace mount must not overlap its private project root')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('uses a cross-worker stable owner-visible project path and permits the controlled user-files symlink', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-owner-visible-'))
    const userFilesRoot = join(root, 'shared', 'user-files')
    const ownerWorkspaceRoot = join(root, 'sessions', 'agent', 'main')
    mkdirSync(userFilesRoot, { recursive: true })
    mkdirSync(ownerWorkspaceRoot, { recursive: true })
    symlinkSync(userFilesRoot, join(ownerWorkspaceRoot, 'user-files'))
    mkdirSync(join(userFilesRoot, 'source'), { recursive: true })
    const firstLocation = codexJobProjectLocation(userFilesRoot, '019f0000-0000-7000-8000-000000000001')
    const resumedLocation = codexJobProjectLocation(userFilesRoot, '019f0000-0000-7000-8000-000000000001')

    try {
      expect(resumedLocation).toEqual(firstLocation)
      const project = prepareCodexJobProject({
        jobProjectRoot: firstLocation.hostPath,
        ownerModelPath: firstLocation.ownerModelPath,
        ownerWorkspaceRoot,
        allowedSourceRoots: [userFilesRoot],
        workspaceMounts: [{ id: 'source', source: '/workspace/user-files/source', access: 'read_only' }]
      })
      writeFileSync(join(project.root, 'artifact.txt'), 'owner-visible')
      expect(
        readFileSync(
          join(
            userFilesRoot,
            'background-agent-jobs',
            '019f0000-0000-7000-8000-000000000001',
            'project',
            'artifact.txt'
          ),
          'utf8'
        )
      ).toBe('owner-visible')
      expect(project.ownerModelPath).toBe(
        '/workspace/user-files/background-agent-jobs/019f0000-0000-7000-8000-000000000001/project'
      )
      expect(project.workspaceMounts[0]?.sourcePath).toBe(realpathSync(join(userFilesRoot, 'source')))

      expect(() =>
        prepareCodexJobProject({
          jobProjectRoot: firstLocation.hostPath,
          ownerModelPath: firstLocation.ownerModelPath,
          ownerWorkspaceRoot,
          allowedSourceRoots: [userFilesRoot],
          workspaceMounts: [{ id: 'too-broad', source: '/workspace/user-files', access: 'read_write' }]
        })
      ).toThrow('workspace mount must not overlap its private project root')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
