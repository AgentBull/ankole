import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { DEFAULT_INBOUND_MESSAGE_DEDUP_LIMIT, InboundMessageDedup } from '../src/fabric/channel-transport'
import { createEnvelope, decodeEnvelope, envelopeHeader, RPCResponseSchema } from '../src/fabric/envelope-proto'
import { arrayBuffer, connectReady, sealed, tick, turnControlEnvelope } from './support/fabric'

describe('RuntimeFabric InboundMessageDedup', () => {
  it('bounds recent message_ids with a 2048-entry LRU and refreshes touched keys', () => {
    expect(DEFAULT_INBOUND_MESSAGE_DEDUP_LIMIT).toBe(2_048)

    const lru = new InboundMessageDedup()
    for (let i = 0; i < 2_048; i++) {
      lru.record(`msg-${i}`)
    }
    expect(lru.size).toBe(2_048)
    // Touching `msg-0` makes `msg-1` the oldest entry.
    expect(lru.hasAndTouch('msg-0')).toBe(true)
    lru.record('msg-2048')
    expect(lru.size).toBe(2_048)
    expect(lru.hasAndTouch('msg-1')).toBe(false)
    expect(lru.hasAndTouch('msg-0')).toBe(true)
    expect(lru.hasAndTouch('msg-2048')).toBe(true)
  })

  it('deduplicates replayed inbound command and reply frames across reconnects while advancing acked_seq', async () => {
    const { socket, fabric } = await connectReady()
    try {
      const firstChannel = socket.current!
      const cmd1 = turnControlEnvelope('dup-cmd-1')
      const reply1 = createEnvelope({
        ...envelopeHeader('dup-reply-1'),
        body: {
          case: 'rpcResponse',
          value: create(RPCResponseSchema, { requestId: 'req-1', payload: new Uint8Array() })
        }
      })

      firstChannel.emit('command', arrayBuffer(sealed(cmd1, 1)))
      firstChannel.emit('reply', arrayBuffer(sealed(reply1, 2)))
      await tick()

      expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(sealed(cmd1, 1)) })
      expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(sealed(reply1, 2)) })

      // Simulate reconnect where control plane replays unacked frames (`dup-cmd-1`, `dup-reply-1`) followed by a fresh `fresh-cmd-3`.
      socket.close(1006)
      expect(await fabric.receive(5)).toMatchObject({ kind: 'disconnected', connectionID: 'connection-1' })
      socket.open()
      firstChannel.joinPush!.reply('ok', { connection_id: 'connection-2' })
      await tick()

      const freshCmd = turnControlEnvelope('fresh-cmd-3')
      firstChannel.emit('command', arrayBuffer(sealed(cmd1, 1)))
      firstChannel.emit('reply', arrayBuffer(sealed(reply1, 2)))
      firstChannel.emit('command', arrayBuffer(sealed(freshCmd, 3)))
      await tick()

      // Duplicate frames advance acked_seq to 3 without re-dispatching `dup-cmd-1` or `dup-reply-1`!
      expect(firstChannel.pushes.at(-1)).toMatchObject({
        event: 'ack',
        payload: { acked_seq: 3 }
      })
      expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(sealed(freshCmd, 3)) })
      expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    } finally {
      fabric.stop()
    }
  })
})
