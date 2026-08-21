import { requestSocketLineBridge, type SocketLineBridgeResponse } from '../../core/socket-line-bridge'
import type { WebhookCLICommand } from './webhook-cli-protocol'

/**
 * Sends one command to the current turn's webhook CLI bridge.
 */
export async function requestWebhookCLI(
  socketPath: string,
  command: WebhookCLICommand
): Promise<Record<string, unknown>> {
  const decoded = await requestSocketLineBridge<SocketLineBridgeResponse>(
    socketPath,
    JSON.stringify(command),
    'webhook CLI bridge returned an invalid response'
  )

  if (decoded.ok) return decoded.result
  throw new Error(decoded.error)
}
