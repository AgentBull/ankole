import { describe, it } from 'bun:test'
import { GardState, Transaction, Correction } from '../../src/core/state'
import { Leaf, type ChangeSet, Plot } from '../../src/core/doc'
import { Paragraph, Strong } from '../../src/core/types'
import { basicBuilders, eq } from './schema'
import { history, undo, redo } from '../../src/core/history'
import ist from 'ist'
import { collab } from '../../src/core/collab'

const { doc, p } = basicBuilders

class DummyServer {
  states: GardState[] = []
  updates: (collab.Update & { doc: Plot.Doc })[] = []
  doc: Plot.Doc
  version = 0
  delayed: number[] = []
  transform: boolean
  passive: boolean
  corrections: readonly Correction[] | undefined

  constructor(
    d: string = '',
    config: {
      n?: number
      extension?: GardState.Extension
      collabConf?: any
      transform?: boolean
      passive?: boolean
      corrections?: readonly Correction[]
    } = {}
  ) {
    this.doc = doc(p(d))
    this.transform = !!config.transform
    this.passive = !!config.passive
    this.corrections = config.corrections
    const { n = 2, extension = [], collabConf = {} } = config
    for (let i = 0; i < n; i++) {
      this.states.push(
        GardState.create({
          doc: this.doc,
          config: [history(), collab({ clientID: `c-${i}`, corrections: this.corrections, ...collabConf }), extension]
        })
      )
    }
  }

  sync(client: number) {
    const state = this.states[client]!,
      version = collab.getSyncedVersion(state)
    if (version != this.version) this.states[client] = collab.receive(state, this.updates.slice(version)).state
  }

  send(client: number) {
    const state = this.states[client]!
    let sendable = collab.sendableUpdate(state)
    if (!sendable) return false
    if (sendable.version != this.version) {
      if (!this.transform) return true
      sendable = collab.transformUpdate(sendable, this.updates.slice(sendable.version), this.corrections)
      if (!sendable) return true
    }
    this.updates.push({ ...sendable, doc: this.doc })
    this.doc = sendable.changes.apply(this.doc)
    this.version++
    return true
  }

  broadcast(client: number) {
    if (this.passive || this.delayed.indexOf(client) > -1) return
    this.sync(client)
    this.send(client)
    for (let i = 0; i < this.states.length; i++) if (i != client) this.sync(i)
  }

  update(client: number, f: (state: GardState) => Transaction | Transaction.Spec) {
    const state = this.states[client]!
    let tr = f(state)
    if (!(tr instanceof Transaction)) tr = state.update(tr)
    this.states[client] = (tr as Transaction).state
    this.broadcast(client)
  }

  type(client: number, text: string, pos: number = this.states[client]!.selection.head) {
    this.update(client, s =>
      s.update({ changes: { from: pos, insert: [Leaf.text(text)] }, selection: { anchor: pos + text.length } })
    )
  }

  undo(client: number) {
    const tr = undo({ state: this.states[client]! }, null)
    if (tr) this.update(client, () => tr)
  }

  redo(client: number) {
    const tr = redo({ state: this.states[client]! }, null)
    if (tr) this.update(client, () => tr)
  }

  syncAll() {
    let i = 0
    for (;;) {
      if (i++ > 20) throw new Error(`woah ${this.doc}`)
      let done = true
      for (let c = 0; c < this.states.length; c++) if (this.send(c)) done = false
      for (let c = 0; c < this.states.length; c++) this.sync(c)
      if (done) break
    }
  }

  conv(expect: string) {
    this.states.forEach(state => ist(state.doc, doc(expect ? p(expect) : p()), eq))
  }

  delay(client: number, f: () => void) {
    this.delayed.push(client)
    f()
    this.delayed.pop()
    this.broadcast(client)
  }
}

describe('collab', () => {
  it('converges for simple changes', () => {
    const s = new DummyServer()
    s.type(0, 'hi')
    s.type(1, 'ok', 3)
    s.type(0, '!', 5)
    s.type(1, '...', 1)
    s.conv('...hiok!')
  })

  it('converges for multiple local changes', () => {
    const s = new DummyServer()
    s.type(0, 'hi')
    s.delay(0, () => {
      s.type(0, 'A')
      s.type(1, 'X', 3)
      s.type(0, 'B')
      s.type(1, 'Y')
    })
    s.conv('hiXYAB')
  })

  it('converges with three peers', () => {
    const s = new DummyServer(undefined, { n: 3 })
    s.type(0, 'A')
    s.type(1, 'U')
    s.type(2, 'X')
    s.type(0, 'B')
    s.type(1, 'V')
    s.type(2, 'Y')
    s.conv('XYUVAB')
  })

  it('converges with three peers with multiple steps', () => {
    const s = new DummyServer(undefined, { n: 3 })
    s.type(0, 'A')
    s.delay(1, () => {
      s.type(1, 'U')
      s.type(2, 'X')
      s.type(0, 'B')
      s.type(1, 'V')
      s.type(2, 'Y')
    })
    s.conv('XYUVAB')
  })

  it('supports undo', () => {
    const s = new DummyServer()
    s.type(0, 'A')
    s.type(1, 'a')
    s.type(0, 'B')
    s.undo(1)
    s.conv('AB')
    s.type(1, 'b')
    s.type(0, 'C')
    s.conv('bABC')
  })

  it('supports redo', () => {
    const s = new DummyServer()
    s.type(0, 'A')
    s.type(1, 'a')
    s.type(0, 'B')
    s.undo(1)
    s.redo(1)
    s.type(1, 'b')
    s.type(0, 'C')
    s.conv('abABC')
  })

  it('supports deep undo', () => {
    const s = new DummyServer('hello bye')
    s.update(0, s => s.update({ selection: { anchor: 6 } }))
    s.update(1, s => s.update({ selection: { anchor: 10 } }))
    s.type(0, '!')
    s.type(1, '!')
    s.update(0, s => s.update({ annotations: history.isolate.of(true) }))
    s.delay(0, () => {
      s.type(0, ' ...')
      s.type(1, ' ,,,')
    })
    s.update(0, s => s.update({ annotations: history.isolate.of(true) }))
    s.type(0, '*')
    s.type(1, '*')
    s.undo(0)
    s.conv('hello! ... bye! ,,,*')
    s.undo(0)
    s.undo(0)
    s.conv('hello bye! ,,,*')
    s.redo(0)
    s.redo(0)
    s.redo(0)
    s.conv('hello! ...* bye! ,,,*')
    s.undo(0)
    s.undo(0)
    s.conv('hello! bye! ,,,*')
    s.undo(1)
    s.conv('hello! bye')
  })

  it('support undo with clashing events', () => {
    const s = new DummyServer('okay!')
    s.type(0, 'A', 6)
    s.delay(0, () => {
      s.type(0, 'B', 4)
      s.type(0, 'C', 5)
      s.type(0, 'D', 1)
      s.update(1, s => s.update({ changes: { from: 2, to: 5 } }))
    })
    s.conv('DoBC!A')
    s.undo(0)
    s.undo(0)
    s.conv('o!A')
    ist(s.states[0]!.selection.head, 4)
  })

  it('can distribute mark changes', () => {
    const s = new DummyServer('xyz')
    s.update(0, s => s.update({ changes: { from: 1, to: 3, add: Strong } }))
    ist(s.states[1]!.doc, s.states[0]!.doc, eq)
  })

  it('handles conflicting steps', () => {
    const s = new DummyServer('abcde')
    s.delay(0, () => {
      s.update(0, s => s.update({ changes: { from: 3, to: 4 } }))
      s.type(0, 'x')
      s.update(1, s => s.update({ changes: { from: 2, to: 5 } }))
    })
    s.undo(0)
    s.undo(0)
    s.conv('ace')
  })

  it('can undo simultaneous typing', () => {
    const s = new DummyServer('A B')
    s.delay(0, () => {
      s.type(0, '1', 2)
      s.type(0, '2')
      s.type(1, 'x', 4)
      s.type(1, 'y')
    })
    s.conv('A12 Bxy')
    s.undo(0)
    s.conv('A Bxy')
    s.undo(1)
    s.conv('A B')
  })

  it('allows you to set the initial version', () => {
    ist(collab.getSyncedVersion(GardState.create({ doc: doc(p()), config: [collab({ startVersion: 20 })] })), 20)
  })

  it('client ids survive reconfiguration', () => {
    const ext = collab()
    const state = GardState.create({ doc: doc(p()), config: [ext] })
    const state2 = state.update({ effects: GardState.reconfigure.of(ext) }).state
    ist(collab.getClientID(state), collab.getClientID(state2))
  })

  it('supports shared effects', () => {
    class Mark {
      from: number
      to: number
      id: string

      constructor(from: number, to: number, id: string) {
        this.from = from
        this.to = to
        this.id = id
      }

      map(mapping: ChangeSet) {
        const from = mapping.mapPos(this.from, 1),
          to = mapping.mapPos(this.to, -1)
        return from >= to ? undefined : new Mark(from, to, this.id)
      }

      toString() {
        return `${this.from}-${this.to}=${this.id}`
      }
    }
    const addMark = Transaction.Effect.define<Mark>({ map: (v, m) => v.map(m) })
    const marks = GardState.Field.define<Mark[]>({
      create: () => [],
      update(value, tr) {
        value = value.map(m => m.map(tr.changes)).filter(x => x) as any
        for (const effect of tr.effects) if (effect.is(addMark)) value = value.concat(effect.value)
        return value.sort((a, b) => (a.id < b.id ? -1 : 1))
      }
    })

    const s = new DummyServer('hello', {
      extension: marks,
      collabConf: {
        sharedEffects(tr: Transaction) {
          return tr.effects.filter(e => e.is(addMark))
        }
      }
    })
    s.delay(0, () => {
      s.delay(1, () => {
        s.update(0, s => s.update({ effects: addMark.of(new Mark(2, 4, 'a')) }))
        s.update(1, s => s.update({ effects: addMark.of(new Mark(4, 6, 'b')) }))
        s.type(0, 'A', 5)
        s.type(1, 'B', 1)
        ist(s.states[0]!.field(marks).join(), '2-4=a')
        ist(s.states[1]!.field(marks).join(), '5-7=b')
      })
    })
    s.conv('BhellAo')
    ist(s.states[0]!.field(marks).join(), '3-5=a,5-8=b')
    ist(s.states[1]!.field(marks).join(), '3-5=a,5-8=b')
  })

  it('holds up on random input', () => {
    const r = (n: number) => Math.floor(Math.random() * n)
    for (let i = 0; i < 100; i++) {
      const n = 3,
        s = new DummyServer('abcd', { n, transform: !r(2), passive: true })
      for (let j = 0; j < 25; j++) {
        const client = r(n),
          sel = r(4),
          len = s.states[client]!.doc.length
        if (sel == 0) {
          s.send(client)
        } else if (sel == 1) {
          s.sync(client)
        } else if (sel == 2) {
          const ch = String.fromCharCode(65 + r(26)),
            pos = 1 + r(len - 2)
          s.type(client, ch, pos)
        } else if (len > 2) {
          const from = 1 + r(len - 3),
            to = from + 1 + r(len - 2 - from)
          s.update(client, s => s.update({ changes: { from, to } }))
        }
      }
      s.syncAll()
      for (let c = 1; c < n; c++) s.conv(s.states[0]!.doc.textContent())
    }
  })

  it('can handle corrections kicking in for merged steps', () => {
    const shortPara = Correction.onChildList(Paragraph, plot => {
      return plot.node.contentLength <= 5 ? null : { from: plot.start + 5, to: plot.end }
    })
    const s = new DummyServer('abcd', { extension: shortPara, corrections: [shortPara] })
    s.delay(0, () => {
      s.type(0, 'x', 5)
      s.type(1, 'y', 5)
    })
    s.conv('abcdy')
  })

  it('can apply corrections eagerly', () => {
    const evenPara = Correction.onChildList(Paragraph, pos => {
      return pos.node.contentLength % 2 ? { from: pos.end, insert: [Leaf.text('-')] } : null
    })
    const s = new DummyServer('abcd', {
      n: 2,
      passive: true,
      corrections: [evenPara],
      extension: evenPara,
      transform: true
    })
    s.type(0, 'e', 5)
    s.syncAll()
    s.conv('abcde-')
    s.update(0, s => s.update({ changes: { from: 1, to: 2, insert: [Leaf.text('x')] } }))
    s.update(1, s => s.update({ changes: { from: 1, to: 2, insert: [Leaf.text('y')] } }))
    s.syncAll()
    s.conv('xybcde--')
  })
})
