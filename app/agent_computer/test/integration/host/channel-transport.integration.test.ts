import { describe, expect, it, spyOn } from 'bun:test'
import {
  createChannelTransport,
  createPhoenixSocket,
  type ChannelSocketLike
} from '../../../src/fabric/channel_transport'
import { workerLogger } from '../../../src/worker/logging'

type PhoenixConnection = ChannelSocketLike & { conn: WebSocket | null; heartbeatIntervalMs: number }

describe('RuntimeFabric native WebSocket connection deadline', () => {
  it('cancels a hanging handshake after 10 seconds and rejoins through Phoenix backoff', async () => {
    const server = fixture([true, false])
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric, socket } = connect(server.port)
    const first = socket.conn!
    const started = performance.now()
    try {
      await waitFor(() => fabric.isReady, 13_000)
      expect(performance.now() - started).toBeGreaterThanOrEqual(9_900)
      expect(performance.now() - started).toBeLessThan(13_000)
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(server.requests).toBe(2)
      expect(log).toHaveBeenCalledWith('worker.fabric_connect_timeout', 'runtime fabric socket connection timed out', {
        error_type: 'connect_timeout',
        timeout_ms: 10_000
      })
      expect(log).toHaveBeenCalledWith(
        'worker.fabric_socket_closed',
        'runtime fabric socket closed',
        expect.objectContaining({ close_code: 1006 })
      )

      // A late response to the cancelled HTTP upgrade cannot open the old
      // connection or interrupt the new channel.
      server.releasePending()
      await Bun.sleep(50)
      expect(server.lateUpgrades).toEqual([false])
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(fabric.isReady).toBe(true)
      expect(socket.conn).not.toBe(first)
      expect(server.requests).toBe(2)
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  }, 15_000)

  it('starts a separate deadline on every Phoenix reconnect attempt', async () => {
    const server = fixture([true, true, false])
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric } = connect(server.port, 30)
    try {
      await waitFor(() => fabric.isReady)
      expect(server.requests).toBe(3)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(2)
      await Bun.sleep(80)
      expect(fabric.isReady).toBe(true)
      expect(server.requests).toBe(3)
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  })

  it('cancels the pending deadline on explicit disconnect and never reconnects', async () => {
    const server = fixture([true])
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const socket = createPhoenixSocket(
      `ws://127.0.0.1:${server.port}/worker`,
      {
        workerID: 'connection-test',
        workerAuthKey: 'test-secret'
      },
      80
    ) as PhoenixConnection
    try {
      socket.connect()
      const first = socket.conn!
      await waitFor(() => server.requests === 1)
      await new Promise<void>(resolve => socket.disconnect(resolve))
      await Bun.sleep(120)
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(socket.conn).toBeNull()
      expect(server.requests).toBe(1)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(0)
    } finally {
      socket.disconnect()
      server.stop()
      log.mockRestore()
    }
  })

  it('cancels an isolated pending connection on transport stop', async () => {
    const server = fixture([true])
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric, socket } = connect(server.port, 80)
    const first = socket.conn!
    try {
      await waitFor(() => server.requests === 1)
      expect(fabric.isolationReason(0)).toBe('no_channel')
      fabric.stop()
      await Bun.sleep(300)
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(server.requests).toBe(1)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(0)
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  })

  it('stops after a fatal generation rejection without a later timeout or reconnect', async () => {
    const server = fixture([false], { rejectJoin: true })
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric, socket } = connect(server.port, 80)
    const first = socket.conn!
    try {
      await waitFor(() => fabric.isolationReason(60_000) === 'stale_worker_generation')
      fabric.stop()
      await Bun.sleep(300)
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(server.requests).toBe(1)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(0)
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  })

  it('keeps an opened connection after its former handshake deadline', async () => {
    const server = fixture([false])
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric, socket } = connect(server.port, 80)
    try {
      await waitFor(() => fabric.isReady)
      const opened = socket.conn!
      await Bun.sleep(180)
      expect(opened.readyState).toBe(WebSocket.OPEN)
      expect(fabric.isReady).toBe(true)
      expect(server.requests).toBe(1)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(0)
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  })

  it('applies the connection deadline after a real unanswered heartbeat reconnect', async () => {
    const server = fixture([false, true, false], { answerHeartbeat: false })
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    const { fabric, socket } = connect(server.port, 30, 40)
    try {
      await waitFor(() => fabric.isReady)
      const first = socket.conn!
      await waitFor(() => server.requests === 3 && fabric.isReady)
      expect(first.readyState).toBe(WebSocket.CLOSED)
      expect(log.mock.calls.filter(call => call[0] === 'worker.fabric_connect_timeout')).toHaveLength(1)
      expect(log).toHaveBeenCalledWith(
        'worker.fabric_socket_closed',
        'runtime fabric socket closed',
        expect.objectContaining({ close_code: 1000, close_reason: 'heartbeat timeout' })
      )
    } finally {
      fabric.stop()
      server.stop()
      log.mockRestore()
    }
  })
})

function connect(port: number, timeoutMs?: number, heartbeatMs?: number) {
  let socket!: PhoenixConnection
  const fabric = createChannelTransport(
    {
      endpoint: `ws://127.0.0.1:${port}/worker`,
      workerID: 'connection-test',
      incarnationID: 'incarnation-test',
      workerAuthKey: 'test-secret'
    },
    {
      joinParams: () => ({ incarnation_id: 'incarnation-test', max_slots: 1, available_slots: 1 }),
      createSocket(endpoint, options) {
        socket = createPhoenixSocket(endpoint, options, timeoutMs) as PhoenixConnection
        if (heartbeatMs) socket.heartbeatIntervalMs = heartbeatMs
        return socket
      }
    }
  )
  return { fabric, socket }
}

function fixture(hanging: boolean[], options: { answerHeartbeat?: boolean; rejectJoin?: boolean } = {}) {
  let requests = 0
  const pending: Array<() => void> = []
  const lateUpgrades: boolean[] = []
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    idleTimeout: 0,
    fetch(request, server) {
      const attempt = requests++
      if (hanging[attempt]) {
        return new Promise<Response | undefined>(resolve =>
          pending.push(() => {
            const upgraded = server.upgrade(request)
            lateUpgrades.push(upgraded)
            resolve(upgraded ? undefined : new Response('cancelled handshake', { status: 503 }))
          })
        )
      }
      if (server.upgrade(request)) return
      return new Response('upgrade failed', { status: 400 })
    },
    websocket: {
      message(socket, data) {
        const [joinRef, ref, topic, event] = JSON.parse(String(data)) as [string, string, string, string]
        if (event === 'phx_join') {
          socket.send(
            JSON.stringify([
              joinRef,
              ref,
              topic,
              'phx_reply',
              {
                status: options.rejectJoin ? 'error' : 'ok',
                response: options.rejectJoin
                  ? { reason: 'stale_worker_generation' }
                  : { connection_id: `connection-${requests}` }
              }
            ])
          )
        } else if (event === 'heartbeat' && options.answerHeartbeat !== false) {
          socket.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response: {} }]))
        }
      }
    }
  })
  return {
    port: server.port!,
    get requests() {
      return requests
    },
    lateUpgrades,
    releasePending() {
      for (const resolve of pending.splice(0)) resolve()
    },
    stop() {
      server.stop(true)
      for (const resolve of pending.splice(0)) resolve()
    }
  }
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000) {
  const deadline = performance.now() + timeoutMs
  while (!predicate() && performance.now() < deadline) await Bun.sleep(5)
  expect(predicate()).toBe(true)
}
