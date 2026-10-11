import { describe, it } from 'bun:test'
import ist from 'ist'
import { PointSet } from '../../src/core/set'
import { ChangeSet } from '../../src/core/doc'

class V implements PointSet.Value {
  name: string
  side: number

  constructor(name = 'x', side = 0) {
    this.name = name
    this.side = side
  }

  eq(other: PointSet.Value): boolean {
    return other instanceof V && other.side == this.side && other.name == this.name
  }

  get trackMode() {
    return 'around' as const
  }

  static a = new V('a')
  static b = new V('b')
  static c = new V('c')
}

function str(set: PointSet<V>) {
  const values: string[] = []
  for (const c = set.cursor(); c.value; c.next()) values.push(`${c.value.name}@${c.from}`)
  return values.join(' ')
}

describe('PointSet', () => {
  it('stores points and values', () => {
    ist(
      str(
        PointSet.create([
          [V.a, 0],
          [V.b, 4]
        ])
      ),
      'a@0 b@4'
    )
  })

  it('checks order on creation', () => {
    ist.throws(
      () =>
        PointSet.create([
          [V.a, 2],
          [V.a, 1]
        ]),
      /Points must be added in order/
    )
  })

  it('can add to', () => {
    ist(
      str(
        PointSet.create([
          [V.a, 0],
          [V.a, 3]
        ]).modify({ add: [[V.b, 2]] })
      ),
      'a@0 b@2 a@3'
    )
  })

  it('can filter', () => {
    ist(
      str(
        PointSet.create([
          [V.a, 0],
          [V.b, 1],
          [V.a, 3],
          [V.b, 4]
        ]).modify({ filter: (v, p) => !(p % 2) })
      ),
      'a@0 b@4'
    )
  })

  it('can be mapped', () => {
    let ps = PointSet.create<V>(add => {
      for (let i = 0; i < 12; i += 2) add(new V(`v${i / 2}`, 1), i)
    })
    ps = ps.map(ChangeSet.new([3, 0, 2, -1, 0, 2, 3, -1, 0, 1, 5, -1], []))
    ist(str(ps), 'v0@0 v2@1 v3@5 v4@8 v5@10')
  })

  it('can be mapped with negative side', () => {
    let ps = PointSet.create<V>([[new V('x', -1), 2]])
    ps = ps.map(ChangeSet.new([2, -1, 0, 2, 2, -1], []))
    ist(str(ps), 'x@2')
  })

  it('properly maps points at the end of the document', () => {
    ist(str(PointSet.create([[V.a, 4]]).map(ChangeSet.new([0, 1, 4, -1], []))), 'a@5')
  })

  it('can map with replacements', () => {
    const set = PointSet.create<V>(add => {
      for (let i = 0; i <= 20; i += 2) add(new V(`p${i}`), i)
    })
    ist(
      str(set.map(ChangeSet.new([6, -1, 8, 4, 6, -1], []), [{ from: 4, to: 12, add: [[V.a, 8]] }])),
      'p0@0 p2@2 a@8 p18@14 p20@16'
    )
  })

  const chunkSize = 512

  it('preserves whole chunks during mapping', () => {
    const ps = PointSet.create<V>(add => {
      for (let i = 0; i < chunkSize * 2; i++) add(V.a, i)
    })
    const ps2 = ps.map(ChangeSet.new([chunkSize + 10, -1, 10, 0, chunkSize, -1], []))
    ist(ps.chunks[0]!.value, ps2.chunks[0]!.value)
  })

  it('can handle order change during mapping', () => {
    const set = PointSet.create<V>([
      [new V('a', 1), 0],
      [new V('b', -1), 1]
    ])
    ist(str(set.map(ChangeSet.new([1, 0], []))), 'b@0 a@0')
  })

  it('can compare sets', () => {
    const diff: number[] = []
    PointSet.create([
      [V.a, 0],
      [V.b, 2],
      [V.c, 4]
    ]).compareRange(
      0,
      PointSet.create([
        [V.a, 1],
        [V.b, 3],
        [V.a, 3],
        [V.c, 6]
      ]),
      1,
      20,
      p => diff.push(p)
    )
    ist(diff.join(), '3,5,6')
  })

  it('cheaply compares identical chunks', () => {
    const setA = PointSet.create<V>(add => {
      for (let i = 0; i < chunkSize * 3; i++) add(V.a, i)
    })
    const setB = setA.map(ChangeSet.new([0, 1, chunkSize * 3, -1], []))
    const target = setB.chunks[1]!
    const values = target.value
    let accessCount = 0
    Object.defineProperty(target, 'value', {
      get() {
        accessCount++
        return values
      }
    })
    setA.compareRange(0, setB, 1, chunkSize * 3, () => ist(false))
    ist(accessCount, 10, '<')
  })
})
