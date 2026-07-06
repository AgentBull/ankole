import { describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createBrowserTools } from '../src/tools/browser/browser-tools'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  createContainerComputer,
  type BackgroundCommandSnapshot,
  type CommandFinished,
  type CommandOutputMode,
  type ComputerToolContext,
  type ContainerComputer
} from '../src/tools/computer/context'
import { createInteractiveTerminalTool } from '../src/tools/computer/interactive-terminal-tool'
import { createPatchTool } from '../src/tools/computer/patch-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'

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
  backgroundStatusSnapshot: BackgroundCommandSnapshot | null = null
  backgroundStartInputs: Array<Parameters<ContainerComputer['backgroundCommands']['start']>[0]> = []
  files = new Map<string, Buffer>()
  runImpl: ContainerComputer['runCommand'] = async () => new FakeFinishedCommand(0)
  terminalCaptureScreen = ''
  terminalSendCalls: Array<{ input?: string; keys?: string[]; enter?: boolean }> = []

  async runCommand(input: Parameters<ContainerComputer['runCommand']>[0]): Promise<CommandFinished> {
    return this.runImpl(input)
  }

  backgroundCommands = {
    start: async (
      input: Parameters<ContainerComputer['backgroundCommands']['start']>[0]
    ): Promise<BackgroundCommandSnapshot> => {
      this.backgroundStartInputs.push(input)
      return backgroundSnapshot('bg-1', async () => '')
    },
    status: async (): Promise<BackgroundCommandSnapshot | null> => this.backgroundStatusSnapshot,
    kill: async (): Promise<BackgroundCommandSnapshot | null> => null,
    list: async (): Promise<BackgroundCommandSnapshot[]> => []
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

  terminals = {
    list: async () => [],
    start: async (name: string) => ({ name, status: 'started' }),
    send: async (name: string, opts: { input?: string; keys?: string[]; enter?: boolean }) => {
      this.terminalSendCalls.push(opts)
      return { name, status: 'sent' }
    },
    capture: async (name: string) => ({ name, screen: this.terminalCaptureScreen }),
    kill: async (name: string) => ({ name, status: 'killed' })
  }
}

function contextFor(computer: ContainerComputer, overrides: Partial<ComputerToolContext> = {}): ComputerToolContext {
  return {
    agentUid: 'agent-1',
    executionScopeId: 'scope-1',
    workspaceRoot: '/workspace',
    getComputer: async () => computer,
    ...overrides
  }
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

function backgroundSnapshot(id: string, output: BackgroundCommandSnapshot['output']): BackgroundCommandSnapshot {
  return {
    id,
    command: 'sleep',
    cwd: '/workspace',
    output,
    startedAtUnixMs: 0,
    status: 'running'
  }
}

let fakeBwrapBinDir: string | undefined

function ensureFakeBwrap(): void {
  if (fakeBwrapBinDir) return

  fakeBwrapBinDir = mkdtempSync(join(tmpdir(), 'ankole-fake-bwrap-'))
  const bwrapPath = join(fakeBwrapBinDir, 'bwrap')
  writeFileSync(
    bwrapPath,
    [
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      'while [[ $# -gt 0 ]]; do',
      '  case "$1" in',
      '    --unshare-all|--share-net|--die-with-parent|--new-session|--clearenv)',
      '      shift',
      '      ;;',
      '    --proc|--dev|--tmpfs|--dir)',
      '      shift 2',
      '      ;;',
      '    --bind|--ro-bind)',
      '      shift 3',
      '      ;;',
      '    --chdir)',
      '      shift 2',
      '      ;;',
      '    --setenv)',
      '      export "$2=$3"',
      '      shift 3',
      '      ;;',
      '    --)',
      '      shift',
      '      break',
      '      ;;',
      '    --*)',
      '      echo "unsupported fake bwrap option: $1" >&2',
      '      exit 2',
      '      ;;',
      '    *)',
      '      break',
      '      ;;',
      '  esac',
      'done',
      'if [[ "${1:-}" == "/bin/sh" && "${2:-}" == "-lc" && "${3:-}" == "test -r /proc/self/status && test -w /tmp" ]]; then',
      '  exit 0',
      'fi',
      'exec "$@"',
      ''
    ].join('\n')
  )
  chmodSync(bwrapPath, 0o755)
  process.env.ANKOLE_BWRAP_PATH = bwrapPath
}

describe('computer tools', () => {
  it('runs browser tools in the worker process without shelling through ankole-browser', async () => {
    const computer = new FakeComputer()
    let runCalled = false
    computer.runImpl = async () => {
      runCalled = true
      throw new Error('browser tool should not shell out')
    }
    const browserDoctor = createBrowserTools(contextFor(computer, { localBrowserIdleTtlMs: 2_700_000 })).find(
      tool => tool.name === 'browser_doctor'
    )

    expect(browserDoctor).toBeTruthy()
    const result = await browserDoctor!.execute('call-browser-doctor', {})

    expect(runCalled).toBe(false)
    expect(textOf(result)).toContain('"backend"')
    expect(textOf(result)).toContain('"local_browser_idle_ttl_ms": 2700000')
  })

  it('adds duration and expected nonzero exit-code notes to command output', async () => {
    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(1, '')
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { action: 'run', command: 'rg does-not-exist' })
    const text = textOf(result)

    expect(text).toContain('exit_code=1')
    expect(text).toContain('duration=')
    expect(text).toContain('exit_code_note: rg exit 1 = no matches found (not an error)')
  })

  it('explains foreground timeout recovery when a command hits exit 124', async () => {
    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(124, 'partial output')
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { action: 'run', command: 'sleep 99', timeout: 1 })
    const text = textOf(result)

    expect(text).toContain('exit_code=124')
    expect(text).toContain('command timed out after 1s')
    expect(text).toContain('background=true')
    expect(text).toContain('action=status')
    expect(text).toContain('partial output')
  })

  it('passes system-root traversal commands through to the sandboxed command runner', async () => {
    const computer = new FakeComputer()
    let runCalled = false
    computer.runImpl = async () => {
      runCalled = true
      return new FakeFinishedCommand(0, 'sandbox result')
    }
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { action: 'run', command: 'find / -maxdepth 2 -type f' })
    const text = textOf(result)

    expect(runCalled).toBe(true)
    expect(result.details.exitCode).toBe(0)
    expect(text).toContain('sandbox result')
    expect(text).not.toContain('Refused command')
  })

  it('polls background status with incremental output', async () => {
    const computer = new FakeComputer()
    computer.backgroundStatusSnapshot = backgroundSnapshot('bg-1', async (_mode, opts) =>
      opts?.incremental ? 'second batch' : 'full output'
    )
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { action: 'status', backgroundId: 'bg-1' })
    const text = textOf(result)

    expect(text).toContain('background_id=bg-1')
    expect(text).toContain('new_output_chars=12')
    expect(text).toContain('second batch')
    expect(text).not.toContain('full output')
  })

  it('keeps background command runs unbounded by default like Hermes', async () => {
    const computer = new FakeComputer()
    const tool = createCommandTool(contextFor(computer))

    await tool.execute('call-1', { action: 'run', command: 'sleep 999', background: true })
    expect(computer.backgroundStartInputs[0]?.timeoutMs).toBeUndefined()

    await tool.execute('call-2', { action: 'run', command: 'sleep 10', background: true, timeout: 7 })
    expect(computer.backgroundStartInputs[1]?.timeoutMs).toBe(7000)
  })

  it('reports when a background status poll has no new output', async () => {
    const computer = new FakeComputer()
    computer.backgroundStatusSnapshot = backgroundSnapshot('bg-1', async () => '')
    const tool = createCommandTool(contextFor(computer))

    const result = await tool.execute('call-1', { action: 'status', backgroundId: 'bg-1' })

    expect(textOf(result)).toContain('[no new output]')
  })

  it('isolates background commands by workspace and execution scope', async () => {
    ensureFakeBwrap()

    const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-bg-owner-'))
    const otherWorkspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-bg-other-'))
    let ownerComputer: ContainerComputer | undefined
    let backgroundId: string | undefined

    try {
      mkdirSync(join(workspaceRoot, 'temp'), { recursive: true })
      mkdirSync(join(otherWorkspaceRoot, 'temp'), { recursive: true })

      ownerComputer = createContainerComputer(workspaceRoot, 'conversation-a')
      const peerConversationComputer = createContainerComputer(workspaceRoot, 'conversation-b')
      const otherWorkspaceComputer = createContainerComputer(otherWorkspaceRoot, 'conversation-a')

      const started = await ownerComputer.backgroundCommands.start({
        cmd: 'bash',
        args: ['-lc', 'sleep 30'],
        timeoutMs: 30_000
      })
      backgroundId = started.id

      expect((await ownerComputer.backgroundCommands.list()).map(command => command.id)).toContain(backgroundId)
      expect(await ownerComputer.backgroundCommands.status(backgroundId)).not.toBeNull()

      expect(await peerConversationComputer.backgroundCommands.list()).toEqual([])
      expect(await peerConversationComputer.backgroundCommands.status(backgroundId)).toBeNull()
      expect(await peerConversationComputer.backgroundCommands.kill(backgroundId)).toBeNull()

      expect(await otherWorkspaceComputer.backgroundCommands.list()).toEqual([])
      expect(await otherWorkspaceComputer.backgroundCommands.status(backgroundId)).toBeNull()
      expect(await otherWorkspaceComputer.backgroundCommands.kill(backgroundId)).toBeNull()

      expect((await ownerComputer.backgroundCommands.kill(backgroundId))?.status).toBe('killed')
      backgroundId = undefined
    } finally {
      if (ownerComputer && backgroundId) await ownerComputer.backgroundCommands.kill(backgroundId)
      rmSync(workspaceRoot, { recursive: true, force: true })
      rmSync(otherWorkspaceRoot, { recursive: true, force: true })
    }
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
    const tool = createPatchTool(contextFor(computer))

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
    const tool = createPatchTool(contextFor(computer))

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
    const tool = createPatchTool(contextFor(computer))

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
    const tool = createPatchTool(contextFor(computer))

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
      mode: 'patch',
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
      mode: 'patch',
      patch: ['*** Begin Patch', '*** Update File: demo.txt', '@@ target', '-old', '+new', '*** End Patch'].join('\n')
    })

    expect(computer.files.get('demo.txt')?.toString('utf-8')).toBe('old\ntarget\nnew\n')
  })

  it('honors V4A End of File constraints', async () => {
    const computer = new FakeComputer()
    computer.files.set('demo.txt', Buffer.from('old\nmiddle\nold\n'))
    const tool = createPatchTool(contextFor(computer))

    await tool.execute('call-1', {
      mode: 'patch',
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

  it('rejects patch writes that escape the real workspace filesystem boundary', async () => {
    const tempRoot = mkdtempSync(join(tmpdir(), 'ankole-patch-boundary-'))
    const workspaceRoot = join(tempRoot, 'workspace')
    const outsidePath = join(tempRoot, 'outside.txt')
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(outsidePath, 'secret\n')

    try {
      const computer = createContainerComputer(workspaceRoot, 'scope-patch-boundary')
      const tool = createPatchTool({
        agentUid: 'agent-1',
        executionScopeId: 'scope-patch-boundary',
        workspaceRoot,
        getComputer: async () => computer
      })

      await expect(
        tool.execute('call-1', {
          path: '/workspace/../outside.txt',
          old_string: 'secret',
          new_string: 'leaked'
        })
      ).rejects.toThrow('path escapes workspace root')

      await expect(
        tool.execute('call-2', {
          path: '../created-outside.txt',
          old_string: '',
          new_string: 'created outside\n'
        })
      ).rejects.toThrow('path escapes workspace root')

      expect(readFileSync(outsidePath, 'utf-8')).toBe('secret\n')
      expect(existsSync(join(tempRoot, 'created-outside.txt'))).toBe(false)
    } finally {
      rmSync(tempRoot, { recursive: true, force: true })
    }
  })

  it('captures the screen after interactive terminal send unless disabled', async () => {
    const computer = new FakeComputer()
    computer.terminalCaptureScreen = 'after send'
    const tool = createInteractiveTerminalTool(contextFor(computer))

    const captured = await tool.execute('call-1', {
      action: 'send',
      session: 'main',
      input: 'Up',
      captureAfterMs: 1,
      captureLines: 12
    })
    expect(JSON.parse(textOf(captured))).toMatchObject({ session: 'main', status: 'sent', screen: 'after send' })
    expect(computer.terminalSendCalls[0]).toEqual({ input: 'Up', keys: [], enter: undefined })

    const statusOnly = await tool.execute('call-2', {
      action: 'send',
      session: 'main',
      keys: ['Enter'],
      captureAfterMs: 0
    })
    expect(JSON.parse(textOf(statusOnly))).toEqual({ session: 'main', status: 'sent' })
  })
})
