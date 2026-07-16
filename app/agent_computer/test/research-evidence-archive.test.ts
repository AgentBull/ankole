import { describe, expect, it } from 'bun:test'
import { genericHash } from '@ankole/kernel'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import type { AgentTool } from '../src/core/types'
import { createResearchEvidenceArchiveRuntime } from '../src/tools/subagent/research-evidence-archive'

describe('@ankole/agent-computer Deep Research evidence archive', () => {
  it('archives fetched source text before returning it to the researcher', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-research-source-archive-'))
    const workdir = join(root, 'research')
    const delegationID = '019f0000-0000-7000-8000-000000000101'
    const runtime = createResearchEvidenceArchiveRuntime({ delegationID, workdir, sharedFsRoot: root })
    const fetch = runtime.wrapTools([webFetchTool()], 'lead')[0]!

    try {
      const result = await fetch.execute('fetch-1', { urls: ['https://example.test/source'] })
      expect(runtime.records).toHaveLength(1)
      const record = runtime.records[0]!
      expect(record.archive_kind).toBe('web_fetch')
      expect(record.url).toBe('https://example.test/source')
      expect(record.scope).toBe('lead')
      expect(record.tool_call_id).toBe('fetch-1')
      expect(record.archive_path).toMatch(/^evidence\/sources\/web-/)

      const archived = readFileSync(join(workdir, record.archive_path))
      expect(archived.toString()).toContain('Authoritative source body.')
      expect(record.content_hash).toBe(genericHash(archived))
      expect(result.content.at(-1)).toMatchObject({ type: 'text' })
      expect((result.content.at(-1) as { text: string }).text).toContain(record.archive_path)
      expect(existsSync(join(root, '.ankole', 'research-evidence', delegationID, 'sources', 'index.json'))).toBe(true)

      const originalBytes = Buffer.from(archived)
      await fetch.execute('fetch-2', { urls: ['https://example.test/source'] })
      expect(runtime.records).toHaveLength(2)
      expect(runtime.records[1]!.archive_path).not.toBe(record.archive_path)
      expect(readFileSync(join(workdir, record.archive_path))).toEqual(originalBytes)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('allows the researcher to repeat or refine a query', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-research-query-registry-'))
    const workdir = join(root, 'research')
    const delegationID = '019f0000-0000-7000-8000-000000000102'
    let executions = 0
    const search = webSearchTool(() => {
      executions += 1
    })

    try {
      const firstRuntime = createResearchEvidenceArchiveRuntime({ delegationID, workdir, sharedFsRoot: root })
      const firstSearch = firstRuntime.wrapTools([search], 'lead')[0]!
      await firstSearch.execute('search-1', { query: '  Aurora   Budget ' })
      expect(executions).toBe(1)

      await firstSearch.execute('search-2', { query: 'aurora budget' })

      const resumedRuntime = createResearchEvidenceArchiveRuntime({ delegationID, workdir, sharedFsRoot: root })
      const resumedSearch = resumedRuntime.wrapTools([search], 'lead')[0]!
      await resumedSearch.execute('search-3', { query: 'AURORA BUDGET' })
      expect(executions).toBe(3)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('archives successful browser observations before they can be cited', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-research-browser-archive-'))
    const workdir = join(root, 'research')
    const delegationID = '019f0000-0000-7000-8000-000000000103'
    const runtime = createResearchEvidenceArchiveRuntime({ delegationID, workdir, sharedFsRoot: root })
    const browser = runtime.wrapTools([browserTool()], 'lead')[0]!

    try {
      const result = await browser.execute('browser-1', { url: 'https://example.test/dynamic' })
      expect(runtime.records).toHaveLength(1)
      const record = runtime.records[0]!
      expect(record).toMatchObject({
        archive_kind: 'browser',
        source: 'browser_tool:browser_navigate',
        url: 'https://example.test/dynamic',
        tool_call_id: 'browser-1'
      })
      const archived = readFileSync(join(workdir, record.archive_path), 'utf8')
      expect(archived).toContain('Dynamic page observation')
      expect((result.content.at(-1) as { text: string }).text).toContain(record.archive_path)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function webFetchTool(): AgentTool {
  return {
    name: 'web_fetch',
    description: 'Fetch pages.',
    schema: z.object({ urls: z.array(z.string()) }),
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute() {
      return {
        content: [{ type: 'text' as const, text: 'Authoritative source body.' }],
        details: {
          source: 'fixture',
          results: [
            {
              url: 'https://example.test/source',
              title: 'Fixture source',
              text: 'Authoritative source body.',
              metadata: { source: 'fixture' }
            }
          ]
        }
      }
    }
  }
}

function webSearchTool(onExecute: () => void): AgentTool {
  return {
    name: 'web_search',
    description: 'Search pages.',
    schema: z.object({ query: z.string() }),
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute() {
      onExecute()
      return { content: [{ type: 'text' as const, text: 'search result' }], details: {} }
    }
  }
}

function browserTool(): AgentTool {
  return {
    name: 'browser_navigate',
    description: 'Navigate a dynamic page.',
    schema: z.object({ url: z.string().url() }),
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallID, params) {
      return {
        content: [{ type: 'text' as const, text: 'Dynamic page observation' }],
        details: { url: (params as { url: string }).url, title: 'Dynamic fixture' }
      }
    }
  }
}
