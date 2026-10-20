import { ChangeSet } from '../doc'
import { GardState, Transaction } from '../state'
import type { Wordgard } from './editor'

export enum UpdateFlag {
  Focus = 1,
  Geometry = 2
}

export const scrollIntoView = Transaction.Effect.define<ScrollTarget>({ map: (t, ch) => t.map(ch) })

const selectionScrollSpec: Required<Wordgard.ScrollSpec> = {
  x: 'nearest',
  y: 'nearest',
  xMargin: 5,
  yMargin: 5
}

export class ScrollTarget {
  constructor(
    readonly from: number,
    readonly to: number,
    // If from == to, this indicates the direction to map the position
    // in. Otherwise, it tells which side of the range is the head
    // (more important) side.
    readonly assoc: -1 | 1,
    readonly spec: Required<Wordgard.ScrollSpec>
  ) {}

  map(changes: ChangeSet) {
    if (changes.empty) return this
    let from: number, to: number
    if (this.from == this.to) {
      from = to = changes.mapPos(this.from, this.assoc)
    } else {
      from = changes.mapPos(this.from, 1)
      to = Math.max(from, changes.mapPos(this.to, -1))
    }
    return new ScrollTarget(from, to, this.assoc, this.spec)
  }

  clip(state: GardState) {
    const len = state.doc.length
    return this.to <= len
      ? this
      : new ScrollTarget(Math.min(len, this.from), Math.min(len, this.to), this.assoc, this.spec)
  }
}

export class ViewState {
  initialized = false
  contentDOMWidth = 0 // contentDOM.getBoundingClientRect().width
  contentDOMHeight = 0 // contentDOM.getBoundingClientRect().height
  editorHeight = 0 // scrollDOM.clientHeight
  editorOffset = 0 // scrollDOM.offsetTop
  editorWidth = 0 // scrollDOM.clientWidth
  // A scroll target that hasn't been scrolled to yet
  scrollTarget: ScrollTarget | null = null

  styleLTR: boolean = true

  flushedState: GardState
  pending: Transaction[] = []

  constructor(public state: GardState) {
    this.flushedState = state
  }

  update(tr: Transaction) {
    if (this.scrollTarget) this.scrollTarget = this.scrollTarget.map(tr.changes)
    if (tr.scrollIntoView) {
      const { selection: sel } = tr.state
      this.scrollTarget = new ScrollTarget(sel.head, sel.head, sel.headSide, selectionScrollSpec)
    }
    for (const e of tr.effects) if (e.is(scrollIntoView)) this.scrollTarget = e.value.clip(this.state)
    if (tr.startState != this.state) throw new Error('Mismatched transaction')
    this.pending = this.pending.concat(tr)
    this.state = tr.state
  }

  flush() {
    this.flushedState = this.state
    this.pending = []
  }

  measure(wg: Wordgard) {
    const dom = wg.contentDOM,
      style = window.getComputedStyle(dom)
    this.styleLTR = style.direction == 'ltr'

    let result = 0
    const domRect = dom.getBoundingClientRect()
    if (Math.abs(this.contentDOMHeight - domRect.height) > 0.5) {
      result |= UpdateFlag.Geometry
      this.contentDOMHeight = domRect.height
    }

    if (this.editorWidth != wg.scrollDOM.clientWidth) {
      this.editorWidth = wg.scrollDOM.clientWidth
      result |= UpdateFlag.Geometry
    }

    const contentWidth = domRect.width
    if (
      Math.abs(this.contentDOMWidth - contentWidth) > 0.5 ||
      this.editorHeight != wg.scrollDOM.clientHeight ||
      this.editorOffset != wg.scrollDOM.offsetTop
    ) {
      this.contentDOMWidth = domRect.width
      this.editorHeight = wg.scrollDOM.clientHeight
      this.editorOffset = wg.scrollDOM.offsetTop
      result |= UpdateFlag.Geometry
    }
    return result
  }

  initialMeasure(wg: Wordgard) {
    this.initialized = true
    const domRect = wg.contentDOM.getBoundingClientRect()
    this.contentDOMWidth = domRect.width
    this.contentDOMHeight = domRect.height
    this.editorHeight = wg.scrollDOM.clientHeight
    this.editorWidth = wg.scrollDOM.clientWidth
  }
}
