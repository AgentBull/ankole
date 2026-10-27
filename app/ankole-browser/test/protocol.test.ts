import { expect, test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { BrowserDaemonServer } from '../src/daemon/server'
import { BrowserDataError } from '../src/errors'
import {
  BrowserMaterialSchema,
  BrowserRequestSchema,
  BrowserResponseSchema,
  parseBrowserRequest,
  type BrowserCommand,
  type BrowserMaterial,
  type BrowserResponse
} from '../src/protocol'

const material: BrowserMaterial = {
  protocol_version: 1,
  route_id: 'br_1234567890abcdef',
  data_root: '/tmp/browser-data',
  artifact_root: '/tmp/browser-artifacts',
  immutable_fingerprint: 'sha256:test',
  material_generation: 0,
  profile: { mode: 'persistent_user_data_dir' },
  backend: { kind: 'local_chromium', executable: '/usr/bin/chromium', args: [] },
  navigation: { ssrf_filter: true, allow_file_urls: false },
  idle_ttl_ms: 60_000
}

test('material is final data-plane input with no control-plane references', () => {
  expect(BrowserMaterialSchema.parse(material)).toEqual(material)
  expect(() => BrowserMaterialSchema.parse({ ...material, credential_ref: 'secret:1' })).toThrow()
  expect(() => BrowserMaterialSchema.parse({ ...material, agent_id: 'agent-1' })).toThrow()
})

test('request route and material are strict protocol values', () => {
  expect(
    BrowserRequestSchema.parse({
      v: 1,
      id: 'request-1',
      route: material.route_id,
      session: 'default',
      material,
      deadline_unix_ms: Date.now() + 1_000,
      command: { name: 'status', args: {} }
    }).route
  ).toBe(material.route_id)
})

function request(command: unknown): unknown {
  return {
    v: 1,
    id: 'request-1',
    route: material.route_id,
    session: 'default',
    material,
    deadline_unix_ms: Date.now() + 1_000,
    command
  }
}

function rejectionMessage(command: unknown): string {
  try {
    parseBrowserRequest(request(command))
  } catch (error) {
    if (error instanceof BrowserDataError) {
      expect(error.code).toBe('invalid_command')
      return error.message
    }
    throw error
  }
  throw new Error('expected the command to be rejected')
}

test('the command vocabulary is closed at the wire schema', () => {
  expect(rejectionMessage({ name: 'teleport', args: {} })).toBe('unsupported browser command: teleport')
  expect(rejectionMessage({ name: 'click', args: {} })).toBe('selector must be a non-empty string')
  expect(rejectionMessage({ name: 'scroll', args: { direction: 'diagonal' } })).toContain('direction Invalid option')
  expect(rejectionMessage({ name: 'press', args: { key: 'Enter', turbo: true } })).toContain('Unrecognized key')
  expect(rejectionMessage({ name: 'wait', args: {} })).toBe('wait requires a condition')
  expect(rejectionMessage({ name: 'tab', args: { action: 'switch' } })).toBe('index must be a number')
  expect(rejectionMessage({ name: 'find', args: { kind: 'text', value: 'x', action: 'fill' } })).toBe(
    'text must be a non-empty string'
  )
})

test('per-command argument dependencies are part of the schema', () => {
  const accepted: BrowserCommand[] = [
    { name: 'get', args: { property: 'title' } },
    { name: 'get', args: { property: 'attr', selector: '@e1', attribute: 'href' } },
    { name: 'dialog', args: { action: 'accept', text: '' } },
    { name: 'tab', args: { action: 'new' } },
    { name: 'lifecycle', args: { verb: 'purge' } },
    { name: 'lease.release', args: { lease_token: 'lease_1', outcome: 'ok' } }
  ]
  for (const command of accepted) {
    expect(parseBrowserRequest(request(command)).command).toEqual(command)
  }
  expect(rejectionMessage({ name: 'get', args: { property: 'text' } })).toBe('selector must be a non-empty string')
  expect(rejectionMessage({ name: 'get', args: { property: 'title', selector: '@e1' } })).toContain('Unrecognized key')
})

test('batch items are structurally limited to page commands plus status', () => {
  const nested = parseBrowserRequest(
    request({
      name: 'batch',
      args: {
        commands: [
          { name: 'open', args: { url: 'https://example.com' } },
          { name: 'status', args: {} }
        ],
        bail: true
      }
    })
  )
  expect(nested.command.name).toBe('batch')
  expect(
    rejectionMessage({ name: 'batch', args: { commands: [{ name: 'lease.acquire', args: { run_id: 'r' } }] } })
  ).toBe('batch cannot contain lease.acquire')
  expect(rejectionMessage({ name: 'batch', args: { commands: [{ name: 'close', args: {} }] } })).toBe(
    'batch cannot contain close'
  )
  expect(rejectionMessage({ name: 'batch', args: { commands: [{ name: 'click', args: {} }] } })).toBe(
    'commands[0].args.selector must be a non-empty string'
  )
})

async function sendRawLine(socketPath: string, line: string): Promise<BrowserResponse> {
  const payload = await new Promise<string>((resolve, reject) => {
    const socket = createConnection(socketPath)
    let chunks = ''
    socket.setEncoding('utf8')
    socket.once('error', reject)
    socket.on('data', chunk => {
      chunks += chunk
    })
    socket.once('connect', () => {
      socket.write(line)
    })
    socket.once('end', () => resolve(chunks))
  })
  return BrowserResponseSchema.parse(JSON.parse(payload.trim()))
}

test('daemon rejects malformed and non-object JSON lines as invalid_command', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'ankole-browserd-'))
  const server = new BrowserDaemonServer(join(dir, 'browserd.sock'))
  await server.listen()
  try {
    for (const line of ['null\n', '123\n', '[]\n', '{bad\n']) {
      const response = await sendRawLine(server.socketPath, line)
      expect(response.ok).toBe(false)
      if (!response.ok) {
        expect(response.error.code).toBe('invalid_command')
        expect(response.error.message).toBe('Invalid JSON request')
      }
    }
  } finally {
    await server.close()
    await rm(dir, { recursive: true, force: true })
  }
})
