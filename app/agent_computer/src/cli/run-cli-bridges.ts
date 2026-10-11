import {
  AUTOMATION_JOB_CLI_SOCKET_ENV,
  DRIVE_CLI_SOCKET_ENV,
  WEBHOOK_CLI_SOCKET_ENV
} from '../core/execution/turn_runtime_env'
import type { SocketLineBridge } from '../core/socket-line-bridge'
import type { Drive } from '../drive/drive'
import type { JobTurnRef, RunRef } from '../lanes/actor_lane'
import { automationJobRPCRequester, webhookRPCRequester, type RPCRequester } from '../lanes/rpc_lane'
import { startAutomationJobCLIBridge } from './automation-jobs/automation-job-cli-bridge'
import { startDriveCLIBridge } from './drive/drive-cli-bridge'
import { startWebhookCLIBridge } from './webhooks/webhook-cli-bridge'

/**
 * Starts the drive, webhook, and Automation Job CLI bridges of one run. `env`
 * holds the socket variable of each bridge. If a bridge cannot start, this
 * function closes the bridges that started, so that no listener stays open in
 * the long-running Worker.
 */
export function startRunCLIBridges({
  drive,
  rpc,
  turn,
  workspaceRoot
}: {
  drive: Drive
  rpc: RPCRequester
  turn: JobTurnRef | RunRef
  workspaceRoot: string
}): { env: Record<string, string>; close: () => void } {
  const bridges: SocketLineBridge[] = []
  const close = () => {
    for (const bridge of bridges) bridge.close()
  }
  const socketOf = (bridge: SocketLineBridge) => {
    bridges.push(bridge)
    return bridge.socketPath
  }

  try {
    return {
      env: {
        [DRIVE_CLI_SOCKET_ENV]: socketOf(startDriveCLIBridge({ drive, workspaceRoot })),
        [WEBHOOK_CLI_SOCKET_ENV]: socketOf(
          startWebhookCLIBridge({ requestWebhookRPC: webhookRPCRequester(rpc, turn) })
        ),
        [AUTOMATION_JOB_CLI_SOCKET_ENV]: socketOf(
          startAutomationJobCLIBridge({ drive, requestAutomationJobRPC: automationJobRPCRequester(rpc, turn) })
        )
      },
      close
    }
  } catch (error) {
    close()
    throw error
  }
}
