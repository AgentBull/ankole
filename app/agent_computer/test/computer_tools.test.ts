import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { mkdirAgentSync } from '../src/common/agent-user'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  createContainerComputer,
  type CommandFinished,
  type ContainerComputer,
  type ReadFileWindow
} from '../src/tools/computer/computer'
import { type CommandOutputMode } from '../src/tools/computer/commands'
import type { ComputerToolContext } from '../src/tools/computer/context'
import { createComputerTools } from '../src/tools/computer'
import { createApplyPatchTool } from '../src/tools/computer/apply-patch-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { FakeDrive } from './support/fake-drive'
import { workerToolDeclarations, workerToolsPath } from '../scripts/export-worker-tools'
import { computerToolsForContext } from '../src/tools/computer'

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

  async readFileBytes(input: { path: string; maxBytes: number }): Promise<{ bytes: Buffer } | { size: number } | null> {
    const buffer = this.files.get(input.path)
    if (!buffer) return null
    return buffer.byteLength > input.maxBytes ? { size: buffer.byteLength } : { bytes: buffer }
  }

  async readFileWindow(input: { path: string; offset: number; limit: number }): Promise<ReadFileWindow | null> {
    const buffer = this.files.get(input.path) ?? null
    if (!buffer) return null
    const lines = buffer.toString('utf8').split('\n')
    if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
    return {
      sniff: buffer.subarray(0, 8192),
      totalLines: lines.length,
      lines: lines.slice(input.offset - 1, input.offset - 1 + input.limit)
    }
  }
}

function contextFor(computer: ContainerComputer, overrides: Partial<ComputerToolContext> = {}): ComputerToolContext {
  return {
    agentHome: '/agents/agent-1',
    workspaceRoot: '/agents/agent-1/sessions/session-1',
    drive: new FakeDrive('/agents/agent-1').drive(),
    computer,
    ...overrides
  }
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

describe('computer tools', () => {
  it('pins schemas and safe replay declarations to the control-plane catalog (G3, G4)', () => {
    const declarations = workerToolDeclarations(computerToolsForContext(contextFor(new FakeComputer())))
    expect(declarations).toEqual(JSON.parse(readFileSync(workerToolsPath, 'utf8')))
  })

  it('exposes only foreground, stateless computer tools to the main agent', () => {
    const tools = createComputerTools({
      agentHome: '/agents/agent-1',
      workspaceRoot: '/agents/agent-1/sessions/session-1',
      drive: new FakeDrive('/agents/agent-1').drive()
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
    const command = createCommandTool(context)

    expect(
      readFile.describeActivity(readFile.schema.parse({ path: '/agents/agent-1/sessions/session-1/app.ts' }))
    ).toEqual({
      key: 'signals_gateway.reply.activity.file_read_target',
      bindings: { path: 'session-1/app.ts' }
    })
    const patchBodySummary = applyPatch.describeActivity(applyPatch.schema.parse('private patch body'))
    expect(patchBodySummary).toEqual({ key: 'signals_gateway.reply.activity.file_update' })
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

  it('passes system-root traversal commands through to the command runner', async () => {
    const computer = new FakeComputer()
    let runCalled = false
    computer.runImpl = async () => {
      runCalled = true
      return new FakeFinishedCommand(0, 'command result')
    }
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { command: 'find / -maxdepth 2 -type f' })
    const text = textOf(result)

    expect(runCalled).toBe(true)
    expect(result.details.exitCode).toBe(0)
    expect(text).toContain('command result')
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

  it('returns an image file as an image part with a caption', async () => {
    const computer = new FakeComputer()
    // The Worker recognizes the format by its signature; the control plane decodes the pixels.
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)])
    computer.files.set('chart.png', png)
    const tool = createReadFileTool(contextFor(computer))

    const result = await tool.execute('call-1', { path: 'chart.png' })

    expect(result.content).toEqual([
      { type: 'text', text: `Image file: chart.png (image/png, ${png.byteLength} bytes)` },
      { type: 'image', image: png, mimeType: 'image/png' }
    ])
    expect(result.details).toEqual({ path: 'chart.png', found: true, totalLines: 0, truncated: false })
  })

  it('names the size limit for a large image and keeps other binaries as text', async () => {
    const computer = new FakeComputer()
    const header = Buffer.from([0xff, 0xd8, 0xff, 0xe0])
    computer.files.set('photo.jpg', Buffer.concat([header, Buffer.alloc(8 * 1024 * 1024)]))
    computer.files.set('report.pdf', Buffer.concat([Buffer.from('%PDF-1.7\n'), Buffer.alloc(16)]))
    computer.files.set('notes.txt', Buffer.from('BMW and BMX notes\n'))
    const tool = createReadFileTool(contextFor(computer))

    expect(textOf(await tool.execute('call-1', { path: 'photo.jpg' }))).toContain(
      'Image is too large to view: photo.jpg'
    )
    expect(textOf(await tool.execute('call-2', { path: 'report.pdf' }))).toContain('convert it to PNG first')
    expect(textOf(await tool.execute('call-3', { path: 'notes.txt' }))).toContain('1|BMW and BMX notes')
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

  it('reads whole files on the container computer within a byte limit', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-read-file-bytes-'))
    mkdirAgentSync(agentHome, 0o700)
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirSync(workspaceRoot, { recursive: true })
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x0a, 0xff])
    writeFileSync(join(workspaceRoot, 'chart.png'), bytes)

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      expect(await computer.readFileBytes({ path: 'chart.png', maxBytes: 1024 })).toEqual({ bytes })
      expect(await computer.readFileBytes({ path: 'chart.png', maxBytes: 4 })).toEqual({ size: bytes.byteLength })
      expect(await computer.readFileBytes({ path: 'missing.png', maxBytes: 1024 })).toBeNull()
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })

  it("reads absolute paths outside the Agent Home on the Agent's own computer", async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-computer-paths-'))
    mkdirAgentSync(root, 0o700)
    const agentHome = join(root, 'agent')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    const sharePath = join(root, 'shared.txt')
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(sharePath, 'before\n')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const context = contextFor(computer, { agentHome, workspaceRoot })
      const readTool = createReadFileTool(context)

      const sharedFile = await readTool.execute('call-1', { path: sharePath })
      expect(textOf(sharedFile)).toContain('before')
      expect(readFileSync(sharePath, 'utf8')).toBe('before\n')
      const builtinSkill = await readTool.execute('call-2', {
        path: join(import.meta.dir, '..', '..', 'library', 'skills', 'pdf', 'SKILL.md'),
        limit: 20
      })
      expect(textOf(builtinSkill)).toContain('name: pdf')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps the model-visible truncation contract for multi-megabyte command output', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-bounded-output-'))
    mkdirAgentSync(agentHome, 0o700)
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirSync(workspaceRoot, { recursive: true })
    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const tool = createCommandTool(contextFor(computer, { agentHome, workspaceRoot }))

      const result = await tool.execute('call-huge-output', {
        command: 'yes 0123456789abcdef | head -c 3000000; echo; echo TAIL_SENTINEL'
      })
      const text = textOf(result)

      expect(result.details.exitCode).toBe(0)
      expect(text).toContain('exit_code=0')
      expect(text).toContain('... [output truncated —')
      expect(text).toContain('TAIL_SENTINEL')
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  }, 30000)

  it('reads a deep window of a large file with exact numbering, totals, and line clipping', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-read-window-'))
    mkdirAgentSync(agentHome, 0o700)
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirSync(workspaceRoot, { recursive: true })
    const totalLines = 60000
    const content = Array.from({ length: totalLines }, (_, index) =>
      index + 1 === 59991 ? 'L'.repeat(10000) : `line-${index + 1}`
    ).join('\n')
    writeFileSync(join(workspaceRoot, 'big.txt'), `${content}\n`)
    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const tool = createReadFileTool(contextFor(computer, { agentHome, workspaceRoot }))

      const page = await tool.execute('call-deep-window', { path: 'big.txt', offset: 59990, limit: 5 })
      const text = textOf(page)

      expect(page.details.totalLines).toBe(totalLines)
      expect(text).toContain('59990|line-59990')
      expect(text).toContain(`59991|${'L'.repeat(2000)}... [line truncated]`)
      expect(text).toContain('59994|line-59994')
      expect(text).toContain('... [showing lines 59990-59994 of 60000 — continue with offset=59995] ...')
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  }, 30000)

  it('kills a TERM-immune command after the timeout and explains the budget', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-timeout-kill-'))
    mkdirAgentSync(agentHome, 0o700)
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirSync(workspaceRoot, { recursive: true })
    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const tool = createCommandTool(contextFor(computer, { agentHome, workspaceRoot }))

      const result = await tool.execute('call-term-immune', {
        command: "trap '' TERM; while :; do :; done",
        timeout: 1
      })
      const text = textOf(result)

      expect(result.details.exitCode).toBe(137)
      expect(text).toContain('exit_code=137')
      expect(text).toContain('command timed out after 1s')
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  }, 30000)

  it('keeps relative and home-relative file tool paths', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-computer-relative-paths-'))
    mkdirAgentSync(agentHome, 0o700)
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    const notesRoot = join(agentHome, 'notes')
    mkdirSync(workspaceRoot, { recursive: true })
    mkdirSync(notesRoot, { recursive: true })
    writeFileSync(join(workspaceRoot, 'workspace.txt'), 'workspace')
    writeFileSync(join(notesRoot, 'allowed.txt'), 'allowed')

    try {
      const computer = createContainerComputer(agentHome, workspaceRoot)
      expect((await computer.readFileWindow({ path: 'workspace.txt', offset: 1, limit: 10 }))?.lines).toEqual([
        'workspace'
      ])
      expect((await computer.readFileWindow({ path: '~/notes/allowed.txt', offset: 1, limit: 10 }))?.lines).toEqual([
        'allowed'
      ])
      expect(await computer.readFileWindow({ path: 'missing.txt', offset: 1, limit: 10 })).toBeNull()
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })
})
