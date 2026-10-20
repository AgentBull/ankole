import { Set } from './set'

function heapBubble<T>(heap: T[], index: number, cmp: (a: T, b: T) => number) {
  for (const cur = heap[index]!; ;) {
    let childIndex = (index << 1) + 1
    if (childIndex >= heap.length) break
    let child = heap[childIndex]
    if (childIndex + 1 < heap.length && cmp(child!, heap[childIndex + 1]!) >= 0) {
      child = heap[childIndex + 1]
      childIndex++
    }
    if (cmp(cur, child!) < 0) break
    heap[childIndex] = cur!
    heap[index] = child!
    index = childIndex
  }
}

function heapSink<T>(heap: T[], index: number, cmp: (a: T, b: T) => number) {
  const elt = heap[index]!
  while (index > 0) {
    const parent = (index - 1) >> 1
    if (cmp(heap[parent]!, elt) < 0) break
    heap[index] = heap[parent]!
    heap[parent] = elt!
    index = parent
  }
}

function heapPop<T>(heap: T[], cmp: (a: T, b: T) => number) {
  const last = heap.pop()!
  if (heap.length) {
    heap[0] = last
    heapBubble(heap, 0, cmp)
  }
}

export class HeapCursor<T> implements Set.Cursor<T> {
  heap: Set.Cursor<T>[] = []
  declare from: number
  declare to: number
  declare value: T | null

  constructor(
    readonly cmp: (a: Set.Cursor<T>, b: Set.Cursor<T>) => number,
    readonly cursors: readonly Set.Cursor<T>[]
  ) {
    for (const cur of cursors) {
      if (cur.value) {
        this.heap.push(cur)
        heapSink(this.heap, this.heap.length - 1, cmp)
      }
    }
    this.fill()
  }

  fill() {
    if (this.heap.length) {
      ;({ from: this.from, to: this.to, value: this.value } = this.heap[0]!)
    } else {
      this.from = this.to = 1e9
      this.value = null
    }
  }

  goto(pos: number, side?: number) {
    this.heap = []
    for (const cur of this.cursors) {
      cur.goto(pos, side)
      if (cur.value) {
        this.heap.push(cur)
        heapSink(this.heap, this.heap.length - 1, this.cmp)
      }
    }
    this.fill()
  }

  next() {
    if (this.heap.length) {
      this.heap[0]!.next()
      if (this.heap[0]!.value) heapBubble(this.heap, 0, this.cmp)
      else heapPop(this.heap, this.cmp)
      this.fill()
    }
  }

  get set() {
    return this.heap.length ? this.heap[0]!.set : null
  }
}
