import { describe, expect, test } from 'bun:test'
import { PageDraftModel } from './page-draft'

type Request = {
  generation: number
  capturedXml: string
  resolve: (value: { xml: string; revision: number }) => void
  reject: (error: unknown) => void
  promise: Promise<string | undefined>
}

type Expected = {
  source: string
  xml: string
  savedXml: string
  revision: number
  conflict: boolean
}

/**
 * Executable mirror of `PageDraft.lean`. The random test compares the real
 * signals model against these transitions after every event.
 */
class DraftOracle {
  generation = 0
  state: Expected

  constructor(source = 'page-a', xml = '<page><p>A0</p></page>', revision = 1) {
    this.state = { source, xml, savedXml: xml, revision, conflict: false }
  }

  edit(xml: string) {
    this.state.xml = xml
  }

  save(content: string, revision: number) {
    this.state.savedXml = content
    this.state.revision = revision
    this.state.conflict = false
  }

  load(source: string, content: string, revision: number) {
    if (this.state.source === source) return
    this.generation += 1
    this.state = { source, xml: content, savedXml: content, revision, conflict: false }
  }

  discard() {
    this.generation += 1
    this.state.xml = this.state.savedXml
    this.state.conflict = false
  }

  cancel() {
    this.generation += 1
  }

  start(): number {
    this.generation += 1
    return this.generation
  }

  apply(request: Request, content: string, revision: number): boolean {
    if (request.generation !== this.generation) return false
    if (request.capturedXml !== this.state.xml) return false
    if (revision < this.state.revision) return false
    this.state = { ...this.state, xml: content, savedXml: content, revision, conflict: false }
    return true
  }
}

function expectSame(model: InstanceType<typeof PageDraftModel>, oracle: DraftOracle) {
  expect(model.source.peek()).toBe(oracle.state.source)
  expect(model.xml.peek()).toBe(oracle.state.xml)
  expect(model.savedXML.peek()).toBe(oracle.state.savedXml)
  expect(model.revision.peek()).toBe(oracle.state.revision)
  expect(model.conflict.peek()).toBe(oracle.state.conflict)
}

function deferredRequest(model: InstanceType<typeof PageDraftModel>, generation: number, capturedXml: string): Request {
  let resolve!: Request['resolve']
  let reject!: Request['reject']
  const response = new Promise<{ xml: string; revision: number }>((ok, fail) => {
    resolve = ok
    reject = fail
  })
  const promise = model.reload(() => response)
  return { generation, capturedXml, resolve, reject, promise }
}

async function settle(request: Request, outcome: 'resolve' | 'reject', content = '', revision = 0) {
  if (outcome === 'resolve') request.resolve({ xml: content, revision })
  else request.reject(new Error('network'))
  return request.promise.catch(() => undefined)
}

describe('page draft async reload model', () => {
  test('a read started before an edit cannot replace the edit', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 1)
    const oracle = new DraftOracle()
    const request = deferredRequest(model, oracle.start(), oracle.state.xml)

    model.xml.value = '<page><p>Local</p></page>'
    oracle.edit(model.xml.peek())

    await expect(settle(request, 'resolve', '<page><p>Remote</p></page>', 2)).resolves.toBeUndefined()
    expect(request.generation).toBe(oracle.generation)
    expectSame(model, oracle)
    expect(model.savedXML.peek()).toBe('<page><p>A0</p></page>')
    expect(model.revision.peek()).toBe(1)
  })

  test('a read started on the previous page cannot touch the new page', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 1)
    const oracle = new DraftOracle()
    const request = deferredRequest(model, oracle.start(), oracle.state.xml)

    model.load('page-b', '<page><p>B0</p></page>', 7)
    oracle.load('page-b', '<page><p>B0</p></page>', 7)

    await expect(settle(request, 'resolve', '<page><p>Late A</p></page>', 9)).resolves.toBeUndefined()
    expectSame(model, oracle)
    expect(model.xml.peek()).toBe('<page><p>B0</p></page>')
  })

  test('discard and cancel invalidate a pending read', async () => {
    for (const cancel of ['discard', 'cancelReload'] as const) {
      const model = new PageDraftModel()
      model.load('page-a', '<page><p>A0</p></page>', 1)
      model.xml.value = '<page><p>Local</p></page>'
      const oracle = new DraftOracle()
      oracle.edit(model.xml.peek())
      const request = deferredRequest(model, oracle.start(), oracle.state.xml)

      if (cancel === 'discard') {
        model.discard()
        oracle.discard()
      } else {
        model.cancelReload()
        oracle.cancel()
      }

      await expect(settle(request, 'resolve', '<page><p>Remote</p></page>', 2)).resolves.toBeUndefined()
      expectSame(model, oracle)
    }
  })

  test('a read cannot move the revision backwards', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 5)
    const oracle = new DraftOracle('page-a', '<page><p>A0</p></page>', 5)
    const request = deferredRequest(model, oracle.start(), oracle.state.xml)

    await expect(settle(request, 'resolve', '<page><p>Older</p></page>', 4)).resolves.toBeUndefined()
    expectSame(model, oracle)
  })

  test('a current read applies and clears the conflict', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 1)
    model.conflict.value = true
    const oracle = new DraftOracle()
    oracle.state.conflict = true
    const request = deferredRequest(model, oracle.start(), oracle.state.xml)

    await expect(settle(request, 'resolve', '<page><p>A1</p></page>', 2)).resolves.toBe('<page><p>A1</p></page>')
    expect(oracle.apply(request, '<page><p>A1</p></page>', 2)).toBe(true)
    expectSame(model, oracle)
  })

  test('a stale rejection is swallowed while a current one is rethrown', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 1)
    const oracle = new DraftOracle()
    const stale = deferredRequest(model, oracle.start(), oracle.state.xml)
    model.xml.value = '<page><p>Edited</p></page>'
    oracle.edit(model.xml.peek())

    stale.reject(new Error('network'))
    await expect(stale.promise).resolves.toBeUndefined()

    const current = deferredRequest(model, oracle.start(), oracle.state.xml)
    current.reject(new Error('network'))
    await expect(current.promise).rejects.toThrow('network')
  })

  test('a stale save cannot lower the baseline through an already started read', async () => {
    const model = new PageDraftModel()
    model.load('page-a', '<page><p>A0</p></page>', 1)
    const oracle = new DraftOracle()
    const request = deferredRequest(model, oracle.start(), oracle.state.xml)

    model.saved('<page><p>A0</p></page>', 3, false)
    oracle.save('<page><p>A0</p></page>', 3)

    await expect(settle(request, 'resolve', '<page><p>A0</p></page>', 2)).resolves.toBeUndefined()
    expectSame(model, oracle)
    expect(model.revision.peek()).toBe(3)
  })

  test('random interleavings keep the draft oracle and the signals model in step', async () => {
    const seed = 0x5eed
    const random = mulberry32(seed)

    for (let run = 0; run < 200; run++) {
      const model = new PageDraftModel()
      model.load('page-a', '<page><p>A0</p></page>', 1)
      const oracle = new DraftOracle()
      const pending: Request[] = []
      const pages = ['page-a', 'page-b', 'page-c']
      let token = 0

      for (let step = 0; step < 30; step++) {
        const action = Math.floor(random() * 10)
        if (action < 3) {
          const xml = `<page><p>edit-${token++}</p></page>`
          model.xml.value = xml
          oracle.edit(xml)
        } else if (action === 3) {
          const revision = oracle.state.revision + Math.floor(random() * 3)
          model.saved(model.xml.peek(), revision, false)
          oracle.save(model.xml.peek(), revision)
        } else if (action === 4) {
          const page = pages[Math.floor(random() * pages.length)]
          const content = `<page><p>${page}-${token++}</p></page>`
          const revision = Math.floor(random() * 10)
          model.load(page, content, revision)
          oracle.load(page, content, revision)
        } else if (action === 5) {
          model.discard()
          oracle.discard()
        } else if (action === 6) {
          model.cancelReload()
          oracle.cancel()
        } else if (action === 7) {
          pending.push(deferredRequest(model, oracle.start(), oracle.state.xml))
        } else {
          const request = pending.shift()
          if (!request) continue
          const content = `<page><p>remote-${token++}</p></page>`
          const revision = Math.floor(random() * 12)
          const applied = oracle.apply(request, content, revision)
          await settle(request, 'resolve', content, revision)
          if (applied) expect(model.xml.peek()).toBe(content)
        }

        expectSame(model, oracle)
      }

      for (const request of pending) {
        request.reject(new Error('sequence finished'))
        await request.promise.catch(() => undefined)
      }
    }
  })
})

function mulberry32(seed: number) {
  return function () {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}
