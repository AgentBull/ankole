import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import type { WebhookCLICommand } from './webhook-cli-protocol'

export async function requestWebhookCLI(
  socketPath: string,
  command: WebhookCLICommand
): Promise<Record<string, unknown>> {
  return requestSocketLineBridge(socketPath, JSON.stringify(command), 'webhook CLI bridge returned an invalid response')
}
