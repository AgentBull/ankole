import { afterAll, beforeAll, expect, test } from 'bun:test'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { connect, type Socket } from 'node:net'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { connect as connectTLS, createSecureContext, createServer } from 'node:tls'
import { startWebProxy } from '../../node'

let root: string
let key: Buffer
let cert: Buffer

beforeAll(async () => {
  root = await mkdtemp('/tmp/ankole-proxy-tls-')
  const result = spawnSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-days',
    '1',
    '-subj',
    '/CN=localhost',
    '-addext',
    'subjectAltName=DNS:localhost',
    '-keyout',
    join(root, 'key.pem'),
    '-out',
    join(root, 'cert.pem')
  ])
  if (result.status !== 0) throw new Error(`test certificate generation failed: ${result.stderr.toString()}`)
  key = await readFile(join(root, 'key.pem'))
  cert = await readFile(join(root, 'cert.pem'))
})

afterAll(async () => {
  if (root) await rm(root, { recursive: true, force: true })
})

async function readBytes(socket: Socket, size: number): Promise<Buffer> {
  for (;;) {
    const bytes = socket.read(size) as Buffer | null
    if (bytes) return bytes
    await once(socket, 'readable')
  }
}

async function tunnel(proxyPort: number, host: string, port: number): Promise<Socket> {
  const socket = connect(proxyPort, '127.0.0.1')
  await once(socket, 'connect')
  try {
    socket.write(Buffer.from([5, 1, 0]))
    expect(await readBytes(socket, 2)).toEqual(Buffer.from([5, 0]))
    const request = Buffer.concat([
      Buffer.from([5, 1, 0, 3, Buffer.byteLength(host)]),
      Buffer.from(host),
      Buffer.alloc(2)
    ])
    request.writeUInt16BE(port, request.length - 2)
    socket.write(request)
    const reply = await readBytes(socket, 10)
    if (reply[1] !== 0) throw new Error(`SOCKS request rejected: ${reply[1]}`)
    return socket
  } catch (error) {
    socket.destroy()
    throw error
  }
}

test('checked TCP tunnels preserve TLS SNI and certificate hostname verification', async () => {
  let seenName = ''
  const context = createSecureContext({ key, cert })
  const server = createServer(
    {
      key,
      cert,
      SNICallback(name, callback) {
        seenName = name
        callback(null, context)
      }
    },
    socket => socket.end('verified TLS')
  )
  server.on('tlsClientError', () => undefined)
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('missing TLS port')
  const proxy = startWebProxy(false)
  try {
    const socket = connectTLS({
      socket: await tunnel(proxy.port, 'localhost', address.port),
      servername: 'localhost',
      ca: cert
    })
    try {
      await once(socket, 'secureConnect')
      expect(socket.authorized).toBe(true)
      expect(seenName).toBe('localhost')
      socket.resume()
      await once(socket, 'end')
    } finally {
      socket.destroy()
    }
    const wrong = connectTLS({
      socket: await tunnel(proxy.port, 'localhost', address.port),
      servername: 'wrong.localhost',
      ca: cert
    })
    try {
      await expect(once(wrong, 'secureConnect')).rejects.toThrow()
    } finally {
      wrong.destroy()
    }
  } finally {
    await proxy.close()
    await new Promise<void>(resolve => server.close(() => resolve()))
  }
}, 10_000)

test('Node-API closes the listener before a saved proxy port is reused', async () => {
  const proxy = startWebProxy(false)
  const port = proxy.port
  await proxy.close()
  const restored = startWebProxy(true, port)
  await expect(tunnel(restored.port, '127.0.0.1', 80)).rejects.toThrow('rejected: 2')
  await restored.close()
})
