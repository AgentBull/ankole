import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { validateToolArguments } from '../src/llm'
import { z } from 'zod'
import type { AgentTool } from '../src/core'
import { buildTool } from '../src/tools/build-tool'
import { createBrowserTools } from '../src/tools/browser/browser-tools'
import { createCommandTool } from '../src/tools/computer/command-tool'
import type { CommandFinished, ComputerToolContext, LocalComputer } from '../src/tools/computer/context'
import { createPatchTool } from '../src/tools/computer/patch-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { createSkillTools } from '../src/tools/library/skill-tools'
import { TodoStore, createTodoTool } from '../src/tools/todo-tool'

type LlmTool = Parameters<typeof validateToolArguments>[0]

const minimalDef = {
  name: 'minimal',
  label: 'Minimal',
  description: 'test tool',
  schema: z.object({}),
  async execute() {
    return { content: [], details: {} }
  }
} satisfies AgentTool<any, any>

describe('@ankole/agent-computer migrated tool semantics', () => {
  it('keeps BullX fail-closed defaults for declarative tools', () => {
    const tool = buildTool(minimalDef)
    expect(tool.executionMode).toBe('sequential')
    expect(tool.isReadOnly).toBe(false)
    expect(tool.isDestructive).toBe(true)

    const explicitlySafe = buildTool({
      ...minimalDef,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false
    })
    expect(explicitlySafe.executionMode).toBe('parallel')
    expect(explicitlySafe.isReadOnly).toBe(true)
    expect(explicitlySafe.isDestructive).toBe(false)
  })

  it('uses each tool zod schema as the argument source of truth', () => {
    const tool = buildTool({
      name: 'validate',
      label: 'Validate',
      description: 'test tool',
      schema: z.object({
        value: z.string().min(1).describe('Value to echo.'),
        limit: z.number().int().min(1).max(20).optional()
      }),
      async execute() {
        return { content: [], details: {} }
      }
    })

    expect(
      validateToolArguments(tool as unknown as LlmTool, {
        type: 'toolCall',
        id: 'tc_1',
        name: 'validate',
        arguments: { value: 'ok', limit: 2 }
      })
    ).toEqual({ value: 'ok', limit: 2 })

    expect(() =>
      validateToolArguments(tool as unknown as LlmTool, {
        type: 'toolCall',
        id: 'tc_2',
        name: 'validate',
        arguments: { value: 123, limit: '2' }
      })
    ).toThrow()
  })

  it('preserves BullX todo read, replace, merge, active snapshot, and caps', async () => {
    const store = new TodoStore()
    expect(store.read()).toEqual([])

    store.write([{ id: '1', content: 'Plan', status: 'pending' }])
    expect(store.read()).toEqual([{ id: '1', content: 'Plan', status: 'pending' }])

    store.write([{ id: '1', status: 'in_progress' }], true)
    expect(store.read()).toEqual([{ id: '1', content: 'Plan', status: 'in_progress' }])
    expect(store.formatActiveSnapshot()).toContain('[>] 1. Plan (in_progress)')

    const tool = createTodoTool(store)
    const result = await tool.execute('todo-1', {
      todos: [{ id: '2', content: 'Ship', status: 'pending' }],
      merge: true
    })
    expect(result.details.todos).toEqual([
      { id: '1', content: 'Plan', status: 'in_progress' },
      { id: '2', content: 'Ship', status: 'pending' }
    ])

    const huge = Array.from({ length: 300 }, (_, index) => ({
      id: String(index),
      content: 'x'.repeat(5000),
      status: 'pending'
    }))
    store.write(huge)
    expect(store.read()).toHaveLength(256)
    expect(store.read()[0]!.content).toHaveLength(4000)
    expect(store.read()[0]!.content.endsWith(' [truncated]')).toBe(true)
  })

  it('runs command through bash with stateless cwd/env and bounded output', async () => {
    const calls: unknown[] = []
    const context = contextWithComputer({
      async runCommand(input) {
        calls.push(input)
        return commandResult(0, '/workspace\n')
      }
    })

    const result = await createCommandTool(context).execute('command-1', {
      command: 'pwd',
      workdir: '/workspace/user-files/repo',
      timeout: 7,
      env: { FOO: 'bar' }
    })

    expect(result.content).toEqual([{ type: 'text', text: 'exit_code=0\n/workspace\n' }])
    expect(result.details).toEqual({ exitCode: 0 })
    expect(calls).toEqual([
      {
        cmd: 'bash',
        args: ['-lc', 'pwd'],
        cwd: '/workspace/user-files/repo',
        env: { FOO: 'bar' },
        timeoutMs: 7000,
        signal: undefined
      }
    ])
  })

  it('read_file returns numbered text and does not throw for missing files', async () => {
    const reads: unknown[] = []
    const context = contextWithComputer({
      readFileToBuffer(input) {
        reads.push(input)
        if (input.path === 'missing.txt') return Promise.resolve(null)
        return Promise.resolve(Buffer.from('first\nsecond\nthird\n'))
      }
    })

    const tool = createReadFileTool(context)
    const read = await tool.execute('read-1', {
      path: 'notes.txt',
      cwd: '/workspace/user-files/repo',
      offset: 2,
      limit: 1
    })
    expect(reads[0]).toEqual({ path: 'notes.txt', cwd: '/workspace/user-files/repo' })
    expect(read.content[0]).toMatchObject({ type: 'text' })
    expect(read.content[0]!.type === 'text' ? read.content[0]!.text : '').toContain('2|second')
    expect(read.content[0]!.type === 'text' ? read.content[0]!.text : '').toContain('use offset')
    expect(read.details).toMatchObject({ found: true, totalLines: 3, truncated: true })

    const missing = await tool.execute('read-2', { path: 'missing.txt' })
    expect(missing.content[0]).toEqual({ type: 'text', text: 'File not found: missing.txt' })
    expect(missing.details.found).toBe(false)
  })

  it('patch replace preserves BOM and CRLF while returning a diff', async () => {
    const writes: Array<{ path: string; content: string | Buffer }> = []
    const context = contextWithComputer({
      readFileToBuffer() {
        return Promise.resolve(Buffer.from('\ufefffirst\r\nold line\r\n'))
      },
      fs: {
        async writeFiles(files) {
          writes.push(...files)
        }
      }
    })

    const result = await createPatchTool(context).execute('patch-1', {
      path: 'src/index.ts',
      old_string: 'old line',
      new_string: 'new line',
      cwd: '/workspace/user-files/repo'
    })

    expect(writes[0]).toMatchObject({ path: 'src/index.ts' })
    expect(String(writes[0]!.content)).toBe('\ufefffirst\r\nnew line\r\n')
    expect(result.content[0]!.type === 'text' ? result.content[0]!.text : '').toContain('-old line')
    expect(result.content[0]!.type === 'text' ? result.content[0]!.text : '').toContain('+new line')
  })

  it('browser tools invoke ankole-browser with scoped session/profile args', async () => {
    const calls: any[] = []
    const writes: Array<{ path: string; content: string | Buffer }> = []
    const context = contextWithComputer({
      async runCommand(input) {
        calls.push(input)
        return commandResult(0, 'noise\n{"ok":true,"title":"Example Domain"}\n')
      },
      fs: {
        async writeFiles(files) {
          writes.push(...files)
        }
      }
    })

    const tools = createBrowserTools(context)
    const open = tools.find(tool => tool.name === 'browser_open')!
    const result = await open.execute('browser-open-1', {
      url: 'https://example.com',
      taskId: 'task 1',
      profileMode: 'persistent'
    })

    expect(result.details).toEqual({ exitCode: 0, result: { ok: true, title: 'Example Domain' } })
    expect(calls[0].cmd).toBe('ankole-browser')
    expect(calls[0].args).toContain('--json')
    expect(calls[0].args).toContain('open')
    expect(calls[0].args).toContain('--profile-mode')
    expect(calls[0].args).toContain('persistent')

    const run = tools.find(tool => tool.name === 'browser_run')!
    await run.execute('browser-run-1', { script: "print('ok')", taskId: 'run one' })
    expect(writes[0]).toMatchObject({
      path: expect.stringContaining('/input_script.py'),
      content: "print('ok')"
    })
  })

  it('model-facing computer tool list is exactly the first-phase allowlist', () => {
    const names = createBrowserTools(contextWithComputer({}))
      .map(tool => tool.name)
      .concat(['command', 'interactive_terminal', 'read_file', 'patch'])

    expect(names).toEqual([
      'browser_doctor',
      'browser_open',
      'browser_extract',
      'browser_run',
      'command',
      'interactive_terminal',
      'read_file',
      'patch'
    ])

    expect(names).not.toContain('terminal')
    expect(names).not.toContain('process')
    expect(names).not.toContain('send_file')
    expect(names).not.toContain('codex_delegate')
    expect(names).not.toContain('check_back_later')
    expect(names).not.toContain('web_search')
    expect(names).not.toContain('web_extract')
  })

  it('skill_view renders effective skills with frontmatter stripped and agent append merged', async () => {
    const root = withLibraryWorkspace()

    try {
      const view = createSkillTools(root).find(tool => tool.name === 'skill_view')!
      const result = await view.execute('skill-view-1', { name: 'nano-pdf' })
      const text = result.content[0]!.type === 'text' ? result.content[0]!.text : ''

      expect(text).toContain(
        '<skill name="nano-pdf" location="/workspace/library-containers/skills/nano-pdf/SKILL.md">'
      )
      expect(text).toContain('<external_content source="skill">')
      expect(text).toContain('# nano-pdf')
      expect(text).toContain('Use OCR carefully.')
      expect(text).toContain('Agent-specific additions:')
      expect(text).toContain('Prefer page-by-page verification.')
      expect(text).not.toContain('name: nano-pdf')

      const reference = await view.execute('skill-view-2', { name: 'nano-pdf', filePath: 'references/api.md' })
      expect(reference.content[0]!.type === 'text' ? reference.content[0]!.text : '').toContain('API reference')
      expect(reference.details).toEqual({ name: 'nano-pdf', path: 'references/api.md' })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_append replaces only AGENT_APPEND.md and rejects skill path traversal', async () => {
    const root = withLibraryWorkspace()

    try {
      const [view, append] = createSkillTools(root)
      const result = await append!.execute('skill-append-1', { name: 'nano-pdf', content: 'New durable overlay.' })

      expect(result.details).toEqual({ name: 'nano-pdf', path: 'AGENT_APPEND.md', changed: true })
      expect(readFileSync(join(root, 'library-containers/skills/nano-pdf/AGENT_APPEND.md'), 'utf8')).toBe(
        'New durable overlay.'
      )
      expect(readFileSync(join(root, 'library-containers/skills/nano-pdf/SKILL.md'), 'utf8')).toContain(
        'Use OCR carefully.'
      )

      await expect(view!.execute('skill-view-escape', { name: 'nano-pdf', filePath: '../SOUL.md' })).rejects.toThrow(
        'skill path escapes skill root'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function contextWithComputer(overrides: Partial<LocalComputer>): ComputerToolContext {
  const computer: LocalComputer = {
    runCommand() {
      return Promise.resolve(commandResult(0, ''))
    },
    readFileToBuffer() {
      return Promise.resolve(Buffer.from(''))
    },
    fs: {
      async writeFiles() {}
    },
    terminals: {
      async list() {
        return []
      },
      async start(name) {
        return { name, status: 'started' }
      },
      async send(name) {
        return { name, status: 'sent' }
      },
      async capture(name) {
        return { name, screen: '' }
      },
      async kill(name) {
        return { name, status: 'killed' }
      }
    },
    ...overrides
  }

  return {
    agentUid: 'agent-1',
    executionScopeId: 'signal-channel:test',
    getComputer: async () => computer,
    backgroundIds: new Set()
  }
}

function commandResult(exitCode: number, output: string): CommandFinished {
  return {
    exitCode,
    async output() {
      return output
    }
  }
}

function withLibraryWorkspace(): string {
  const root = mkdtempSync(join(tmpdir(), 'ankole-tools-'))
  const skillRoot = join(root, 'library-containers/skills/nano-pdf')
  mkdirSync(join(skillRoot, 'references'), { recursive: true })
  writeFileSync(
    join(skillRoot, 'SKILL.md'),
    ['---', 'name: nano-pdf', 'description: PDF analysis', '---', '# nano-pdf', '', 'Use OCR carefully.'].join('\n')
  )
  writeFileSync(join(skillRoot, 'AGENT_APPEND.md'), 'Prefer page-by-page verification.')
  writeFileSync(join(skillRoot, 'references/api.md'), 'API reference')
  return root
}
