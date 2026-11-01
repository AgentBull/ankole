import { chmodSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { mkdirAgentSync } from '../common/agent-user'
import { WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import {
  AUTOMATION_JOB_CLI_SOCKET_ENV,
  CLI_CONTEXT_FILE_ENV,
  CLI_LEDGER_DIR_ENV,
  DRIVE_CLI_SOCKET_ENV,
  POD_CLI_SOCKET_ENV,
  WEBHOOK_CLI_SOCKET_ENV
} from '../core/execution/turn_runtime_env'
import type { SocketLineBridge } from '../core/socket-line-bridge'
import type { Drive } from '../drive/drive'
import { type RPCRequester } from '../lanes/rpc_lane'
import type { JobTurnRef, RunRef } from '../lanes/session_lane'
import { automationJobRPCRequester, startAutomationJobCLIBridge } from './automation-jobs/automation-job-cli-bridge'
import { writeContextGenerationFile } from './cli-guidance'
import { startDriveCLIBridge } from './drive/drive-cli-bridge'
import { startPodCLIBridge } from './pod/pod-cli-bridge'
import { startWebhookCLIBridge, webhookRPCRequester } from './webhooks/webhook-cli-bridge'

/**
 * Starts the drive, Pod, webhook, and Automation Job CLI bridges of one run. `env`
 * holds the socket variable of each bridge plus the Worker-managed context pointer
 * and SQLite ledger path for first-use CLI guidance. If a bridge cannot start, this
 * function closes the bridges that started, so that no listener stays open in
 * the long-running Worker.
 */
export function startRunCLIBridges({
  drive,
  rpc,
  turn,
  workspaceRoot,
  agentUid,
  initialContextId,
  shareRoot = WORKER_SHARE_ROOT
}: {
  drive: Drive
  rpc: RPCRequester
  turn: JobTurnRef | RunRef
  workspaceRoot: string
  agentUid?: string
  initialContextId?: string
  shareRoot?: string
}): {
  env: Record<string, string>
  close: () => void
  updateContextId: (nextContextId?: string) => void
} {
  const bridges: SocketLineBridge[] = []
  let contextDir: string | undefined

  const close = () => {
    for (const bridge of bridges) bridge.close()
    if (contextDir) {
      try {
        rmSync(contextDir, { recursive: true, force: true })
      } catch {
        // Best-effort cleanup of run context directory.
      }
      contextDir = undefined
    }
  }
  const socketOf = (bridge: SocketLineBridge) => {
    bridges.push(bridge)
    return bridge.socketPath
  }

  try {
    mkdirAgentSync(shareRoot, 0o755)
    contextDir = mkdtempSync(join(shareRoot, 'ankole-cli-ctx-'))
    chmodSync(contextDir, 0o755)

    const ledgerOwner = sanitizePathSegment(agentUid || 'default')
    const ledgerDir = join(shareRoot, 'cli-ledger', ledgerOwner)
    mkdirAgentSync(ledgerDir, 0o700)

    const contextFilePath = join(contextDir, 'context-generation.json')
    const updateContextId = (nextContextId?: string) => {
      if (!contextDir || !nextContextId || !nextContextId.trim()) return
      writeContextGenerationFile(contextDir, nextContextId)
    }

    if (initialContextId && initialContextId.trim()) {
      updateContextId(initialContextId)
    }

    return {
      env: {
        [DRIVE_CLI_SOCKET_ENV]: socketOf(
          startDriveCLIBridge({
            drive,
            workspaceRoot,
            frame: 'job_id' in turn ? { jobTurn: turn } : { run: turn }
          })
        ),
        [POD_CLI_SOCKET_ENV]: socketOf(
          startPodCLIBridge({
            drive,
            rpc,
            frame: 'job_id' in turn ? { jobTurn: turn } : { run: turn }
          })
        ),
        [WEBHOOK_CLI_SOCKET_ENV]: socketOf(
          startWebhookCLIBridge({ requestWebhookRPC: webhookRPCRequester(rpc, turn) })
        ),
        [AUTOMATION_JOB_CLI_SOCKET_ENV]: socketOf(
          startAutomationJobCLIBridge({
            drive,
            requestAutomationJobRPC: automationJobRPCRequester(rpc, turn)
          })
        ),
        [CLI_CONTEXT_FILE_ENV]: contextFilePath,
        [CLI_LEDGER_DIR_ENV]: ledgerDir
      },
      close,
      updateContextId
    }
  } catch (error) {
    close()
    throw error
  }
}

function sanitizePathSegment(value: string): string {
  const cleaned = value.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 128)
  return cleaned.length > 0 ? cleaned : 'default'
}
