import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { POD_CLI_HELP } from '../src/cli/pod/pod-cli'
import { startPodCLIBridge } from '../src/cli/pod/pod-cli-bridge'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequestInit } from '../src/lanes/rpc_contract'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { FakeDrive } from './support/fake-drive'

const respond = (result: unknown) => create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ result }) })

const VALID_MERMAID = 'flowchart LR\n  Fetch[读取数据] --> Render[渲染图表]'
const INVALID_MERMAID = 'flowchart LR\n  Broken -->'

const VALID_INFOGRAPHIC = [
  'infographic list-row-simple-horizontal-arrow',
  'data',
  '  title 核心里程碑',
  '  items',
  '    - label 第一步',
  '      desc 采集指标',
  '    - label 第二步',
  '      desc 导出报告'
].join('\n')

const INVALID_INFOGRAPHIC = ['infographic nonexistent-template-name', 'data', '  title 错误示例'].join('\n')

describe('Pod CLI help & incremental diagram syntax preflight', () => {
  it('documents Base chart views, aggregate/drill-down parameters, Doc/Knowledge diagram rules, and Applet viz exports in POD_CLI_HELP', () => {
    expect(POD_CLI_HELP).toContain('ChartViewSpec')
    expect(POD_CLI_HELP).toContain('count_distinct')
    expect(POD_CLI_HELP).toContain('other_exclude_values_json')
    expect(POD_CLI_HELP).toContain('<embed ref=')
    expect(POD_CLI_HELP).toContain('<infographic>')
    expect(POD_CLI_HELP).toContain('AnkoleChart')
    expect(POD_CLI_HELP).toContain('AnkoleFinancialChart')
    expect(POD_CLI_HELP).toContain('AnkoleYieldCurveChart')
    expect(POD_CLI_HELP).toContain('AnkoleInfographic')
    expect(POD_CLI_HELP).toContain('AnkoleStatCard')
    expect(POD_CLI_HELP).toContain('AnkoleSparkline')
    expect(POD_CLI_HELP).toContain('recordsToFinancialSeries')
    expect(POD_CLI_HELP).toContain('densifyTimeBuckets')
    expect(POD_CLI_HELP).toContain('formatMetricValue')
  })

  it('passes valid Mermaid and Infographic blocks with zero extra pages.read RPCs and rejects new broken blocks before mutating', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-diagram-fastpath-'))
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    const rpcLog: { method: string; operation: string }[] = []
    let storedMarkdown = '# Existing Doc\n\nInitial paragraph.'
    const storedType = 'doc'

    const rpc = (async (method, raw) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      const op = payload.operation!
      rpcLog.push({ method, operation: op })
      const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params') ?? {}
      if (op === 'pages.read') {
        if (typeof params.markdown_home_relative_path === 'string') {
          await writeFile(join(root, params.markdown_home_relative_path), storedMarkdown, 'utf8')
        }
        return respond({ page: { id: 'doc-1', type: storedType, revision: 3 }, content: { markdown_file: true } })
      }
      if (op === 'pages.write' || op === 'pages.append') {
        const local = join(root, params.markdown_home_relative_path as string)
        const incoming = await readFile(local, 'utf8')
        storedMarkdown = op === 'pages.append' ? `${storedMarkdown}\n\n${incoming}` : incoming
      }
      return respond({ id: 'doc-1', revision: 4 })
    }) as RPCRequester

    const bridge = startPodCLIBridge({
      rpc,
      frame,
      drive: new FakeDrive(root).drive(),
      socketRoot: root
    })

    const send = (operation: string, params: Record<string, unknown>) =>
      requestSocketLineBridge(bridge.socketPath, JSON.stringify({ operation, params, cwd: root }), 'invalid')

    try {
      // 1. Valid `pages.create`, `pages.append`, `pages.write` execute with ZERO `pages.read` RPCs.
      const validDocMarkdown = [
        '# Architecture',
        '',
        '```mermaid',
        VALID_MERMAID,
        '```',
        '',
        '<infographic title="Roadmap">',
        VALID_INFOGRAPHIC,
        '</infographic>'
      ].join('\n')

      await send('pages.create', { type: 'doc', title: 'Valid Doc', markdown: validDocMarkdown })
      await send('pages.write', { id: 'doc-1', base_revision: 3, markdown: validDocMarkdown })
      await send('pages.append', {
        id: 'doc-1',
        base_revision: 3,
        markdown: `<mermaid title="Flow">\n${VALID_MERMAID}\n</mermaid>`
      })

      expect(rpcLog).toEqual([
        { method: 'pod.write', operation: 'pages.create' },
        { method: 'pod.write', operation: 'pages.write' },
        { method: 'pod.write', operation: 'pages.append' }
      ])

      // 2. Invalid Mermaid and Infographic blocks are rejected on create / append / write / patch BEFORE write RPCs.
      rpcLog.length = 0
      await expect(
        send('pages.create', {
          type: 'doc',
          title: 'Broken Mermaid',
          markdown: `# Bad\n\n\`\`\`mermaid\n${INVALID_MERMAID}\n\`\`\``
        })
      ).rejects.toThrow(/mermaid block at line 3/i)
      expect(rpcLog).toEqual([])

      await expect(
        send('pages.append', {
          id: 'doc-1',
          base_revision: 3,
          markdown: `\`\`\`infographic\n${INVALID_INFOGRAPHIC}\n\`\`\``
        })
      ).rejects.toThrow(/infographic block at line 1/i)
      // `pages.append` consulted `pages.read` once to check `:knowledge` exemption, then aborted without `pages.append` write!
      expect(rpcLog).toEqual([{ method: 'pod.read', operation: 'pages.read' }])

      rpcLog.length = 0
      storedMarkdown = '# Clean Doc\n\nHello world.'
      await expect(
        send('pages.write', {
          id: 'doc-1',
          base_revision: 3,
          markdown: `# Clean Doc\n\n<mermaid>\n${INVALID_MERMAID}\n</mermaid>`
        })
      ).rejects.toThrow(/mermaid block at line 3/i)
      expect(rpcLog).toEqual([{ method: 'pod.read', operation: 'pages.read' }])

      rpcLog.length = 0
      await expect(
        send('pages.patch', {
          id: 'doc-1',
          base_revision: 3,
          edits: [{ old_text: 'Hello world.', new_text: `\`\`\`infographic\n${INVALID_INFOGRAPHIC}\n\`\`\`` }]
        })
      ).rejects.toThrow(/infographic block at line 3/i)
      // `pages.patch` performed only its single initial `pages.read` and never sent `pages.write`!
      expect(rpcLog).toEqual([{ method: 'pod.read', operation: 'pages.read' }])

      expect(await readdir(join(root, '.ankole/pod-content'))).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('exempts untouched legacy broken Mermaid and Infographic blocks when pages.write or pages.patch edits prose elsewhere', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-diagram-legacy-'))
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    const writes: string[] = []

    let existingMarkdown = [
      '# Legacy Report',
      '',
      'Introductory paragraph before edit.',
      '',
      '```mermaid',
      INVALID_MERMAID,
      '```',
      '',
      '```infographic',
      INVALID_INFOGRAPHIC,
      '```'
    ].join('\n')

    const rpc = (async (_method, raw) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params') ?? {}
      const local = join(root, params.markdown_home_relative_path as string)
      if (payload.operation === 'pages.read') {
        await writeFile(local, existingMarkdown, 'utf8')
        return respond({ page: { id: 'legacy-doc', type: 'doc', revision: 10 }, content: { markdown_file: true } })
      }
      const nextMd = await readFile(local, 'utf8')
      writes.push(nextMd)
      existingMarkdown = nextMd
      return respond({ page: { id: 'legacy-doc', revision: 11 } })
    }) as RPCRequester

    const bridge = startPodCLIBridge({
      rpc,
      frame,
      drive: new FakeDrive(root).drive(),
      socketRoot: root
    })

    const send = (operation: string, params: Record<string, unknown>) =>
      requestSocketLineBridge(bridge.socketPath, JSON.stringify({ operation, params, cwd: root }), 'invalid')

    try {
      // 1. `pages.patch` editing prose while leaving both legacy broken blocks untouched succeeds!
      await send('pages.patch', {
        id: 'legacy-doc',
        base_revision: 10,
        edits: [{ old_text: 'Introductory paragraph before edit.', new_text: 'Updated executive summary.' }]
      })
      expect(writes).toHaveLength(1)
      expect(writes[0]).toContain('Updated executive summary.')

      // 2. `pages.write` updating prose while keeping the exact same broken blocks untouched also succeeds!
      const updatedProseDoc = existingMarkdown.replace('Updated executive summary.', 'Second prose revision.')
      await send('pages.write', {
        id: 'legacy-doc',
        base_revision: 10,
        markdown: updatedProseDoc
      })
      expect(writes).toHaveLength(2)
      expect(writes[1]).toContain('Second prose revision.')

      // 3. Modifying the legacy broken Mermaid block to a DIFFERENT broken Mermaid block is rejected!
      await expect(
        send('pages.patch', {
          id: 'legacy-doc',
          base_revision: 10,
          edits: [{ old_text: 'Broken -->', new_text: 'StillBroken ===>' }]
        })
      ).rejects.toThrow(/mermaid block/i)
      expect(writes).toHaveLength(2)
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('ignores <pre lang="mermaid">, meta-string fences, and quadruple fences, and ignores fenced infographic in :knowledge pages', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-diagram-exemptions-'))
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    const rpcCalls: string[] = []
    const knowledgeMarkdown = '---\ntitle: KB\n---\n\nInitial note.'

    const rpc = (async (_method, raw) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      rpcCalls.push(payload.operation!)
      const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params') ?? {}
      if (payload.operation === 'pages.read') {
        const local = join(root, params.markdown_home_relative_path as string)
        await writeFile(local, knowledgeMarkdown, 'utf8')
        return respond({ page: { id: 'kb-1', type: 'knowledge', revision: 2 }, content: { markdown_file: true } })
      }
      return respond({ id: 'kb-1', revision: 3 })
    }) as RPCRequester

    const bridge = startPodCLIBridge({
      rpc,
      frame,
      drive: new FakeDrive(root).drive(),
      socketRoot: root
    })

    const send = (operation: string, params: Record<string, unknown>) =>
      requestSocketLineBridge(bridge.socketPath, JSON.stringify({ operation, params, cwd: root }), 'invalid')

    try {
      // 1. `<pre lang="mermaid">`, meta-string fences, inline code spans, and 4-backtick outer fences are ignored with 0 extra RPCs.
      const literalExamplesMarkdown = [
        '# Syntax Guide',
        '',
        'Inline mention of `<mermaid>not parsed</mermaid>` in prose.',
        '',
        '<pre lang="mermaid">',
        INVALID_MERMAID,
        '</pre>',
        '',
        '```mermaid title="broken-raw-example"',
        INVALID_MERMAID,
        '```',
        '',
        '````markdown',
        '```mermaid',
        INVALID_MERMAID,
        '```',
        '<infographic>',
        INVALID_INFOGRAPHIC,
        '</infographic>',
        '````'
      ].join('\n')

      await send('pages.write', { id: 'doc-guide', base_revision: 1, markdown: literalExamplesMarkdown })
      expect(rpcCalls).toEqual(['pages.write'])

      // 2. `:knowledge` pages ignore ` ```infographic ` fences while still validating ` ```mermaid `!
      rpcCalls.length = 0
      await send('pages.create', {
        type: 'knowledge',
        parent_id: 'space-root',
        title: 'KB Entry',
        markdown: `---\ntitle: KB\n---\n\n\`\`\`infographic\n${INVALID_INFOGRAPHIC}\n\`\`\`\n\n\`\`\`mermaid\n${VALID_MERMAID}\n\`\`\``
      })
      expect(rpcCalls).toEqual(['pages.create'])

      // `pages.write` on an existing `:knowledge` page also exempts ` ```infographic ` via `pages.read` type check:
      rpcCalls.length = 0
      await send('pages.write', {
        id: 'kb-1',
        base_revision: 2,
        markdown: `---\ntitle: KB\n---\n\n\`\`\`infographic\n${INVALID_INFOGRAPHIC}\n\`\`\``
      })
      expect(rpcCalls).toEqual(['pages.read', 'pages.write'])

      // Whereas invalid ` ```mermaid ` on `:knowledge` IS rejected!
      rpcCalls.length = 0
      await expect(
        send('pages.create', {
          type: 'knowledge',
          parent_id: 'space-root',
          title: 'Bad KB Mermaid',
          markdown: `---\ntitle: KB\n---\n\n\`\`\`mermaid\n${INVALID_MERMAID}\n\`\`\``
        })
      ).rejects.toThrow(/mermaid block/i)
      expect(rpcCalls).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })
})
