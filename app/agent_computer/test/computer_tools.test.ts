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
import { createApplyPatchTool } from '../src/tools/computer/apply-patch-tool'
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
      agentHome: '/agents/agent-1',
      workspaceRoot: '/agents/agent-1/sessions/session-1',
      userFilesRoot: '/agents/agent-1/user-files'
    })
    const names = tools.map(tool => tool.name)

    expect(names.some(name => name.startsWith('browser_'))).toBe(false)
    expect(names).not.toContain('interactive_terminal')
  })

  it('exposes the Codex freeform apply_patch contract', () => {
    const context = contextFor(new FakeComputer())
    const applyPatch = createApplyPatchTool(context)

    expect(applyPatch.schema.safeParse('*** Begin Patch\n*** Delete File: a.ts\n*** End Patch\n').success).toBe(true)
    expect(applyPatch.schema.safeParse({ patch: 'private patch body' }).success).toBe(false)
    expect(applyPatch.schema.safeParse('x'.repeat(256 * 1024 + 1)).success).toBe(false)
    expect(applyPatch.inputFormat).toEqual({
      type: 'grammar',
      syntax: 'lark',
      definition: expect.stringContaining('start: begin_patch hunk+ end_patch')
    })
  })

  it('describes file and command work without exposing detailed parameters', () => {
    const computer = new FakeComputer()
    const context = contextFor(computer)
    const readFile = createReadFileTool(context)
    const applyPatch = createApplyPatchTool(context)
    const attachment = createReplyAttachmentTool(context)
    const command = createCommandTool(context)

    expect(
      readFile.describeActivity(readFile.schema.parse({ path: '/agents/agent-1/sessions/session-1/app.ts' }))
    ).toEqual({
      key: 'signals_gateway.reply.activity.file_read_target',
      bindings: { path: 'session-1/app.ts' }
    })
    const patchBodySummary = applyPatch.describeActivity(applyPatch.schema.parse('private patch body'))
    expect(patchBodySummary).toEqual({ key: 'signals_gateway.reply.activity.file_update' })
    const attachmentSummary = attachment.describeActivity(
      attachment.schema.parse({ path: '/agents/agent-1/user-files/reports/weekly.pdf', name: 'private-name.pdf' })
    )
    expect(attachmentSummary).toEqual({
      key: 'signals_gateway.reply.activity.attachment_prepare_target',
      bindings: { path: 'reports/weekly.pdf' }
    })

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
      { key: 'signals_gateway.reply.activity.command_test_family', bindings: { family: 'mix test' } },
      { key: 'signals_gateway.reply.activity.command_search_code_family', bindings: { family: 'rg' } },
      { key: 'signals_gateway.reply.activity.command_check_changes_family', bindings: { family: 'git diff' } },
      { key: 'signals_gateway.reply.activity.command_execute_family', bindings: { family: 'run-secret' } },
      { key: 'signals_gateway.reply.activity.command_execute_family', bindings: { family: 'echo' } }
    ])
    expect(JSON.stringify(commandSummaries)).not.toContain('private')
    expect(JSON.stringify(commandSummaries)).not.toContain('do-not-leak')
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

    expect(result.details.delivery_state).toBe('queued')
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

  it('passes the raw patch to the native apply_patch command', async () => {
    const computer = new FakeComputer()
    const calls: Array<Parameters<ContainerComputer['runCommand']>[0]> = []
    computer.runImpl = async input => {
      calls.push(input)
      return new FakeFinishedCommand(0, 'Done!')
    }
    const tool = createApplyPatchTool(contextFor(computer))
    const patch = '*** Begin Patch\n*** Add File: demo.txt\n+hello\n*** End Patch\n'

    const result = await tool.execute('call-1', patch)

    expect(calls).toEqual([
      {
        cmd: 'apply_patch',
        cwd: '/agents/agent-1/sessions/session-1',
        stdin: patch,
        signal: undefined
      }
    ])
    expect(textOf(result)).toBe('Done!')
    expect(result.details.exitCode).toBe(0)
  })

  it('returns a stable success message when native apply_patch is silent', async () => {
    const tool = createApplyPatchTool(contextFor(new FakeComputer()))

    const result = await tool.execute('call-1', '*** Begin Patch\n*** Delete File: demo.txt\n*** End Patch\n')

    expect(textOf(result)).toBe('Done!')
  })

  it('returns the native apply_patch failure to the model', async () => {
    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(1, '', 'Invalid Context 0')
    const tool = createApplyPatchTool(contextFor(computer))

    await expect(tool.execute('call-1', '*** Begin Patch\n*** Delete File: demo.txt\n*** End Patch\n')).rejects.toThrow(
      'Invalid Context 0'
    )
  })

  it('edits files through the native apply_patch binary inside bubblewrap', async () => {
    const agentHome = mkdtempSync('/agents/ankole-native-apply-patch-')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(join(workspaceRoot, 'report.md'), 'old\n')
    writeFileSync(join(workspaceRoot, 'stale.md'), 'remove\n')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const tool = createApplyPatchTool(
        contextFor(computer, {
          agentHome,
          workspaceRoot,
          userFilesRoot: join(agentHome, 'user-files')
        })
      )

      await tool.execute(
        'call-native-apply-patch',
        [
          '*** Begin Patch',
          '*** Update File: report.md',
          '@@',
          '-old',
          '+new',
          '*** Add File: created.md',
          '+created',
          '*** Delete File: stale.md',
          '*** End Patch',
          ''
        ].join('\n')
      )

      expect(readFileSync(join(workspaceRoot, 'report.md'), 'utf8')).toBe('new\n')
      expect(readFileSync(join(workspaceRoot, 'created.md'), 'utf8')).toBe('created\n')
      expect(() => readFileSync(join(workspaceRoot, 'stale.md'), 'utf8')).toThrow()
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })

  it('lets the current bubblewrap view decide which absolute paths filesystem tools can use', async () => {
    const agentHome = mkdtempSync('/agents/ankole-computer-paths-')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    const sharePath = join(WORKER_SHARE_ROOT, `ankole-computer-paths-${process.pid}`)
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(sharePath, 'before\n')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const context = {
        agentHome,
        workspaceRoot,
        userFilesRoot: join(agentHome, 'user-files'),
        getComputer: async () => computer
      }
      const readTool = createReadFileTool(context)

      const sharedFile = await readTool.execute('call-1', { path: sharePath })
      expect(textOf(sharedFile)).toContain('before')
      expect(readFileSync(sharePath, 'utf8')).toBe('before\n')
      const builtinSkill = await readTool.execute('call-2', {
        path: join(BUILTIN_SKILLS_ROOT, 'skills', 'pdf', 'SKILL.md'),
        limit: 20
      })
      expect(textOf(builtinSkill)).toContain('name: pdf')
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
