import { request } from 'node:http'

/** One call to the ankole-rclone control API. */
export type RcCall = <T>(method: string, body: Record<string, unknown>, signal?: AbortSignal) => Promise<T>

/**
 * ankole-rclone did not answer one control call before its deadline. The
 * daemon may still finish the call, so the Turn that waited is retryable.
 */
export class DriveControlTimeoutError extends Error {
  readonly code = 'drive_control_timeout'
  readonly retryable = true

  constructor(method: string, cause: unknown) {
    super(`Drive did not answer rclone ${method} before its deadline.`, { cause })
    this.name = 'DriveControlTimeoutError'
  }
}

/** Calls the ankole-rclone control API on its Unix socket. */
export function rcOnSocket<T>(
  socketPath: string,
  method: string,
  body: Record<string, unknown>,
  signal = AbortSignal.timeout(15_000)
): Promise<T> {
  return new Promise((resolve, reject) => {
    // node:http reports any aborted request as a bare AbortError; name the
    // call when the abort came from its deadline.
    const fail = (error: unknown) =>
      reject(
        signal.aborted && signal.reason instanceof DOMException && signal.reason.name === 'TimeoutError'
          ? new DriveControlTimeoutError(method, signal.reason)
          : error
      )
    const req = request(
      {
        socketPath,
        path: `/${method}`,
        method: 'POST',
        signal,
        headers: { 'content-type': 'application/json' }
      },
      response => {
        const chunks: Buffer[] = []
        response.on('data', chunk => chunks.push(chunk))
        response.on('error', fail)
        response.on('end', () => {
          try {
            const raw = Buffer.concat(chunks).toString()
            const result = raw ? JSON.parse(raw) : {}
            if (response.statusCode !== 200) {
              reject(new Error(result.error || `rclone ${method}: HTTP ${response.statusCode}`))
            } else resolve(result as T)
          } catch (error) {
            reject(error)
          }
        })
      }
    )
    req.on('error', fail)
    req.end(JSON.stringify(body))
  })
}
