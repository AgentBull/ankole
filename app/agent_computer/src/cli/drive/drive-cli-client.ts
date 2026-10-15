import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import type { DriveCLICommand } from './drive-cli-protocol'

export async function requestDriveCLI(socketPath: string, command: DriveCLICommand): Promise<Record<string, unknown>> {
  return requestSocketLineBridge(socketPath, JSON.stringify(command), 'drive CLI bridge returned an invalid response')
}
