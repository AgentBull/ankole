import { afterEach, beforeEach, expect, mock, test } from 'bun:test'

const sourceURL = 'http://127.0.0.1:3198/pod/spreadsheet/spreadsheet-worker.ts?worker_file&type=module'
mock.module('./spreadsheet-worker.ts?worker&url', () => ({ default: sourceURL }))
const { createSpreadsheetEngine } = await import('./spreadsheet-engine')
const originalLocation = Object.getOwnPropertyDescriptor(globalThis, 'location')
const originalWorker = Object.getOwnPropertyDescriptor(globalThis, 'Worker')
const originalCreateURL = URL.createObjectURL
const originalRevokeURL = URL.revokeObjectURL
let blobs: Blob[]
let revoked: string[]
let workers: { url: string; terminated: boolean }[]
let constructionError: Error | undefined

beforeEach(() => {
  blobs = []
  revoked = []
  workers = []
  constructionError = undefined
  Object.defineProperty(globalThis, 'location', { configurable: true, value: { origin: 'http://pod.localhost:4100' } })
  Object.defineProperty(globalThis, 'Worker', {
    configurable: true,
    value: class {
      constructor(url: string | URL) {
        if (constructionError) throw constructionError
        const record = { url: String(url), terminated: false }
        workers.push(record)
        this.terminate = () => {
          record.terminated = true
        }
      }
      terminate() {}
      postMessage() {}
    }
  })
  URL.createObjectURL = blob => {
    if (!(blob instanceof Blob)) throw new TypeError('Expected a worker bootstrap Blob')
    blobs.push(blob)
    return 'blob:http://pod.localhost:4100/spreadsheet'
  }
  URL.revokeObjectURL = url => {
    revoked.push(url)
  }
})

afterEach(() => {
  for (const [key, descriptor] of [
    ['location', originalLocation],
    ['Worker', originalWorker]
  ] as const) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor)
    else Reflect.deleteProperty(globalThis, key)
  }
  URL.createObjectURL = originalCreateURL
  URL.revokeObjectURL = originalRevokeURL
})

test('a same-origin spreadsheet worker uses its separate entry without a blob', () => {
  Object.defineProperty(globalThis, 'location', { configurable: true, value: { origin: new URL(sourceURL).origin } })
  const engine = createSpreadsheetEngine()
  expect(workers[0].url).toBe(sourceURL)
  expect(blobs).toEqual([])
  engine.dispose()
  expect(workers[0].terminated).toBe(true)
  expect(revoked).toEqual([])
})

test('a cross-origin worker imports its real entry and releases its bootstrap when disposed', async () => {
  const engine = createSpreadsheetEngine()
  expect(blobs).toHaveLength(1)
  expect(await blobs[0].text()).toBe(`import ${JSON.stringify(sourceURL)}`)
  const pending = engine.sheets()
  engine.dispose()
  await expect(pending).rejects.toThrow('The spreadsheet worker stopped')
  expect(workers[0].terminated).toBe(true)
  expect(revoked).toEqual([workers[0].url])
})

test('a rejected worker construction releases the bootstrap URL', () => {
  constructionError = new Error('Worker blocked by the browser')
  expect(createSpreadsheetEngine).toThrow('Worker blocked by the browser')
  expect(blobs).toHaveLength(1)
  expect(revoked).toEqual(['blob:http://pod.localhost:4100/spreadsheet'])
})
