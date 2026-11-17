import { expect } from 'bun:test'
import { appletCodeDigest, type AppletBindings } from '../../main/code-cache.ts'

export const base = process.env.ANKOLE_FUNCTION_RUNTIME_URL || 'http://127.0.0.1:5435'
export const headers = {
  authorization: `Bearer ${process.env.ANKOLE_FUNCTION_RUNTIME_TOKEN || 'dev-function-runtime-token'}`,
  'content-type': 'application/json',
  'x-ankole-mcp-origin': 'http://host.docker.internal:5546',
  'x-ankole-caller-mcp-token': 'caller-test-token',
  'x-ankole-admin-mcp-token': 'admin-test-token'
}
export const post = async (path: string, body: unknown) =>
  await fetch(base + path, { method: 'POST', headers, body: JSON.stringify(body) })

export async function publish(source: string, env: Record<string, string> = {}, bindings: AppletBindings = {}) {
  const sha = await appletCodeDigest({ source, env, bindings })
  const response = await fetch(`${base}/v1/applet/code/${sha}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ source, env, bindings })
  })
  expect(response.status).toBe(204)
  return sha
}

export async function invoke(
  sha: string,
  context: Record<string, unknown> = { method: 'POST', path: '/' },
  options: {
    page?: string
    lane?: 'route' | 'action'
    revision?: number | string
    timeout?: number
    call?: (frame: { operation: string; args: unknown[] }) => Promise<unknown>
  } = {}
) {
  const runId = crypto.randomUUID()
  const path = `/v1/applet/invoke?tenant_id=test&page_id=${options.page || sha}&revision=${options.revision || 1}&sha256=${sha}&run_id=${runId}&timeout_ms=${options.timeout || 2000}&lane=${options.lane || 'route'}`
  const ready = await fetch(base + path, { headers })
  expect(ready.status).toBe(204)
  try {
    return await new Promise<any>((resolve, reject) => {
      const ws = new WebSocket(base.replace(/^http/, 'ws') + path, { headers })
      let settled = false
      ws.onopen = () => ws.send(JSON.stringify({ type: 'start', run_id: runId, context }))
      ws.onmessage = async event => {
        const frame = JSON.parse(String(event.data))
        if (frame.type === 'done') {
          settled = true
          resolve(frame.outcome)
        }
        if (frame.type === 'call') {
          try {
            const value = await options.call!(frame)
            ws.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value }))
          } catch (error) {
            reject(error)
            ws.close()
          }
        }
      }
      ws.onerror = reject
      ws.onclose = () => {
        if (!settled) reject(new Error('Invocation closed before completion'))
      }
    })
  } finally {
    expect((await fetch(`${base}/v1/applet/invocations/${runId}`, { method: 'DELETE', headers })).status).toBe(204)
  }
}
