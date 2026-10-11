import { describe, expect, test } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { agentHomePaths } from '../src/core/agent-home-paths'
import { materializeAgentLibraryDocuments } from '../src/core/codex-runner/job/agent-library-documents'
import { AgentConversationContextResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('Agent Home document projection', () => {
  test('atomically projects all uppercase read-only documents and returns the received snapshot', () => {
    const agentHomeRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-documents-'))
    const paths = agentHomePaths(agentHomeRoot)
    mkdirSync(paths.home, { recursive: true })

    try {
      const projected = materializeAgentLibraryDocuments(
        paths,
        create(AgentConversationContextResponseSchema, {
          soul: 'SOUL',
          mission: 'MISSION',
          design: 'DESIGN',
          confidentialityPolicy: 'POLICY'
        })
      )

      expect(readFileSync(paths.soul, 'utf8')).toBe('SOUL')
      expect(readFileSync(paths.mission, 'utf8')).toBe('MISSION')
      expect(readFileSync(paths.design, 'utf8')).toBe('DESIGN')
      expect(readFileSync(paths.confidentialityPolicy, 'utf8')).toBe('POLICY')
      expect(statSync(paths.design).mode & 0o222).toBe(0)
      expect(statSync(paths.confidentialityPolicy).mode & 0o222).toBe(0)
      expect(projected.soul).toBe('SOUL')
      expect(projected.mission).toBe('MISSION')
      expect(projected.design).toBe('DESIGN')
      expect(projected.confidentialityPolicy).toBe('POLICY')
    } finally {
      rmSync(agentHomeRoot, { recursive: true, force: true })
    }
  })
})
