import { afterEach, expect, test } from 'bun:test'
import { existsSync, rmSync } from 'node:fs'
import { runAutomationJob } from '../src/automation-jobs/run'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import type { PodRequest } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { request, rpcStub, runFixture } from './support/automation-job-run'

let root: string | undefined
afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true })
})

test('an automation process gets Pod and files CLI bridges with its attempt fence', async () => {
  const fixture = runFixture(`
async function command(path, request) {
  return await new Promise((resolve, reject) => {
    let text = ''
    Bun.connect({ unix: path, socket: {
      open(socket) { socket.write(JSON.stringify(request) + '\\n') },
      data(socket, chunk) { text += chunk.toString(); if (text.includes('\\n')) { socket.end(); resolve(JSON.parse(text)) } },
      error(_socket, error) { reject(error) }
    }}).catch(reject)
  })
}
const pod = process.env.ANKOLE_RUNTIME_POD_CLI_SOCKET
const files = process.env.ANKOLE_RUNTIME_FILES_CLI_SOCKET
const listing = await command(pod, { operation: 'pages.list', params: {}, cwd: process.cwd() })
const drive = await command(files, { operation: 'list', prefix: '', cwd: process.cwd() })
console.log(JSON.stringify({ pod, files, listing, drive: drive.ok }))
`)
  root = fixture.root
  const calls: unknown[] = []
  const base = rpcStub(fixture, [])
  const rpc: RPCRequester = async (method, payload, frame, options) => {
    if (method === 'pod.read') {
      const pod = payload as Partial<PodRequest>
      calls.push({ method, attempt: pod.automationAttempt, operation: pod.operation, frame })
      return { bodyJson: jsonBytes({ result: [] }) } as never
    }
    if (method.startsWith('files.')) {
      calls.push({ method, attempt: (payload as { automationAttempt?: unknown }).automationAttempt })
    }
    return base(method, payload, frame, options)
  }
  const run = request(fixture, {})
  const result = await runAutomationJob(run, { config: fixture.config, sdkPath: fixture.sdkPath, rpc })
  expect(result.status).toBe('succeeded')
  const output = JSON.parse(result.stdout)
  expect(output.listing).toEqual({ ok: true, result: [] })
  expect(output.drive).toBe(true)
  expect(existsSync(output.pod)).toBe(false)
  expect(existsSync(output.files)).toBe(false)
  expect(calls.some(call => (call as { method: string }).method === 'pod.read')).toBe(true)
  for (const call of calls) {
    expect(call).toMatchObject({
      attempt: { jobId: run.automationJobId, runId: run.automationJobRunId, attemptId: run.attemptId }
    })
  }
})
