/** The CLI and automation subprocesses share this client without importing Worker runtime code. */
export type SocketLineBridgeResponse = { ok: true; result: Record<string, unknown> } | { ok: false; error: string }

export async function requestSocketLineBridge(
  socketPath: string,
  line: string,
  invalidResponseError: string
): Promise<Record<string, unknown>> {
  const decoded = await new Promise<SocketLineBridgeResponse>((resolve, reject) => {
    const response: Buffer[] = []
    let pending = Buffer.from(`${line}\n`)
    const flush = (socket: Bun.Socket) => {
      if (!pending.byteLength) return
      const written = socket.write(pending)
      if (written < 0) {
        pending = Buffer.alloc(0)
        return
      }
      pending = pending.subarray(written)
    }
    let settled = false

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          flush(socket)
        },
        drain: flush,
        data(_socket, data) {
          response.push(Buffer.from(data))
        },
        close() {
          if (settled) return
          settled = true

          try {
            resolve(JSON.parse(Buffer.concat(response).toString('utf8').trim()) as SocketLineBridgeResponse)
          } catch {
            reject(new Error(invalidResponseError))
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
  if (decoded.ok) return decoded.result
  throw new Error(decoded.error)
}
