import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject } from '@agentbull/active-support'
import { jobWebFetchResult } from '../src/tools/web/web-fetch-result'
import { createWebTools, renderedFallbackFetch } from '../src/tools/web/web-tools'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { createContainerComputer } from '../src/tools/computer/computer'
import { buildCodexJobProjection } from '../src/core/codex-runner/job/projection'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { mkdirAgentSync } from '../src/common/agent-user'
import type { RPCRequester } from '../src/lanes/rpc_lane'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})
function workspace(): string {
  const root = mkdtempSync(join(tmpdir(), 'web-fetch-'))
  mkdirAgentSync(root, 0o700)
  roots.push(root)
  return root
}
function page(text: string, url = 'https://example.com/article', total = [...text].length): JsonObject {
  return {
    url,
    text,
    title: 'Article',
    total_characters: total,
    stored_characters: [...text].length,
    cache_at: 1700000000000
  }
}
function text(result: { content: Array<{ type: string; text?: string }> }): string {
  return result.content.map(part => part.text || '').join('\n')
}
function records(result: { details: JsonObject }): JsonObject[] {
  return result.details.results as JsonObject[]
}

describe('Job web_fetch workspace output', () => {
  it('stores a complete rendered article beyond 512K and reads its formerly missing middle and true ending', async () => {
    const root = workspace()
    const body = `START\n${'ordinary article line\n'.repeat(35_000)}TRUE-ARTICLE-END\n`
    const normalized = await renderedFallbackFetch(
      ['https://example.com/long'],
      {
        fetchBatch: async (_urls, _signal, mode) => {
          expect(mode).toBe('workspace')
          return { results: [{ text: body, total_characters: body.length, stored_characters: body.length }] }
        }
      },
      undefined,
      'workspace'
    )
    const normalizedPage = (normalized.results as JsonObject[])[0]!
    const result = await jobWebFetchResult(
      [{ ...normalizedPage, source: 'rendered_fallback' }],
      root,
      createContainerComputer(root, root)
    )
    const record = records(result)[0]!
    const saved = readFileSync(String(record.file_path), 'utf8')
    expect(saved).toBe(body)
    expect(record.total_characters).toBe(body.length)
    expect(record.stored_characters).toBe(body.length)
    expect(text(result)).toContain('TRUE-ARTICLE-END')
    expect([...text(result)].length).toBeLessThanOrEqual(40_000)
    const reader = createReadFileTool({
      agentHome: root,
      workspaceRoot: root,
      computer: createContainerComputer(root, root)
    })
    const read = await reader.execute('rendered-middle', { path: String(record.file_path), offset: 30_000, limit: 1 })
    expect(text(read)).toContain('30000|ordinary article line')
  })

  it('returns complete short Unicode pages without creating workspace files or duplicating body metadata', async () => {
    const root = workspace()
    const body = '第一行 🚀\nsecond line'
    const result = await jobWebFetchResult([page(body)], root, createContainerComputer(root, root))
    expect(text(result)).toContain(body)
    expect(records(result)).toEqual([
      {
        url: 'https://example.com/article',
        title: 'Article',
        total_characters: [...body].length,
        returned_characters: [...body].length,
        repeat_fetch: false
      }
    ])
    expect(existsSync(join(root, 'temp'))).toBe(false)
  })

  it('keeps full lines at both ends, stores the full page, and includes headers inside the 40k call budget', async () => {
    const root = workspace()
    const lines = Array.from({ length: 900 }, (_, index) => `line-${index}: ${'🚀中文'.repeat(40)}\n`)
    const body = lines.join('')
    const result = await jobWebFetchResult([page(body)], root, createContainerComputer(root, root))
    const output = text(result)
    const record = records(result)[0]!
    expect([...output].length).toBeLessThanOrEqual(40_000)
    expect(output).toContain(lines[0]!)
    expect(output).toContain(lines.at(-1)!)
    expect(output).not.toContain(lines[450]!)
    expect(output.indexOf('read_file(')).toBeLessThan(output.indexOf('--- Page 1 ---'))
    expect(readFileSync(String(record.file_path), 'utf8')).toBe(body)
    const excerpt = output.split('--- Page 1 ---\n')[1]!
    for (const line of excerpt.split('\n').filter(line => line && line !== '[... omitted ...]')) {
      expect(lines).toContain(`${line}\n`)
    }
    expect(JSON.stringify(record)).not.toContain('line-')
  })

  it('redistributes small pages shares across large pages while preserving per-page failures', async () => {
    const root = workspace()
    const small = 's'.repeat(1000)
    const large = 'large line 🚀\n'.repeat(15_000)
    const result = await jobWebFetchResult(
      [
        page(small, 'https://example.com/small'),
        page(large, 'https://example.com/large-1'),
        page(large, 'https://example.com/large-2'),
        { ...page('', 'https://example.com/failed'), error: 'upstream unavailable' }
      ],
      root,
      createContainerComputer(root, root)
    )
    const output = text(result)
    const resultPages = records(result)
    expect([...output].length).toBeLessThanOrEqual(40_000)
    expect(output).toContain(small)
    expect(resultPages[0]).not.toHaveProperty('file_path')
    expect(Number(resultPages[1]!.returned_characters)).toBeGreaterThan(15_000)
    expect(
      Math.abs(Number(resultPages[1]!.returned_characters) - Number(resultPages[2]!.returned_characters))
    ).toBeLessThan(100)
    expect(resultPages[3]!.error).toBe('upstream unavailable')
    expect(resultPages[3]).not.toHaveProperty('file_path')
  })

  it('writes exactly the 2M-character transport prefix and clearly reports the source cap', async () => {
    const root = workspace()
    const body = '🚀\n'.repeat(1_000_000)
    const ending = 'actual original ending\n'
    const result = await jobWebFetchResult(
      [
        {
          ...page(body, undefined, 2_000_000 + ending.length),
          tail: `${'🚀\n'.repeat(20_000)}${ending}`
        }
      ],
      root,
      createContainerComputer(root, root)
    )
    const record = records(result)[0]!
    const stored = readFileSync(String(record.file_path), 'utf8')
    expect([...stored].length).toBe(2_000_000)
    expect(stored).toBe(body)
    expect(text(result)).toContain(`2000000 of ${2_000_000 + ending.length} characters saved`)
    expect(text(result)).toContain('actual original ending\n')
    expect(stored).not.toContain('actual original ending')
    expect([...text(result)].length).toBeLessThanOrEqual(40_000)
  })

  it('returns bounded head and tail when the workspace file cannot be written', async () => {
    const root = workspace()
    writeFileSync(join(root, 'temp'), 'not a directory')
    const body = 'whole line\n'.repeat(10_000)
    const result = await jobWebFetchResult([page(body)], root, createContainerComputer(root, root))
    expect([...text(result)].length).toBeLessThanOrEqual(40_000)
    expect(text(result)).toContain('Full page file unavailable')
    expect(text(result)).toContain('whole line\n')
    expect(records(result)[0]!.file_unavailable).toBe(true)
    expect(records(result)[0]).not.toHaveProperty('file_path')
    expect(text(result)).not.toContain('read_file(')
  })

  it('omits oversized individual lines whole and rejects cancellation or malformed transport counts', async () => {
    const root = workspace()
    const body = `${'🚀'.repeat(10_000)}MIDDLE-CODEWORD${'🚀'.repeat(40_000)}`
    const result = await jobWebFetchResult([page(body)], root, createContainerComputer(root, root))
    const excerpt = text(result).split('--- Page 1 ---\n')[1]!
    expect(excerpt).toBe('\n[... omitted ...]\n')
    expect(text(result)).toContain('If read_file truncates a long line, use the command shell')
    expect([...text(result)].length).toBeLessThanOrEqual(40_000)
    const hint = /read_file\((\{[^\n]+\})\)/.exec(text(result))
    const params = JSON.parse(hint![1]!) as { path: string; offset: number; limit: number }
    const computer = createContainerComputer(root, root)
    const reader = createReadFileTool({ agentHome: root, workspaceRoot: root, computer })
    const read = await reader.execute('long-line', params)
    expect(text(read)).not.toContain('MIDDLE-CODEWORD')
    expect(readFileSync(params.path, 'utf8')).toBe(body)
    const command = await computer.runCommand({
      cmd: process.execPath,
      args: ['-e', 'process.stdout.write((await Bun.file(process.argv[1]).text()).slice(20000,20015))', params.path]
    })
    expect(command.exitCode).toBe(0)
    expect(await command.output()).toBe('MIDDLE-CODEWORD')
    const aborted = AbortSignal.abort()
    await expect(
      jobWebFetchResult([page('x\n'.repeat(50_000))], root, createContainerComputer(root, root), aborted)
    ).rejects.toThrow()
    await expect(
      jobWebFetchResult([{ ...page('short'), total_characters: 1 }], root, createContainerComputer(root, root))
    ).rejects.toThrow('character counts')
  })

  it('passes a real web result through the Job projection and executes its exact read_file hint against the same workspace', async () => {
    const root = workspace()
    const body = Array.from({ length: 1500 }, (_, index) => `row-${index}: ${'中文🚀'.repeat(25)}\n`).join('')
    const tools = await createWebTools({
      workspaceRoot: root,
      computer: createContainerComputer(root, root),
      turn: { session: { session_id: 'job:1000' }, job_id: 1000, attempt: 1, signal_id: 'input' },
      rpc: (async () => ({
        bodyJson: jsonBytes({ output: '', details: { results: [page(body)] } })
      })) as unknown as RPCRequester
    })
    const readFile = createReadFileTool({
      agentHome: root,
      workspaceRoot: root,
      computer: createContainerComputer(root, root)
    })
    const projection = buildCodexJobProjection({ tools: [...tools, readFile] })
    const invoke = (tool: string, args: Parameters<typeof projection.handleToolCall>[0]['arguments']) =>
      projection.handleToolCall(
        {
          threadId: 'thread',
          turnId: 'turn',
          callId: tool,
          namespace: null,
          tool,
          arguments: args
        },
        new AbortController().signal
      )
    const fetched = await invoke('web_fetch', { urls: ['https://example.com/article'] })
    expect(fetched.success).toBe(true)
    const output = fetched.contentItems[0]?.type === 'inputText' ? fetched.contentItems[0].text : ''
    expect([...output].length).toBeLessThanOrEqual(40_000)
    expect(Buffer.byteLength(output)).toBeGreaterThan(16_384)
    expect(output).not.toContain('...[truncated]')
    const hint = /read_file\((\{[^\n]+\})\)/.exec(output)
    expect(hint).not.toBeNull()
    const args = JSON.parse(hint![1]!) as { offset: number }
    const read = await invoke('read_file', args)
    expect(read.success).toBe(true)
    const readOutput = read.contentItems[0]?.type === 'inputText' ? read.contentItems[0].text : ''
    expect(readOutput).toContain(`row-${args.offset - 1}:`)
    expect(readOutput).not.toContain('...[truncated]')
    expect(readOutput).toContain(`continue with offset=${args.offset + 100}`)
  })

  it.each([
    ['Chinese', '中文'.repeat(900)],
    ['emoji', '🚀'.repeat(900)]
  ])('preserves a full bounded %s file window and its next offset in a Job', async (_label, line) => {
    const root = workspace()
    const path = join(root, 'article.md')
    writeFileSync(path, Array.from({ length: 200 }, (_, index) => `row-${index}: ${line}\n`).join(''))
    const readFile = createReadFileTool({
      agentHome: root,
      workspaceRoot: root,
      computer: createContainerComputer(root, root)
    })
    const args = { path, offset: 1, limit: 100 }
    const raw = await readFile.execute('direct', args)
    const expected = text(raw)
    expect(Buffer.byteLength(expected)).toBeGreaterThan(160_000)
    const projection = buildCodexJobProjection({ tools: [readFile] })
    const read = (offset: number) =>
      projection.handleToolCall(
        {
          threadId: 'thread',
          turnId: 'turn',
          callId: 'read',
          namespace: null,
          tool: 'read_file',
          arguments: { ...args, offset }
        },
        new AbortController().signal
      )
    const result = await read(1)
    expect(result.success).toBe(true)
    const output = result.contentItems[0]?.type === 'inputText' ? result.contentItems[0].text : ''
    expect(output).toBe(expected)
    const nextOffset = /continue with offset=(\d+)/.exec(output)
    expect(nextOffset).not.toBeNull()
    const next = await read(Number(nextOffset![1]))
    expect(next.success).toBe(true)
    const nextOutput = next.contentItems[0]?.type === 'inputText' ? next.contentItems[0].text : ''
    expect(nextOutput).toStartWith(`${nextOffset![1]}|row-${Number(nextOffset![1]) - 1}:`)
  })
})
