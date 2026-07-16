import { describe, expect, test } from 'bun:test'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AGENT_DESIGN_DOCUMENT_PATH, materializeAgentLibraryDocuments } from '../src/core/turns/agent_library_documents'

describe('agent library document projection', () => {
  test('atomically projects DESIGN.md at the stable read-only model path', () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-library-'))

    try {
      materializeAgentLibraryDocuments(workspaceRoot, context('Use cobalt accents.'))

      const designPath = join(workspaceRoot, '.ankole/agent-library/DESIGN.md')
      expect(AGENT_DESIGN_DOCUMENT_PATH).toBe('/workspace/.ankole/agent-library/DESIGN.md')
      expect(readFileSync(designPath, 'utf8')).toBe('Use cobalt accents.')
      expect(statSync(designPath).mode & 0o222).toBe(0)

      materializeAgentLibraryDocuments(workspaceRoot, context('Use magenta accents.'))
      expect(readFileSync(designPath, 'utf8')).toBe('Use magenta accents.')
    } finally {
      rmSync(workspaceRoot, { recursive: true, force: true })
    }
  })

  test('removes a stale projection when the runtime context has no DESIGN document', () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-library-'))
    const designPath = join(workspaceRoot, '.ankole/agent-library/DESIGN.md')

    try {
      mkdirSync(join(workspaceRoot, '.ankole/agent-library'), { recursive: true })
      materializeAgentLibraryDocuments(workspaceRoot, context('Use cobalt accents.'))
      expect(existsSync(designPath)).toBeTrue()

      materializeAgentLibraryDocuments(workspaceRoot, { ...context(''), design: undefined })
      expect(existsSync(designPath)).toBeFalse()
    } finally {
      rmSync(workspaceRoot, { recursive: true, force: true })
    }
  })

  test('reclaims a symbolic-link projection root without writing through it', () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-library-'))
    const outsideRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-library-outside-'))
    const projectionRoot = join(workspaceRoot, '.ankole/agent-library')

    try {
      mkdirSync(join(workspaceRoot, '.ankole'), { recursive: true })
      symlinkSync(outsideRoot, projectionRoot, 'dir')

      materializeAgentLibraryDocuments(workspaceRoot, context('Use cobalt accents.'))

      expect(lstatSync(projectionRoot).isSymbolicLink()).toBeFalse()
      expect(readFileSync(join(projectionRoot, 'DESIGN.md'), 'utf8')).toBe('Use cobalt accents.')
      expect(existsSync(join(outsideRoot, 'DESIGN.md'))).toBeFalse()
    } finally {
      rmSync(workspaceRoot, { recursive: true, force: true })
      rmSync(outsideRoot, { recursive: true, force: true })
    }
  })
})

function context(design: string) {
  return {
    request_id: 'context-1',
    agent_uid: 'agent-1',
    session_id: 'session-1',
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000101',
      revision: 0
    },
    design
  }
}
