import { describe, expect, it } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { validateToolArguments } from '../src/llm'
import { z } from 'zod'
import type { AgentTool } from '../src/core'
import { buildTool } from '../src/tools/build-tool'
import { createBrowserTools } from '../src/tools/browser/browser-tools'
import { createComputerTools } from '../src/tools/computer'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  type BackgroundCommandSnapshot,
  createContainerComputer,
  type CommandFinished,
  type ComputerToolContext,
  type ContainerComputer
} from '../src/tools/computer/context'
import { bubblewrapArgv } from '../src/tools/computer/bubblewrap'
import { createPatchTool } from '../src/tools/computer/patch-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { createReplyAttachmentStore, createReplyAttachmentTool } from '../src/tools/computer/reply-attachment-tool'
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

  it('starts, polls, and kills background commands through the command tool', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-computer-'))

    try {
      const computer = createContainerComputer(root)
      const context: ComputerToolContext = {
        agentUid: 'agent-1',
        workspaceRoot: root,
        executionScopeId: 'signal-channel:test',
        getComputer: async () => computer,
        backgroundIds: new Set()
      }
      const tool = createCommandTool(context)

      const started = await tool.execute('command-bg-start', {
        command: 'printf READY; sleep 30',
        background: true,
        timeout: 30
      })
      const backgroundId = started.details.backgroundId!

      expect(backgroundId.startsWith('bg-')).toBe(true)
      expect(started.content[0]!.type === 'text' ? started.content[0]!.text : '').toContain('status=running')
      expect(context.backgroundIds.has(backgroundId)).toBe(true)

      let statusText = ''
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const status = await tool.execute('command-bg-status', {
          action: 'status',
          backgroundId
        })
        statusText = status.content[0]!.type === 'text' ? status.content[0]!.text : ''
        if (statusText.includes('READY')) break
        await Bun.sleep(25)
      }

      expect(statusText).toContain(`background_id=${backgroundId}`)
      expect(statusText).toContain('status=running')
      expect(statusText).toContain('READY')

      const killed = await tool.execute('command-bg-kill', {
        action: 'kill',
        backgroundId
      })
      const killedText = killed.content[0]!.type === 'text' ? killed.content[0]!.text : ''
      expect(killedText).toContain(`background_id=${backgroundId}`)
      expect(killedText).toContain('status=killed')
      expect(context.backgroundIds.has(backgroundId)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('runs container commands asynchronously with scoped env and abort handling', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-computer-'))
    const previousSecret = process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN

    try {
      process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN = 'secret-token'

      const computer = createContainerComputer(root)
      const result = await computer.runCommand({
        cmd: 'bash',
        args: ['-lc', 'printf "%s|%s" "${ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN-unset}" "$FOO"'],
        env: { FOO: 'visible' }
      })

      expect(result.exitCode).toBe(0)
      expect(await result.output('stdout')).toBe('unset|visible')

      const controller = new AbortController()
      controller.abort()
      const aborted = await computer.runCommand({
        cmd: 'bash',
        args: ['-lc', 'sleep 5'],
        signal: controller.signal
      })

      expect(aborted.exitCode).toBe(130)
      expect(await aborted.output('stderr')).toBe('command aborted')
    } finally {
      if (previousSecret === undefined) {
        delete process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN
      } else {
        process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN = previousSecret
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('wraps stateless commands in bubblewrap', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-computer-'))
    const bin = join(root, 'bin')
    const argsFile = join(root, 'bwrap-args.txt')
    const previousSecret = process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN

    try {
      mkdirSync(bin, { recursive: true })
      mkdirSync(join(root, 'sub'), { recursive: true })
      writeFileSync(join(bin, 'bwrap'), '#!/bin/sh\nprintf "%s\\n" "$@" > "$BWRAP_ARGS_FILE"\nexit 0\n')
      chmodSync(join(bin, 'bwrap'), 0o755)

      process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN = 'secret-token'

      const result = await createContainerComputer(root).runCommand({
        cmd: 'bash',
        args: ['-lc', 'printf ok'],
        cwd: '/workspace/sub',
        env: {
          BWRAP_ARGS_FILE: argsFile,
          PATH: `${bin}:${process.env.PATH ?? ''}`
        }
      })

      expect(result.exitCode).toBe(0)

      const args = readFileSync(argsFile, 'utf8').trim().split('\n')
      expect(args).toContain('--unshare-all')
      expect(args).toContain('--share-net')
      expect(args).toContain('--clearenv')
      expect(args.slice(args.indexOf('--bind'), args.indexOf('--bind') + 3)).toEqual(['--bind', root, '/workspace'])
      expect(args.slice(args.indexOf('--chdir'), args.indexOf('--chdir') + 2)).toEqual(['--chdir', '/workspace/sub'])
      expect(args).not.toContain('ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN')

      const commandIndex = args.indexOf('timeout')
      expect(args.slice(commandIndex, commandIndex + 5)).toEqual(['timeout', '60s', 'bash', '-lc', 'printf ok'])
    } finally {
      if (previousSecret === undefined) {
        delete process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN
      } else {
        process.env.ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN = previousSecret
      }

      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps weak bubblewrap as bwrap with container procfs instead of an unsandboxed fallback', () => {
    const base = {
      workspaceRoot: '/workspace',
      cwd: '/workspace/project',
      env: { PATH: '/usr/bin', HOME: '/workspace' },
      commandArgv: ['true']
    }

    const strong = bubblewrapArgv(base, 'strong')
    expect(strong[0]).toBe('bwrap')
    expect(strong.slice(strong.indexOf('--proc'), strong.indexOf('--proc') + 2)).toEqual(['--proc', '/proc'])

    const weak = bubblewrapArgv(base, 'weak')
    expect(weak[0]).toBe('bwrap')
    expect(weak).not.toContain('--proc')
    expect(weak.slice(weak.indexOf('--dir'), weak.indexOf('--dir') + 2)).toEqual(['--dir', '/proc'])
    const procBindIndex = weak.findIndex((arg, index) => arg === '--ro-bind' && weak[index + 1] === '/proc')
    expect(weak.slice(procBindIndex, procBindIndex + 3)).toEqual(['--ro-bind', '/proc', '/proc'])
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
    expect(reads[0]).toEqual({
      path: 'notes.txt',
      cwd: '/workspace/user-files/repo'
    })
    expect(read.content[0]).toMatchObject({ type: 'text' })
    expect(read.content[0]!.type === 'text' ? read.content[0]!.text : '').toContain('2|second')
    expect(read.content[0]!.type === 'text' ? read.content[0]!.text : '').toContain('use offset')
    expect(read.details).toMatchObject({
      found: true,
      totalLines: 3,
      truncated: true
    })

    const missing = await tool.execute('read-2', { path: 'missing.txt' })
    expect(missing.content[0]).toEqual({
      type: 'text',
      text: 'File not found: missing.txt'
    })
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

    expect(result.details).toEqual({
      exitCode: 0,
      result: { ok: true, title: 'Example Domain' }
    })
    expect(calls[0].cmd).toBe('ankole-browser')
    expect(calls[0].args).toContain('--json')
    expect(calls[0].args).toContain('open')
    expect(calls[0].args).toContain('--profile-mode')
    expect(calls[0].args).toContain('persistent')

    const run = tools.find(tool => tool.name === 'browser_run')!
    await run.execute('browser-run-1', {
      script: "print('ok')",
      taskId: 'run one'
    })
    expect(writes[0]).toMatchObject({
      path: expect.stringContaining('/input_script.py'),
      content: "print('ok')"
    })
  })

  it('model-facing computer tool list is exactly the first-phase allowlist', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-computer-tools-'))

    try {
      const names = createComputerTools({
        agentUid: 'agent-1',
        conversationId: 'signal-channel:test',
        workspaceRoot: root,
        replyAttachmentStore: createReplyAttachmentStore()
      }).map(tool => tool.name)

      expect(names).toEqual([
        'browser_doctor',
        'browser_open',
        'browser_extract',
        'browser_run',
        'command',
        'interactive_terminal',
        'read_file',
        'patch',
        'reply_attachment'
      ])

      expect(names).not.toContain('terminal')
      expect(names).not.toContain('process')
      expect(names).not.toContain('send_file')
      expect(names).not.toContain('codex_delegate')
      expect(names).not.toContain('check_back_later')
      expect(names).not.toContain('web_search')
      expect(names).not.toContain('web_extract')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('reply_attachment records final reply files from /workspace/user-files only', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-reply-attachment-'))

    try {
      mkdirSync(join(root, 'user-files/reports'), { recursive: true })
      mkdirSync(join(root, 'temp'), { recursive: true })
      writeFileSync(join(root, 'user-files/reports/a.txt'), 'hello attachment')
      writeFileSync(join(root, 'temp/a.txt'), 'scratch')

      const store = createReplyAttachmentStore()
      const tool = createReplyAttachmentTool(contextWithComputer({}, root), store)
      const result = await tool.execute('reply-attachment-1', {
        path: '/workspace/user-files/reports/a.txt',
        name: 'report.txt',
        mimeType: 'text/plain'
      })

      expect(result.details).toMatchObject({
        registered: true,
        agent_computer_path: '/workspace/user-files/reports/a.txt',
        user_files_relative_path: 'reports/a.txt',
        name: 'report.txt',
        mime_type: 'text/plain',
        size: 16
      })
      expect(store.attachments).toEqual([
        {
          agent_computer_path: '/workspace/user-files/reports/a.txt',
          user_files_relative_path: 'reports/a.txt',
          name: 'report.txt',
          mime_type: 'text/plain',
          size: 16
        }
      ])

      await expect(tool.execute('reply-attachment-escape', { path: '/workspace/temp/a.txt' })).rejects.toThrow(
        '/workspace/user-files'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_view renders effective skills with frontmatter stripped and DB overlay merged', async () => {
    const root = withLibraryWorkspace()

    try {
      const view = createSkillTools(root, {
        turn: testTurnRef(),
        enabledSkills: ['nano-pdf'],
        async requestSkillOverlay(request) {
          return {
            request_id: request.request_id,
            agent_uid: request.turn.actor.agent_uid,
            session_id: request.turn.actor.session_id,
            skill_name: request.skill_name,
            has_overlay: true,
            overlay_json: { text: 'Prefer page-by-page verification.' },
            content_hash: 'hash'
          }
        }
      }).find(tool => tool.name === 'skill_view')!
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

      const reference = await view.execute('skill-view-2', {
        name: 'nano-pdf',
        filePath: 'references/api.md'
      })
      expect(reference.content[0]!.type === 'text' ? reference.content[0]!.text : '').toContain('API reference')
      expect(reference.details).toEqual({
        name: 'nano-pdf',
        path: 'references/api.md'
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_append replaces DB overlay and rejects skill path traversal', async () => {
    const root = withLibraryWorkspace()

    try {
      const turn = testTurnRef()
      let replacedContent = ''
      const [view, append] = createSkillTools(root, {
        turn,
        enabledSkills: ['nano-pdf'],
        async replaceSkillOverlay(request) {
          replacedContent = request.content
          return {
            request_id: request.request_id,
            agent_uid: request.turn.actor.agent_uid,
            session_id: request.turn.actor.session_id,
            skill_name: request.skill_name,
            has_overlay: true,
            overlay_json: { text: request.content },
            content_hash: 'hash'
          }
        }
      })
      const result = await append!.execute('skill-append-1', {
        name: 'nano-pdf',
        content: 'New durable overlay.'
      })

      expect(result.details).toEqual({ name: 'nano-pdf', changed: true })
      expect(replacedContent).toBe('New durable overlay.')
      expect(readFileSync(join(root, 'library-containers/skills/nano-pdf/SKILL.md'), 'utf8')).toContain(
        'Use OCR carefully.'
      )

      await expect(
        view!.execute('skill-view-escape', {
          name: 'nano-pdf',
          filePath: '../SOUL.md'
        })
      ).rejects.toThrow('invalid skill file path')
      await expect(
        append!.execute('skill-append-escape', {
          name: '../nano-pdf',
          content: 'x'
        })
      ).rejects.toThrow('invalid skill name')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function contextWithComputer(overrides: Partial<ContainerComputer>, workspaceRoot?: string): ComputerToolContext {
  const computer: ContainerComputer = {
    runCommand() {
      return Promise.resolve(commandResult(0, ''))
    },
    backgroundCommands: {
      start() {
        return Promise.resolve(backgroundSnapshot('bg-test', 'running', ''))
      },
      status(id) {
        return Promise.resolve(id === 'missing' ? null : backgroundSnapshot(id, 'running', ''))
      },
      kill(id) {
        return Promise.resolve(id === 'missing' ? null : backgroundSnapshot(id, 'killed', ''))
      }
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
    workspaceRoot: workspaceRoot ?? '/workspace',
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

function backgroundSnapshot(
  id: string,
  status: BackgroundCommandSnapshot['status'],
  output: string
): BackgroundCommandSnapshot {
  return {
    id,
    command: 'bash -lc test',
    cwd: '/workspace',
    status,
    startedAtUnixMs: Date.now(),
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
  writeFileSync(join(skillRoot, 'references/api.md'), 'API reference')
  return root
}

function testTurnRef() {
  return {
    actor: {
      agent_uid: 'agent-1',
      session_id: 'session-1'
    },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    llm_turn_id: 'turn-1',
    revision: 0
  }
}
