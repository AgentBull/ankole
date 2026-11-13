import { describe, expect, it } from 'bun:test'
import { chmodSync, mkdtempSync, openSync, closeSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { mkdirAgentSync } from '../src/common/agent-user'
import { commandEnv } from '../src/core/execution/command-env'
import { createApplyPatchTool } from '../src/tools/computer/apply-patch-tool'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  createContainerComputer,
  type CommandFinished,
  type ContainerComputer,
  type ReadFileWindow
} from '../src/tools/computer/computer'
import type { CommandOutputMode } from '../src/tools/computer/commands'
import type { ComputerToolContext } from '../src/tools/computer/context'
import {
  PERCEPTUAL_SHIM_DIR,
  planShellCommandShaping,
  shapeCommandOutput
} from '../src/tools/computer/perceptual-shaping'
import { shapeCurlJsonOutput } from '../src/tools/computer/perceptual-shapers'
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
  lastInput?: Parameters<ContainerComputer['runCommand']>[0]
  runImpl: ContainerComputer['runCommand'] = async () => new FakeFinishedCommand(0)

  async runCommand(input: Parameters<ContainerComputer['runCommand']>[0]): Promise<CommandFinished> {
    this.lastInput = input
    return this.runImpl(input)
  }

  async readFileBytes(): Promise<null> {
    return null
  }

  async readFileWindow(): Promise<ReadFileWindow | null> {
    return null
  }
}

function contextFor(computer: ContainerComputer, overrides: Partial<ComputerToolContext> = {}): ComputerToolContext {
  return {
    agentHome: '/agents/agent-1',
    workspaceRoot: '/agents/agent-1/sessions/session-1',
    computer,
    ...overrides
  }
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  return result.content[0]?.text ?? ''
}

describe('Worker silent perceptual CLI shaping', () => {
  it('places the perceptual CLI shim directory ahead of /usr/local/bin in commandEnv', () => {
    const env = commandEnv(undefined, { agentHome: '/agents/agent-1' })
    expect(env.PATH.split(':').slice(0, 4)).toEqual([PERCEPTUAL_SHIM_DIR, '/usr/local/bin', '/usr/bin', '/bin'])
  })

  it('folds verbose passing test output by >60% without anxious truncation disclaimers', async () => {
    const computer = new FakeComputer()
    const verbosePytest = [
      '============================= test session starts ==============================',
      'platform linux -- Python 3.12.7, pytest-8.3.4',
      'collected 180 items',
      ...Array.from(
        { length: 180 },
        (_, index) =>
          `tests/unit/test_service_${index}.py::test_behavior_case_${index} PASSED [${Math.round(((index + 1) / 180) * 100)}%]`
      ),
      '============================== 180 passed in 2.41s =============================='
    ].join('\n')

    computer.runImpl = async () => new FakeFinishedCommand(0, verbosePytest)
    const tool = createCommandTool(contextFor(computer))
    const result = await tool.execute('call-pytest-pass', { command: 'pytest' })
    const text = textOf(result)

    expect(result.details.exitCode).toBe(0)
    expect(result.details.perceptualShaping?.applied).toBe(true)
    expect(result.details.perceptualShaping!.shapedChars).toBeLessThan(verbosePytest.length * 0.2)
    expect(text).toContain('180 passed in 2.41s')
    expect(text).not.toContain('test_service_42.py')
    expect(text).not.toContain('saved to:')
    expect(text).not.toContain('filtered')
    expect(text).not.toContain('truncated')
  })

  it('injects --run and CI=1 for vitest so watch mode never stalls foreground commands', () => {
    const shaped = planShellCommandShaping('cd packages/web && vitest src/button.test.ts')
    expect(shaped.plan.bypassed).toBe(false)
    expect(shaped.command).toBe('cd packages/web && vitest --run src/button.test.ts')
    expect(shaped.envPatch).toEqual({ CI: '1' })
  })

  it('preserves failed test names, assertion diffs, stack frames, and exact exitCode on failure', async () => {
    const computer = new FakeComputer()
    const failingOutput = [
      ...Array.from({ length: 60 }, (_, idx) => `✓ test/ok_${idx}.test.ts > passes [2ms]`),
      'FAIL test/billing.test.ts > computes invoice tax',
      'AssertionError: expected 1080 to equal 1100',
      '  - Expected: 1100',
      '  + Received: 1080',
      '    at Object.<anonymous> (test/billing.test.ts:44:18)',
      '1 fail, 60 pass'
    ].join('\n')

    computer.runImpl = async () => new FakeFinishedCommand(1, failingOutput)
    const tool = createCommandTool(contextFor(computer))
    const result = await tool.execute('call-test-fail', { command: 'bun test' })
    const text = textOf(result)

    expect(result.details.exitCode).toBe(1)
    expect(text).toContain('exit_code=1')
    expect(text).toContain('FAIL test/billing.test.ts > computes invoice tax')
    expect(text).toContain('AssertionError: expected 1080 to equal 1100')
    expect(text).toContain('test/billing.test.ts:44:18')
  })

  it('strips package-manager progress bars and funding chatter on exit 0', () => {
    const plan = planShellCommandShaping('pnpm install')
    const raw = [
      'Progress: resolved 1, reused 0, downloaded 0, added 0',
      'Progress: resolved 145, reused 120, downloaded 25, added 0',
      'Progress: resolved 412, reused 390, downloaded 22, added 412, done',
      'Packages: +85',
      '+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++',
      ...Array.from({ length: 85 }, (_, idx) => `+ @scope/pkg-${idx} 1.2.${idx}`),
      '42 packages are looking for funding',
      '  run `npm fund` for details',
      'Done in 2.8s'
    ].join('\n')

    const { output, metrics } = shapeCommandOutput(plan.plan, { exitCode: 0, output: raw })
    expect(metrics.applied).toBe(true)
    expect(output.length).toBeLessThan(raw.length * 0.25)
    expect(output).toContain('+85 packages')
    expect(output).toContain('Done in 2.8s')
    expect(output).not.toContain('Progress: resolved')
    expect(output).not.toContain('looking for funding')
  })

  it('synthesizes a global unified JSON schema across ALL array elements for >4KB curl payloads', () => {
    const items = Array.from({ length: 120 }, (_, index) => {
      const base: Record<string, unknown> = {
        id: `ord_${1000 + index}`,
        amount_cents: 2500 + index,
        active: true,
        metadata: { region: 'apac', tags: ['priority', ' enterprise '] }
      }
      if (index === 97) {
        base.cancellation_reason = 'customer_requested'
        base.refunded_at = null
      }
      if (index === 115) {
        base.cancellation_reason = null
      }
      return base
    })
    const payload = JSON.stringify({
      ok: true,
      total: 120,
      has_more: true,
      next_cursor: 'cur_next_page_99',
      items
    })
    expect(Buffer.byteLength(payload, 'utf8')).toBeGreaterThan(4_096)

    const shaped = shapeCurlJsonOutput(payload)
    expect(Buffer.byteLength(shaped, 'utf8')).toBeLessThan(Buffer.byteLength(payload, 'utf8') * 0.25)
    expect(shaped).toContain('"next_cursor":"cur_next_page_99"')
    expect(shaped).toContain('"total":120')
    expect(shaped).toContain('(length: 120)')
    // Fields that only appeared on element #97 / #115 MUST be captured as optional & nullable!
    expect(shaped).toContain('"cancellation_reason"?: string | null')
    expect(shaped).toContain('"refunded_at"?: null')
  })

  it('preserves <4KB JSON responses and >4KB HTTP error JSON payloads 100% verbatim', () => {
    const smallPayload = JSON.stringify({ items: [{ id: 1, secret_value: 'exact-123' }] })
    expect(shapeCurlJsonOutput(smallPayload)).toBe(smallPayload)

    const largeErrorPayload = JSON.stringify({
      status: 422,
      error: {
        code: 'validation_failed',
        message: 'Field amount_cents must be positive',
        trace: 'x'.repeat(5_000)
      }
    })
    expect(Buffer.byteLength(largeErrorPayload, 'utf8')).toBeGreaterThan(4_096)
    expect(shapeCurlJsonOutput(largeErrorPayload)).toBe(largeErrorPayload)
  })

  it('automatically bypasses shaping on pipes, redirections, explicit flags, and ANKOLE_RAW=1', () => {
    expect(planShellCommandShaping('curl -s https://api.example.com/items | jq .items[0]').plan).toEqual({
      bypassed: true,
      bypassReason: 'shell_compound_or_redirect'
    })
    expect(planShellCommandShaping('curl -i https://api.example.com/items').plan).toEqual({
      bypassed: true,
      bypassReason: 'explicit_curl_forensic_or_output_flag'
    })
    expect(planShellCommandShaping('pytest -vv tests/').plan).toEqual({
      bypassed: true,
      bypassReason: 'explicit_verbose_or_debug_flag'
    })
    expect(planShellCommandShaping('pytest -s tests/').plan).toEqual({
      bypassed: true,
      bypassReason: 'explicit_verbose_or_debug_flag'
    })
    expect(planShellCommandShaping('git log --merges').plan).toEqual({
      bypassed: true,
      bypassReason: 'explicit_git_log_specificity'
    })
    expect(planShellCommandShaping('git log -n 5').plan).toEqual({
      bypassed: true,
      bypassReason: 'explicit_git_log_specificity'
    })
    expect(planShellCommandShaping('ANKOLE_RAW=1 pytest').plan).toEqual({
      bypassed: true,
      bypassReason: 'env_ankole_raw'
    })
    expect(planShellCommandShaping('pytest', { ANKOLE_PERCEPTUAL_POSTURE: 'exact_data_forensics' }).plan).toEqual({
      bypassed: true,
      bypassReason: 'forensics_posture'
    })

    // Bare git log gets bounded commit count and excludes merge commits.
    const bareGitLog = planShellCommandShaping('git -C /repo log src/index.ts')
    expect(bareGitLog.plan.bypassed).toBe(false)
    expect(bareGitLog.command).toBe('git -C /repo log -n 20 --no-merges --oneline src/index.ts')
  })

  it('folds bare shell cat on large source files while keeping read_file + apply_patch 100% byte-exact', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-perceptual-read-patch-'))
    mkdirAgentSync(root, 0o700)
    const agentHome = join(root, 'agent')
    const workspaceRoot = join(agentHome, 'sessions', 'session-1')
    mkdirAgentSync(workspaceRoot)

    const sourceLines = [
      '/*',
      ' * Copyright (c) 2026 Example Corp.',
      ' * SPDX-License-Identifier: Apache-2.0',
      ' */',
      '',
      '',
      '',
      '',
      '/** Public API docstring that must remain visible even in shell cat. */',
      'export function computeTotal(items: number[]): number {',
      '  // Implementation comment line 1 that apply_patch context will anchor on',
      '  // Implementation comment line 2',
      '  let sum = 0',
      ...Array.from({ length: 65 }, (_, idx) => `  // step comment ${idx}\n  sum += items[${idx}] ?? 0`),
      '  return sum',
      '}',
      ''
    ]
    const rawFileContent = sourceLines.join('\n')
    const targetPath = join(workspaceRoot, 'compute.ts')
    writeFileSync(targetPath, rawFileContent, 'utf8')

    try {
      // 1. Shell `cat compute.ts` folds license banner, 4 blank lines, and `//` comments, keeping `/** ... */`.
      const catPlan = planShellCommandShaping('cat compute.ts')
      const shapedCat = shapeCommandOutput(catPlan.plan, { exitCode: 0, output: rawFileContent })
      expect(shapedCat.metrics.applied).toBe(true)
      expect(shapedCat.output).toContain('/** Public API docstring that must remain visible even in shell cat. */')
      expect(shapedCat.output).not.toContain('SPDX-License-Identifier')
      expect(shapedCat.output).not.toContain('Implementation comment line 1')

      // 2. `read_file` returns 100% byte-exact lines (including license banner, blank lines, and `//` comments).
      const computer = createContainerComputer(agentHome, workspaceRoot)
      const ctx = contextFor(computer, { agentHome, workspaceRoot })
      const readTool = createReadFileTool(ctx)
      const readResult = textOf(await readTool.execute('call-read-1', { path: 'compute.ts', limit: 30 }))

      expect(readResult).toContain('2| * Copyright (c) 2026 Example Corp.')
      expect(readResult).toContain('5|')
      expect(readResult).toContain('6|')
      expect(readResult).toContain('7|')
      expect(readResult).toContain('8|')
      expect(readResult).toContain('11|  // Implementation comment line 1 that apply_patch context will anchor on')

      // 3. `apply_patch` anchoring directly on those exact comments & blank lines succeeds cleanly if binary exists.
      if (Bun.which('apply_patch')) {
        const applyPatchTool = createApplyPatchTool(ctx)
        const patch = [
          '*** Begin Patch',
          '*** Update File: compute.ts',
          '@@',
          ' export function computeTotal(items: number[]): number {',
          '   // Implementation comment line 1 that apply_patch context will anchor on',
          '   // Implementation comment line 2',
          '-  let sum = 0',
          '+  let sum = 10',
          '*** End Patch',
          ''
        ].join('\n')
        const patchResult = await applyPatchTool.execute('call-patch-1', patch)
        expect(patchResult.details.exitCode).toBe(0)
        expect(textOf(patchResult).length).toBeGreaterThan(0)
        expect(readFileSync(targetPath, 'utf8')).toContain('  let sum = 10\n')
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('standalone ankole-cli-shim shapes direct harness calls and bypasses file redirections and ANKOLE_RAW=1', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ankole-cli-shim-test-'))
    const realBinDir = join(dir, 'real-bin')
    const shimDir = join(dir, 'shims')
    mkdirAgentSync(realBinDir)
    mkdirAgentSync(shimDir)

    const payload = JSON.stringify({
      total: 80,
      items: Array.from({ length: 80 }, (_, idx) => ({
        id: idx,
        title: `Item number ${idx} with descriptive text padding`,
        extra: idx === 50 ? 'rare-optional' : undefined
      }))
    })
    const fakeCurlPath = join(realBinDir, 'curl')
    writeFileSync(fakeCurlPath, `#!/usr/bin/env bash\nprintf '%s' '${payload}'\n`)
    chmodSync(fakeCurlPath, 0o755)

    const shimEntry = join(import.meta.dir, '..', 'src', 'cli', 'shim', 'ankole-cli-shim.ts')
    const outFile = join(dir, 'redirected.json')

    try {
      // 1. Direct harness pipe invocation -> shaped into unified JSON schema!
      const direct = Bun.spawnSync([process.execPath, shimEntry, 'curl', 'https://api.example.test/items'], {
        env: {
          ...process.env,
          ANKOLE_SHIM_DIR_OVERRIDE: shimDir,
          ANKOLE_SHIM_DIRECT: '1',
          PATH: `${shimDir}:${realBinDir}:${process.env.PATH}`
        }
      })
      expect(direct.exitCode).toBe(0)
      const directOut = direct.stdout.toString('utf8')
      expect(directOut).toContain('JSON Object unified schema:')
      expect(directOut).toContain('"extra"?: string')

      // 2. Redirected stdout to regular file (`> outFile`) -> 100% raw bytes!
      const fd = openSync(outFile, 'w')
      try {
        const redirected = Bun.spawnSync([process.execPath, shimEntry, 'curl', 'https://api.example.test/items'], {
          stdout: fd,
          env: {
            ...process.env,
            ANKOLE_SHIM_DIR_OVERRIDE: shimDir,
            ANKOLE_SHIM_DIRECT: '1',
            PATH: `${shimDir}:${realBinDir}:${process.env.PATH}`
          }
        })
        expect(redirected.exitCode).toBe(0)
      } finally {
        closeSync(fd)
      }
      expect(readFileSync(outFile, 'utf8')).toBe(payload)

      // 3. ANKOLE_RAW=1 -> 100% raw bytes!
      const rawRun = Bun.spawnSync([process.execPath, shimEntry, 'curl', 'https://api.example.test/items'], {
        env: {
          ...process.env,
          ANKOLE_RAW: '1',
          ANKOLE_SHIM_DIR_OVERRIDE: shimDir,
          ANKOLE_SHIM_DIRECT: '1',
          PATH: `${shimDir}:${realBinDir}:${process.env.PATH}`
        }
      })
      expect(rawRun.exitCode).toBe(0)
      expect(rawRun.stdout.toString('utf8')).toBe(payload)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('container shell shim passes through to the real command when another directory precedes the shim directory in PATH', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ankole-cli-shell-shim-test-'))
    const callerBinDir = join(dir, 'caller-bin')
    const realBinDir = join(dir, 'real-bin')
    const shimDir = join(dir, 'shims')
    mkdirAgentSync(callerBinDir)
    mkdirAgentSync(realBinDir)
    mkdirAgentSync(shimDir)
    const fakeCatPath = join(realBinDir, 'cat')
    writeFileSync(fakeCatPath, '#!/bin/sh\nprintf \'real cat:%s\' "$*"\nexit 3\n')
    chmodSync(fakeCatPath, 0o755)
    symlinkSync(join(import.meta.dir, '..', 'scripts', 'ankole-cli-shim.sh'), join(shimDir, 'cat'))

    try {
      // Codex prepends its own directory, so the shim directory is not the first PATH entry.
      const run = Bun.spawnSync([join(shimDir, 'cat'), 'notes.md'], {
        env: {
          ANKOLE_RAW: '1',
          ANKOLE_SHIM_DIR_OVERRIDE: shimDir,
          PATH: `${callerBinDir}:${shimDir}:${realBinDir}:${shimDir}:/usr/bin:/bin`
        },
        timeout: 5_000
      })
      expect(run.exitCode).toBe(3)
      expect(run.stdout.toString('utf8')).toBe('real cat:notes.md')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('persists raw output log when command shaping collapses large JSON into a short schema', async () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-cmd-log-test-'))
    const rawJson = JSON.stringify({
      total: 1000,
      items: Array.from({ length: 1000 }, (_, idx) => ({
        id: idx,
        title: `Record ${idx} with long text payload so raw JSON exceeds 100 KB while schema stays tiny`
      }))
    })
    expect(rawJson.length).toBeGreaterThan(90_000)

    const computer = new FakeComputer()
    computer.runImpl = async () => new FakeFinishedCommand(0, rawJson)
    const commandTool = createCommandTool(contextFor(computer, { agentHome }))

    try {
      const result = await commandTool.execute('call-curl-json-log', {
        command: 'curl -s https://api.example.test/items'
      })
      expect(result.details.perceptualShaping?.applied).toBe(true)
      expect(result.details.perceptualShaping?.family).toBe('curl_json')
      expect(result.details.outputLogPath).toBeDefined()
      expect(readFileSync(result.details.outputLogPath!, 'utf8')).toBe(rawJson)
      expect(textOf(result)).toContain(`[captured output saved to: ${result.details.outputLogPath}`)
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })
})
