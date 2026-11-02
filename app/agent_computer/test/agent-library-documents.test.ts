import { describe, expect, test } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { agentHomePaths } from '../src/core/agent-home-paths'
import { materializeAgentLibraryDocuments } from '../src/core/agent-library-documents'
import { AgentConversationContextResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('Agent contract projection', () => {
  test('refreshes whole contracts on every turn without changing project instructions', () => {
    const home = mkdtempSync(join(tmpdir(), 'ankole-agent-contracts-'))
    const paths = agentHomePaths(home)
    const project = join(home, 'jobs', '1000', 'project')
    mkdirSync(project, { recursive: true })
    writeFileSync(join(project, 'AGENTS.override.md'), 'Project contract')
    try {
      for (const version of ['one', 'two']) {
        const context = create(AgentConversationContextResponseSchema, {
          agents: `Company contract ${version}`,
          design: `Brand ${version}`
        })
        expect(materializeAgentLibraryDocuments(paths, context)).toBe(context)
        expect(readFileSync(paths.agents, 'utf8')).toBe(`Company contract ${version}`)
        expect(readFileSync(join(paths.codexHome, 'AGENTS.md'), 'utf8')).toBe(`Company contract ${version}`)
        expect(readFileSync(paths.design, 'utf8')).toBe(`Brand ${version}`)
        expect(statSync(paths.agents).mode & 0o222).toBe(0)
        expect(statSync(paths.design).mode & 0o222).toBe(0)
        expect(readFileSync(join(project, 'AGENTS.override.md'), 'utf8')).toBe('Project contract')
      }
    } finally {
      rmSync(home, { recursive: true, force: true })
    }
  })
})
