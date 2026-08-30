import { describe, expect, test } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { xxh3String128Hex } from '@ankole/kernel'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { agentHomePaths } from '../src/core/agent-home-paths'
import { materializeAgentLibraryDocuments } from '../src/core/turns/agent_library_documents'
import { AgentConversationContextResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('Agent Home document projection', () => {
  test('atomically projects all uppercase read-only documents and reads them back', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-documents-'))
    const paths = agentHomePaths(agentsRoot, 'agent-1')
    mkdirSync(paths.home, { recursive: true })

    try {
      const projected = materializeAgentLibraryDocuments(
        paths,
        create(AgentConversationContextResponseSchema, {
          soul: 'SOUL',
          mission: 'MISSION',
          design: 'DESIGN',
          confidentialityPolicy: 'POLICY',
          soulContentHash: xxh3String128Hex('SOUL'),
          missionContentHash: xxh3String128Hex('MISSION'),
          designContentHash: xxh3String128Hex('DESIGN'),
          confidentialityPolicyContentHash: xxh3String128Hex('POLICY')
        })
      )

      expect(readFileSync(paths.soul, 'utf8')).toBe('SOUL')
      expect(readFileSync(paths.mission, 'utf8')).toBe('MISSION')
      expect(readFileSync(paths.design, 'utf8')).toBe('DESIGN')
      expect(readFileSync(paths.confidentialityPolicy, 'utf8')).toBe('POLICY')
      expect(statSync(paths.design).mode & 0o222).toBe(0)
      expect(statSync(paths.confidentialityPolicy).mode & 0o222).toBe(0)
      expect(projected.design).toBe('DESIGN')
      expect(projected.confidentialityPolicy).toBe('POLICY')
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  test('fails before model execution when a control-plane hash does not match', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-documents-'))
    const paths = agentHomePaths(agentsRoot, 'agent-1')
    mkdirSync(paths.home, { recursive: true })

    try {
      expect(() =>
        materializeAgentLibraryDocuments(
          paths,
          create(AgentConversationContextResponseSchema, {
            soul: 'SOUL',
            mission: 'MISSION',
            design: 'DESIGN',
            confidentialityPolicy: 'POLICY',
            soulContentHash: xxh3String128Hex('different'),
            missionContentHash: xxh3String128Hex('MISSION'),
            designContentHash: xxh3String128Hex('DESIGN'),
            confidentialityPolicyContentHash: xxh3String128Hex('POLICY')
          })
        )
      ).toThrow('SOUL.md projection content hash mismatch')
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})
