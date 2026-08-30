import { requestSocketLineBridge, type SocketLineBridgeResponse } from '../../core/socket-line-bridge'
import type { AutomationJobCLICommand } from './automation-job-cli-protocol'

/**
 * Sends one command to the current turn's automation job CLI bridge.
 */
export async function requestAutomationJobCLI(
  socketPath: string,
  command: AutomationJobCLICommand
): Promise<Record<string, unknown>> {
  const decoded = await requestSocketLineBridge<SocketLineBridgeResponse>(
    socketPath,
    JSON.stringify(command),
    'automation job CLI bridge returned an invalid response'
  )

  if (decoded.ok) return decoded.result
  throw new Error(decoded.error)
}
