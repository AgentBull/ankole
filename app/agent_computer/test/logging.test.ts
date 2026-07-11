import { describe, expect, it } from 'bun:test'
import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import { Writable } from 'node:stream'
import type { DestinationStream } from 'pino'
import { createWorkerLogger, createWorkerPinoOptions } from '../src/worker/logging'

describe('@ankole/agent-computer worker logger', () => {
  it('writes structured JSON without the Pino level field', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    )

    logger.notice('worker.ready_sent', 'worker ready sent', { worker_id: 'worker-1' })

    const [entry] = capture.entries()
    expect(entry).not.toHaveProperty('level')
    expect(entry.severity).toBe('NOTICE')
    expect(entry.message).toBe('worker ready sent')
    expect(entry.event).toBe('worker.ready_sent')
    expect(typeof entry.time).toBe('string')
    expect(entry.worker_id).toBe('worker-1')
    expect(entry.labels).toEqual({
      service: 'ankole-worker',
      component: 'agent-computer',
      runtime: 'bun',
      environment: 'production'
    })
  })

  it('maps public severity methods to the shared severity names', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    )

    logger.notice('worker.notice', 'notice')
    logger.warning('worker.warning', 'warning')
    logger.critical('worker.critical', 'critical')
    logger.alert('worker.alert', 'alert')
    logger.emergency('worker.emergency', 'emergency')

    expect(capture.entries().map(entry => entry.severity)).toEqual([
      'NOTICE',
      'WARNING',
      'CRITICAL',
      'ALERT',
      'EMERGENCY'
    ])
  })

  it('serializes Error values under the error key', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    )

    logger.error('worker.turn_failed', 'worker turn failed', { error: new TypeError('bad turn') })

    const [entry] = capture.entries()
    const error = recordValue(entry.error) ?? {}
    expect(error).toMatchObject({
      type: 'TypeError',
      message: 'bad turn'
    })
    expect(String(error.stack)).toContain('TypeError: bad turn')
  })

  it('keeps child logger labels in the labels field', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    ).child({
      component: 'runtime-fabric',
      labels: { environment: 'test', version: 'v1' },
      fields: { subsystem: 'fabric' }
    })

    logger.info('runtime.fabric.started', 'runtime fabric started')

    const [entry] = capture.entries()
    expect(entry.subsystem).toBe('fabric')
    expect(entry.labels).toEqual({
      service: 'ankole-worker',
      component: 'runtime-fabric',
      runtime: 'bun',
      environment: 'test',
      version: 'v1'
    })
  })

  it('keeps operation as a normal top-level structured field', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    )

    logger.info('worker.turn_started', 'worker turn started', {
      operation: { id: 'event-1', producer: 'ankole-worker/agent-computer', first: true }
    })

    const [entry] = capture.entries()
    expect(entry.operation).toEqual({
      id: 'event-1',
      producer: 'ankole-worker/agent-computer',
      first: true
    })
  })

  it('drops old Cloud Logging compatibility fields from payload input', () => {
    const capture = createCapture()
    const logger = createWorkerLogger(
      {},
      {
        env: { ANKOLE_LOG_LEVEL: 'debug', NODE_ENV: 'production' },
        destination: capture.stream
      }
    )

    logger.info('worker.compat_ignored', 'compat ignored', {
      level: 30,
      severity_text: 'ERROR',
      severity_number: 17,
      'logging.googleapis.com/labels': { component: 'old' },
      'logging.googleapis.com/operation': { id: 'old' },
      worker_id: 'worker-1'
    })

    const [entry] = capture.entries()
    expect(entry.severity).toBe('INFO')
    expect(entry.worker_id).toBe('worker-1')
    expect(entry).not.toHaveProperty('level')
    expect(entry).not.toHaveProperty('severity_text')
    expect(entry).not.toHaveProperty('severity_number')
    expect(Object.keys(entry).some(key => key.startsWith('logging.googleapis.com/'))).toBe(false)
    expect((recordValue(entry.labels) ?? {}).component).toBe('agent-computer')
  })

  it('keeps the worker output structured so kit can own local display formatting', () => {
    expect(createWorkerPinoOptions({ NODE_ENV: 'production' }).transport).toBeUndefined()
    expect(createWorkerPinoOptions({ NODE_ENV: 'development' }).transport).toBeUndefined()
  })
})

function createCapture(): { stream: DestinationStream; entries(): JSONObject[] } {
  const chunks: string[] = []
  const stream = new Writable({
    write(chunk, _encoding, callback) {
      chunks.push(String(chunk))
      callback()
    }
  }) as DestinationStream

  return {
    stream,
    entries() {
      return chunks
        .join('')
        .split('\n')
        .filter(Boolean)
        .map(line => JSON.parse(line) as JSONObject)
    }
  }
}
