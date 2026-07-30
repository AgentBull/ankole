import type { WebhookCLICommand, WebhookCLIResponse } from './webhook-cli-protocol'

/**
 * Sends one command to the current turn's webhook CLI bridge.
 */
export async function requestWebhookCLI(
  socketPath: string,
  command: WebhookCLICommand
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    let response = ''
    let settled = false

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(`${JSON.stringify(command)}\n`)
        },
        data(_socket, data) {
          response += Buffer.from(data).toString('utf8')
        },
        close() {
          if (settled) return
          settled = true

          try {
            const decoded = JSON.parse(response.trim()) as WebhookCLIResponse
            if (decoded.ok) resolve(decoded.result)
            else reject(new Error(decoded.error))
          } catch {
            reject(new Error('webhook CLI bridge returned an invalid response'))
          }
        },
        connectError(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        },
        error(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        }
      }
    }).catch(error => {
      if (settled) return
      settled = true
      reject(error)
    })
  })
}
