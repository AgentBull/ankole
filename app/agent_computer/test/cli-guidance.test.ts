import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { emitFirstUseGuidance, readContextGenerationFile, writeContextGenerationFile } from '../src/cli/cli-guidance'
import { startRunCLIBridges } from '../src/cli/run-cli-bridges'
import { CLI_CONTEXT_FILE_ENV, CLI_LEDGER_DIR_ENV } from '../src/core/execution/turn_runtime_env'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { FakeDrive } from './support/fake-drive'

describe('CLI context-epoch first-use guidance and stdout EPIPE guard', () => {
  it('keeps stdout pure JSON, emits first-use guidance once per (contextId, commandKey) on stderr, and re-emits after context rotation', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-cli-guidance-'))
    const turn = { session: { session_id: 'conversation:guid' }, signal_id: 'signal-guid' }
    const rpc = (async (method: string) => {
      if (method === 'webhook.endpoint.list') {
        return create(JSONPassthroughResponseSchema, {
          bodyJson: jsonBytes({ endpoints: [{ id: 'wh_1' }, { id: 'wh_2' }] })
        })
      }
      if (method === 'pod.read') {
        return create(JSONPassthroughResponseSchema, {
          bodyJson: jsonBytes({ result: { pages: [] } })
        })
      }
      throw new Error(`Unexpected RPC: ${method}`)
    }) as unknown as RPCRequester

    const bridges = startRunCLIBridges({
      drive: new FakeDrive(root).drive(),
      rpc,
      turn,
      workspaceRoot: root,
      agentUid: 'agent-guidance-1',
      initialContextId: 'conv-1:cmp:root',
      shareRoot: root
    })

    try {
      const driveEntry = join(import.meta.dir, '../src/cli/drive/drive-cli.ts')
      const webhookEntry = join(import.meta.dir, '../src/cli/webhooks/webhook-cli.ts')
      const childEnv = { ...process.env, ...bridges.env }

      // Call 1 (`ankole-files`): stdout is pure JSON, stderr carries first-use guidance
      const run1 = Bun.spawn([process.execPath, driveEntry, 'list'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [out1, err1, exit1] = await Promise.all([
        new Response(run1.stdout).text(),
        new Response(run1.stderr).text(),
        run1.exited
      ])
      expect(exit1).toBe(0)
      expect(JSON.parse(out1)).toBeObject()
      expect(err1).toContain('[ankole-cli first-use note: ankole-files]')
      expect(err1.trim().split('\n').length).toBeLessThanOrEqual(13)

      // Call 2 (`ankole-files`, same contextId): stderr is empty, stdout remains pure JSON
      const run2 = Bun.spawn([process.execPath, driveEntry, 'list'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [out2, err2, exit2] = await Promise.all([
        new Response(run2.stdout).text(),
        new Response(run2.stderr).text(),
        run2.exited
      ])
      expect(exit2).toBe(0)
      expect(JSON.parse(out2)).toBeObject()
      expect(err2).toBe('')

      // Different commandKey (`webhook-cli`) in the same contextId still gets its own note once
      const whRun1 = Bun.spawn([process.execPath, webhookEntry, 'list'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [whOut1, whErr1, whExit1] = await Promise.all([
        new Response(whRun1.stdout).text(),
        new Response(whRun1.stderr).text(),
        whRun1.exited
      ])
      expect(whExit1).toBe(0)
      expect(JSON.parse(whOut1)).toEqual({ endpoints: [{ id: 'wh_1' }, { id: 'wh_2' }] })
      expect(whErr1).toContain('[ankole-cli first-use note: webhook-cli]')

      // Rotate contextId (simulating compaction checkpoint or cold-wake recycle) -> re-emits once!
      bridges.updateContextId('conv-1:cmp:chk_02')

      const run3 = Bun.spawn([process.execPath, driveEntry, 'list'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [out3, err3, exit3] = await Promise.all([
        new Response(run3.stdout).text(),
        new Response(run3.stderr).text(),
        run3.exited
      ])
      expect(exit3).toBe(0)
      expect(JSON.parse(out3)).toBeObject()
      expect(err3).toContain('[ankole-cli first-use note: ankole-files]')

      // Running `--help` in a new epoch marks help seen so the next command skips duplicate guidance
      bridges.updateContextId('conv-1:cmp:chk_03')

      const helpRun = Bun.spawn([process.execPath, driveEntry, '--help'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [helpOut, helpErr, helpExit] = await Promise.all([
        new Response(helpRun.stdout).text(),
        new Response(helpRun.stderr).text(),
        helpRun.exited
      ])
      expect(helpExit).toBe(0)
      expect(helpOut).toContain('ankole-files')
      expect(helpErr).toBe('')

      const afterHelp = Bun.spawn([process.execPath, driveEntry, 'list'], {
        env: childEnv,
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [afterOut, afterErr, afterExit] = await Promise.all([
        new Response(afterHelp.stdout).text(),
        new Response(afterHelp.stderr).text(),
        afterHelp.exited
      ])
      expect(afterExit).toBe(0)
      expect(JSON.parse(afterOut)).toBeObject()
      expect(afterErr).toBe('')
    } finally {
      bridges.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects symlinked context files via O_NOFOLLOW and degrades gracefully when ledger path is unwritable', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-cli-sec-'))
    try {
      const realFile = writeContextGenerationFile(root, 'conv-sec:cmp:root')
      expect(readContextGenerationFile(realFile)).toBe('conv-sec:cmp:root')

      const linkPath = join(root, 'symlink-context.json')
      symlinkSync(realFile, linkPath)
      expect(readContextGenerationFile(linkPath)).toBeUndefined()

      // Point CLI_LEDGER_DIR at a regular file so mkdir/sqlite open fails -> degrades to attach without throwing
      const blockingFile = join(root, 'not-a-directory')
      writeFileSync(blockingFile, 'blocked')

      const chunks: string[] = []
      const fakeStderr = {
        write(chunk: string, cb?: (err?: Error | null) => void) {
          chunks.push(String(chunk))
          cb?.(null)
          return true
        }
      } as unknown as NodeJS.WriteStream

      const decision = await emitFirstUseGuidance({
        commandKey: 'ankole-pod',
        guidance: 'Short pod usage note',
        stderr: fakeStderr,
        env: {
          [CLI_CONTEXT_FILE_ENV]: realFile,
          [CLI_LEDGER_DIR_ENV]: blockingFile
        }
      })

      expect(decision).toBe('attach')
      expect(chunks.join('')).toContain('[ankole-cli first-use note: ankole-pod]')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  for (const initialExitCode of [0, 7]) {
    it(`reports broken stdout pipes without a stack and preserves exit code ${initialExitCode || 1}`, async () => {
      const epipeScript = `
      import { installStdoutEpipeGuard } from ${JSON.stringify(join(import.meta.dir, '../src/cli/cli-guidance.ts'))};
      installStdoutEpipeGuard(process.stdout);
      process.exitCode = ${initialExitCode};
      const line = 'x'.repeat(256) + '\\n';
      for (let i = 0; i < 4096; i++) {
        process.stdout.write(\`\${i}:\${line}\`);
      }
    `
      const proc = Bun.spawn(
        ['/bin/bash', '-c', 'set -euo pipefail; "$0" -e "$1" | head -n 5', process.execPath, epipeScript],
        { stdout: 'pipe', stderr: 'pipe' }
      )
      const [stdout, stderr, exit] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited
      ])
      expect(exit).toBe(initialExitCode || 1)
      expect(stdout.trim().split('\n').length).toBe(5)
      expect(stderr).toBe('')
    })
  }
})
