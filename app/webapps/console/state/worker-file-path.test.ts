import { describe, expect, test } from 'bun:test'
import { agentUIDFromWorkerFilePath, workerFileRootPath } from './worker-file-path'

describe('worker file paths', () => {
  test('builds each Agent-scoped root path', () => {
    expect(workerFileRootPath('agent_sessions', 'researcher')).toBe('researcher/sessions')
    expect(workerFileRootPath('user_files', 'researcher')).toBe('researcher/user-files')
    expect(workerFileRootPath('agent_installed_skills', 'researcher')).toBe('researcher/installed-skills')
  })

  test('extracts the Agent only from a path in the selected root', () => {
    expect(agentUIDFromWorkerFilePath('agent_sessions', 'researcher/sessions/thread-1')).toBe('researcher')
    expect(agentUIDFromWorkerFilePath('agent_sessions', '')).toBeUndefined()
    expect(agentUIDFromWorkerFilePath('agent_sessions', 'researcher/user-files')).toBeUndefined()
    expect(agentUIDFromWorkerFilePath('agent_sessions', '../sessions')).toBeUndefined()
  })
})
