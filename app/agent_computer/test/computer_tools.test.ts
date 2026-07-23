import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { BUILTIN_SKILLS_ROOT, WORKER_SHARE_ROOT } from '../src/core/agent-home-paths'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  createContainerComputer,
  type CommandFinished,
  type CommandOutputMode,
  type ContainerComputer
} from '../src/tools/computer/computer'
import type { ComputerToolContext } from '../src/tools/computer/context'
import { createComputerTools } from '../src/tools/computer'
import { createPatchTool, createReplaceTool } from '../src/tools/computer/patch-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { createReplyAttachmentTool } from '../src/tools/computer/reply-attachment-tool'

class FakeFinishedCommand implements CommandFinished {
  constructor(
    readonly exitCode: number,
    private readonly stdout = '',
    private readonly stderr = ''
  ) {}

  async output(mode: CommandOutputMode = 'both'): Promise<string> {
    if (mode === 'stdout') return this.stdout
    if (mode === 'stderr') return this.stderr
    return [this.stdout, this.stderr].filter(Boolean).join(this.stdout && this.stderr ? '\n' : '')
  }
}

class FakeComputer implements ContainerComputer {
  files = new Map<string, Buffer>()
  runImpl: ContainerComputer['runCommand'] = async () => new FakeFinishedCommand(0)

  async runCommand(input: Parameters<ContainerComputer['runCommand']>[0]): Promise<CommandFinished> {
    return this.runImpl(input)
  }

  async readFileToBuffer(input: { path: string }): Promise<Buffer | null> {
    return this.files.get(input.path) ?? null
  }

  fs = {
    writeFiles: async (files: Array<{ path: string; content: string | Buffer }>): Promise<void> => {
      for (const file of files) {
        this.files.set(file.path, Buffer.isBuffer(file.content) ? file.content : Buffer.from(file.content))
      }
    }
  }
}

function contextFor(computer: ContainerComputer, overrides: Partial<ComputerToolContext> = {}): ComputerToolContext {
  return {
    executionScopeID: 'scope-1',
    agentHome: '/agents/agent-1',
    workspaceRoot: '/agents/agent-1/sessions/session-1',
    userFilesRoot: '/agents/agent-1/user-files',
    getComputer: async () => computer,
    ...overrides
  }
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

describe('computer tools', () => {
  it('exposes only foreground, stateless computer tools to the main agent', () => {
    const tools = createComputerTools({
      agentUID: 'agent-1',
      conversationID: 'conversation-1',
      agentHome: '/agents/agent-1',
      workspaceRoot: '/agents/agent-1/sessions/session-1',
      userFilesRoot: '/agents/agent-1/user-files'
    })
    const names = tools.map(tool => tool.name)

    expect(names).toEqual(['command', 'read_file', 'replace', 'patch', 'reply_attachment'])
    expect(names.some(name => name.startsWith('browser_'))).toBe(false)
    expect(names).not.toContain('interactive_terminal')
  })

  it('keeps replace and V4A patch schemas disjoint, strict, and bounded', () => {
    const context = contextFor(new FakeComputer())
    const replace = createReplaceTool(context)
    const patch = createPatchTool(context)

    expect(replace.schema.safeParse({ path: 'a.ts', old_string: 'a', new_string: 'b' }).success).toBe(true)
    expect(replace.schema.safeParse({ mode: 'patch', patch: 'private patch body' }).success).toBe(false)
    expect(replace.schema.safeParse({ path: 'a.ts', old_string: 'a', new_string: 'b', surprise: true }).success).toBe(
      false
    )
    expect(
      replace.schema.safeParse({ path: 'a.ts', old_string: 'a'.repeat(96 * 1024 + 1), new_string: 'b' }).success
    ).toBe(false)

    expect(patch.schema.safeParse({ patch: '*** Begin Patch\n*** End Patch' }).success).toBe(true)
    expect(patch.schema.safeParse({ path: 'a.ts', old_string: 'a', new_string: 'b' }).success).toBe(false)
    expect(patch.schema.safeParse({ patch: 'x'.repeat(192 * 1024 + 1) }).success).toBe(false)
  })

  it('describes file and command work without exposing detailed parameters', () => {
    const computer = new FakeComputer()
    const context = contextFor(computer)
    const readFile = createReadFileTool(context)
    const replace = createReplaceTool(context)
    const patch = createPatchTool(context)
    const attachment = createReplyAttachmentTool(context)
    const command = createCommandTool(context)

    expect(
      readFile.describeActivity(readFile.schema.parse({ path: '/agents/agent-1/sessions/session-1/app.ts' }))
    ).toContain('session-1/app.ts')
    expect(
      replace.describeActivity(
        replace.schema.parse({
          path: '/agents/agent-1/sessions/session-1/app.ts',
          old_string: 'before',
          new_string: 'after'
        })
      )
    ).toContain('session-1/app.ts')
    const patchBodySummary = patch.describeActivity(patch.schema.parse({ patch: 'private patch body' }))
    expect(patchBodySummary).toBeTruthy()
    expect(patchBodySummary).not.toContain('private patch body')
    const attachmentSummary = attachment.describeActivity(
      attachment.schema.parse({ path: '/agents/agent-1/user-files/reports/weekly.pdf', name: 'private-name.pdf' })
    )
    expect(attachmentSummary).toContain('reports/weekly.pdf')
    expect(attachmentSummary).not.toContain('private-name')

    const commandSummaries = [
      command.describeActivity(
        command.schema.parse({
          command: 'source /agents/agent-1/private.env && mix test test/secret_test.exs --seed 123',
          env: { API_TOKEN: 'do-not-leak' }
        })
      ),
      command.describeActivity(command.schema.parse({ command: 'rg -n "private query" /agents/agent-1 --hidden' })),
      command.describeActivity(command.schema.parse({ command: 'git diff -- app/private.ex' })),
      command.describeActivity(
        command.schema.parse({ command: '/agents/agent-1/private/run-secret --token do-not-leak' })
      ),
      command.describeActivity(command.schema.parse({ command: 'echo "rg private query"' }))
    ]

    expect(commandSummaries).toEqual([
      expect.stringContaining('mix test'),
      expect.stringContaining('rg'),
      expect.stringContaining('git diff'),
      expect.stringContaining('run-secret'),
      expect.stringContaining('echo')
    ])
    expect(commandSummaries.join(' ')).not.toContain('private')
    expect(commandSummaries.join(' ')).not.toContain('do-not-leak')
  })

  it('adds duration and expected nonzero exit-code notes to command output', async () => {
    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(1, '')
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { command: 'rg does-not-exist' })
    const text = textOf(result)

    expect(text).toContain('exit_code=1')
    expect(text).toContain('duration=')
    expect(text).toContain('exit_code_note: rg exit 1 = no matches found (not an error)')
  })

  it('records reply attachments only for files under the Agent user-files directory', async () => {
    const computer = new FakeComputer()
    computer.files.set('/agents/agent-1/user-files/report.txt', Buffer.from('report'))
    const tool = createReplyAttachmentTool(contextFor(computer))

    const result = await tool.execute('call-reply-attachment', { path: '/agents/agent-1/user-files/report.txt' })

    expect(result.details.attachments).toEqual([
      {
        agent_computer_path: '/agents/agent-1/user-files/report.txt',
        user_files_relative_path: 'report.txt',
        name: 'report.txt',
        size: 6
      }
    ])
  })

  it('rejects reply attachment paths that normalize outside Agent user-files', async () => {
    const computer = new FakeComputer()
    computer.files.set('/agents/agent-1/user-files/../temp/secret.txt', Buffer.from('secret'))
    const tool = createReplyAttachmentTool(contextFor(computer))

    await expect(
      tool.execute('call-reply-attachment-escape', { path: '/agents/agent-1/user-files/../temp/secret.txt' })
    ).rejects.toThrow('reply_attachment only accepts files under /agents/agent-1/user-files')
  })

  it('explains foreground timeout recovery when a command hits exit 124', async () => {
    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(124, 'partial output')
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { command: 'sleep 99', timeout: 1 })
    const text = textOf(result)

    expect(text).toContain('exit_code=124')
    expect(text).toContain('command timed out after 1s')
    expect(text).toContain('create_background_job')
    expect(text).not.toContain('background=true')
    expect(text).toContain('partial output')
  })

  it('rejects removed background command controls at the schema boundary', () => {
    const tool = createCommandTool(contextFor(new FakeComputer()))

    expect(tool.schema.safeParse({ command: 'sleep 1', background: true }).success).toBe(false)
    expect(tool.schema.safeParse({ action: 'status', backgroundID: 'bg-1' }).success).toBe(false)
    expect(tool.schema.safeParse({ action: 'list' }).success).toBe(false)
  })

  it('passes system-root traversal commands through to the sandboxed command runner', async () => {
    const computer = new FakeComputer()
    let runCalled = false
    computer.runImpl = async () => {
      runCalled = true
      return new FakeFinishedCommand(0, 'sandbox result')
    }
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { command: 'find / -maxdepth 2 -type f' })
    const text = textOf(result)

    expect(runCalled).toBe(true)
    expect(result.details.exitCode).toBe(0)
    expect(text).toContain('sandbox result')
    expect(text).not.toContain('Refused command')
  })

  it('prints read_file line ranges and total line counts in visible text', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.txt', Buffer.from('one\ntwo\nthree\n'))
    const tool = createReadFileTool(contextFor(computer))

    const page = await tool.execute('call-1', { path: 'demo.txt', limit: 2 })
    expect(textOf(page)).toContain('... [showing lines 1-2 of 3')
    expect(textOf(page)).toContain('continue with offset=3')

    const full = await tool.execute('call-2', { path: 'demo.txt', limit: 10 })
    expect(textOf(full)).toContain('[3 lines total]')
  })

  it('shows closest line matches when replace cannot find old_string', async () => {
    const computer = new FakeComputer()
    computer.files.set(
      'demo.ts',
      Buffer.from(
        ['function run() {', '  const result = await computer.runCommand(input)', '  return result', '}'].join('\n')
      )
    )
    const tool = createReplaceTool(contextFor(computer))

    await expect(
      tool.execute('call-1', {
        path: 'demo.ts',
        old_string: '  const reslt = await computer.runCommand(input)',
        new_string: '  const result = await computer.runCommand(nextInput)'
      })
    ).rejects.toThrow(/Did you mean one of these sections\?[\s\S]*2\|  const result/)
  })

  it('escalates repeated patch match failures for the same path', async () => {
    const computer = new FakeComputer()
    computer.files.set('repeat.ts', Buffer.from('const actual = 1\n'))
    const tool = createReplaceTool(contextFor(computer))

    let lastError: unknown
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        await tool.execute('call-1', {
          path: 'repeat.ts',
          old_string: 'const missing = 1',
          new_string: 'const actual = 2'
        })
      } catch (error) {
        lastError = error
      }
    }

    expect(lastError).toBeInstanceOf(Error)
    expect((lastError as Error).message).toContain('Repeated patch failures for repeat.ts')
    expect((lastError as Error).message).toContain('Re-read the file with read_file')
  })

  it('uses Unicode punctuation normalization for unique single-line replacements', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.ts', Buffer.from('const title = “Hello”;\n'))
    const tool = createReplaceTool(contextFor(computer))

    const result = await tool.execute('call-1', {
      path: 'demo.ts',
      old_string: 'const title = "Hello";',
      new_string: 'const title = "Hi";'
    })

    expect(textOf(result)).toContain('Patched demo.ts (1 replacement).')
    expect(computer.files.get('demo.ts')?.toString('utf-8')).toBe('const title = "Hi";\n')
  })

  it('creates a missing file in replace mode when old_string is empty', async () => {
    const computer = new FakeComputer()
    const tool = createReplaceTool(contextFor(computer))

    const result = await tool.execute('call-1', {
      path: 'created.txt',
      old_string: '',
      new_string: 'one\ntwo\n'
    })

    expect(textOf(result)).toContain('Created created.txt.')
    expect(textOf(result)).toContain('--- a/created.txt')
    expect(computer.files.get('created.txt')?.toString('utf-8')).toBe('one\ntwo\n')
  })

  it('applies V4A hunks in cursor order without requiring global uniqueness', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.txt', Buffer.from('same\nold\nsame\nold\n'))
    const tool = createPatchTool(contextFor(computer))

    await tool.execute('call-1', {
      patch: [
        '*** Begin Patch',
        '*** Update File: demo.txt',
        '@@',
        ' same',
        '-old',
        '+new',
        '@@',
        ' same',
        '-old',
        '+new2',
        '*** End Patch'
      ].join('\n')
    })

    expect(computer.files.get('demo.txt')?.toString('utf-8')).toBe('same\nnew\nsame\nnew2\n')
  })

  it('uses @@ context as a V4A cursor anchor', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.txt', Buffer.from('old\ntarget\nold\n'))
    const tool = createPatchTool(contextFor(computer))

    await tool.execute('call-1', {
      patch: ['*** Begin Patch', '*** Update File: demo.txt', '@@ target', '-old', '+new', '*** End Patch'].join('\n')
    })

    expect(computer.files.get('demo.txt')?.toString('utf-8')).toBe('old\ntarget\nnew\n')
  })

  it('honors V4A End of File constraints', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.txt', Buffer.from('old\nmiddle\nold\n'))
    const tool = createPatchTool(contextFor(computer))

    await tool.execute('call-1', {
      patch: [
        '*** Begin Patch',
        '*** Update File: demo.txt',
        '@@',
        '-old',
        '+new',
        '*** End of File',
        '*** End Patch'
      ].join('\n')
    })

    expect(computer.files.get('demo.txt')?.toString('utf-8')).toBe('old\nmiddle\nnew\n')
  })

  it('lets the current bubblewrap view decide which absolute paths file tools can use', async () => {
    const agentHome = mkdtempSync('/agents/ankole-computer-paths-')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    const sharePath = join(WORKER_SHARE_ROOT, `ankole-computer-paths-${process.pid}`)
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(sharePath, 'before\n')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const context = {
        executionScopeID: 'scope-bubblewrap-paths',
        agentHome,
        workspaceRoot,
        userFilesRoot: join(agentHome, 'user-files'),
        getComputer: async () => computer
      }
      const tool = createReplaceTool(context)
      const readTool = createReadFileTool(context)

      await tool.execute('call-1', {
        path: sharePath,
        old_string: 'before',
        new_string: 'after'
      })

      expect(readFileSync(sharePath, 'utf8')).toBe('after\n')
      const builtinSkill = await readTool.execute('call-2', {
        path: join(BUILTIN_SKILLS_ROOT, 'skills', 'nano-pdf', 'SKILL.md'),
        limit: 20
      })
      expect(textOf(builtinSkill)).toContain('name: nano-pdf')
      await expect(
        computer.fs.writeFiles([{ path: '/usr/ankole-file-tool-write-probe', content: 'blocked' }])
      ).rejects.toThrow('write file failed')
    } finally {
      rmSync(sharePath, { force: true })
      rmSync(agentHome, { recursive: true, force: true })
    }
  })

  it('keeps relative and home-relative file tool paths', async () => {
    const agentHome = mkdtempSync('/agents/ankole-computer-relative-paths-')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    const userFilesRoot = join(agentHome, 'user-files')
    mkdirSync(workspaceRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    writeFileSync(join(workspaceRoot, 'workspace.txt'), 'workspace')
    writeFileSync(join(userFilesRoot, 'allowed.txt'), 'allowed')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      expect(await computer.readFileToBuffer({ path: 'workspace.txt' })).toEqual(Buffer.from('workspace'))
      expect(await computer.readFileToBuffer({ path: '~/user-files/allowed.txt' })).toEqual(Buffer.from('allowed'))
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })
})
