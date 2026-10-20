import { GardSelection, Transaction } from '../state'
import browser from './browser'
import type { Wordgard } from './editor'
import { DOMNode, hasSelection, getSelection, DOMSelectionState, SelectionRange, isEquivalentPosition } from './dom'
import { Tile, WidgetTile } from './tile'
import { readDOMSelection, selectionFromTouch } from './selection'
import { addRange } from './changes'

// Marks a transaction whose selection was read from the DOM selection.
export const selectionFromDOM = Transaction.Annotation.define<boolean>()

const observeOptions = {
  childList: true,
  characterData: true,
  subtree: true,
  attributes: true,
  characterDataOldValue: true
}

export class DOMObserver {
  dom: HTMLElement
  win: Window | null = null

  observer: MutationObserver
  active: boolean = false

  // The known selection. Kept in our own object, as opposed to just
  // directly accessing the selection because:
  //  - Safari doesn't provide getSelection in shadow DOM
  //  - Reading from the selection forces a DOM layout
  //  - By tracking this, we can ignore selectionchange events if we
  //    have already seen the 'new' selection
  selectionRange: DOMSelectionState = new DOMSelectionState()
  selectionChanged = false

  resizeTimeout = -1
  queue: MutationRecord[] = []

  // Ranges (refering to positions in the flushed document) that need
  // to be re-checked because their DOM changed, if any are known.
  dirty: number[] | null = null

  scrollTargets: HTMLElement[] = []
  resizeScroll: ResizeObserver | null = null
  darkThemeQuery: MediaQueryList | null = null

  constructor(private wg: Wordgard) {
    this.dom = wg.contentDOM
    this.observer = new MutationObserver(mutations => {
      for (const mut of mutations) this.queue.push(mut)
      this.wg.scheduleFlush()
    })

    this.onSelectionChange = this.onSelectionChange.bind(this)
    this.onResize = this.onResize.bind(this)
    this.onScroll = this.onScroll.bind(this)
    this.onColorSchemeChange = this.onColorSchemeChange.bind(this)

    if (typeof ResizeObserver == 'function') {
      let lastFlushSeen = 0
      this.resizeScroll = new ResizeObserver(() => {
        if (this.wg.lastFlush != lastFlushSeen) {
          lastFlushSeen = this.wg.lastFlush
          this.onResize()
        }
      })
    }
    this.readSelectionRange()
  }

  connect() {
    this.observer.observe(this.dom, observeOptions)
    this.resizeScroll?.observe(this.dom)
    for (let dom = this.dom as any; dom;) {
      if (dom.nodeType == 1) {
        this.scrollTargets.push(dom)
        dom.addEventListener('scroll', this.onScroll)
        dom = dom.assignedSlot || dom.parentNode
      } else if (dom.nodeType == 11) {
        // Shadow root
        dom = dom.host
      } else {
        break
      }
    }
    const win = (this.win = this.wg.win)
    win.addEventListener('resize', this.onResize)
    win.addEventListener('scroll', this.onScroll)
    win.document.addEventListener('selectionchange', this.onSelectionChange)
    if (typeof win.matchMedia == 'function') {
      this.darkThemeQuery = win.matchMedia('(prefers-color-scheme: dark)')
      this.onColorSchemeChange()
      this.darkThemeQuery.addEventListener('change', this.onColorSchemeChange)
    }
  }

  disconnect() {
    this.observer.disconnect()
    this.resizeScroll?.disconnect()
    for (const dom of this.scrollTargets) dom.removeEventListener('scroll', this.onScroll)
    this.scrollTargets = []
    clearTimeout(this.resizeTimeout)
    if (this.win) {
      this.win.removeEventListener('scroll', this.onScroll)
      this.win.removeEventListener('resize', this.onResize)
      this.win.document.removeEventListener('selectionchange', this.onSelectionChange)
      this.win = null
    }
    if (this.darkThemeQuery) {
      this.darkThemeQuery.removeEventListener('change', this.onColorSchemeChange)
      this.darkThemeQuery = null
    }
  }

  onScroll(e: Event) {
    this.wg.inputState.runHandlers('scroll', e)
  }

  onResize() {
    if (this.resizeTimeout < 0) {
      this.resizeTimeout = window.setTimeout(() => {
        this.resizeTimeout = -1
        this.wg.scheduleFlush()
      }, 50)
    }
  }

  onColorSchemeChange() {
    this.wg.configureColorScheme(this.darkThemeQuery!.matches ? 'dark' : 'light')
  }

  onSelectionChange() {
    this.readSelectionRange()
    if (this.selectionChanged) this.wg.scheduleFlush()
  }

  pollSelection() {
    const { wg } = this
    if (this.selectionChanged && (wg.hasFocus || !wg.focusable) && hasSelection(wg.contentDOM, this.selectionRange)) {
      this.selectionChanged = false
      const fromTouch = wg.inputState.lastTouchTime > Date.now() - 100
      let sel: GardSelection = readDOMSelection(wg, this.selectionRange)
      if (!sel.eqPos(wg.state.selection)) {
        let userEvent = 'select'
        if (fromTouch) {
          userEvent = 'select.pointer'
          const event = wg.inputState.lastTouchEvent!
          if (event.touches.length == 1 && sel.isCursor) sel = selectionFromTouch(event, wg)
        }
        wg.dispatch({ selection: sel, userEvent, annotations: selectionFromDOM.of(true) })
      }
    }
  }

  // A pending transaction sets a selection that the DOM does not show
  // yet. Reading the DOM selection would undo it. Selections that were
  // read from the DOM do not count: the DOM selection can only be newer.
  get editorSelectionPending() {
    return this.wg.viewState.pending.some(tr => tr.selection && !tr.annotation(selectionFromDOM))
  }

  readSelectionRange() {
    const { wg } = this
    // The Selection object is broken in shadow roots in Safari. See
    // https://github.com/codemirror/dev/issues/414
    const selection = getSelection(wg.root)
    if (!selection) return false
    let range: SelectionRange = selection
    if (browser.safari && (wg.root as any).nodeType == 11 && wg.root.activeElement == this.dom) {
      // Used to work around a Safari Selection/shadow DOM bug (#414)
      const selRange = (selection as any).getComposedRanges(wg.root)[0] as StaticRange
      if (selRange) range = buildSelectionRangeFromRange(wg, selRange)
    }
    if (!range || !range.focusNode || this.selectionRange.eq(range)) return false
    const context = range.anchorNode && wg.docTile.nearest(range.anchorNode)
    if (context instanceof WidgetTile) return false

    this.selectionRange.setRange(range)
    return (this.selectionChanged = true)
  }

  setSelectionRange(anchor: { dom: DOMNode; offset: number }, head: { dom: DOMNode; offset: number }) {
    this.selectionRange.set(anchor.dom, anchor.offset, head.dom, head.offset)
    this.selectionChanged = false
  }

  ignore<T>(f: () => T): T {
    const result = f()
    this.clear()
    return result
  }

  // Throw away any pending changes
  clear() {
    this.takeRecords()
    this.readSelectionRange()
  }

  takeRecords() {
    const records = this.pendingRecords()
    if (records.length) this.queue = []
    return records
  }

  // The mutation records that the next flush processes. Does not take them.
  pendingRecords(): readonly MutationRecord[] {
    for (const mut of this.observer.takeRecords()) this.queue.push(mut)
    return this.queue
  }

  addDirtyRange(from: number, to: number) {
    addRange(this.dirty || (this.dirty = []), from, to)
  }

  processRecords(records: readonly MutationRecord[]) {
    for (const record of records) {
      const range = this.findMutation(record)
      if (range) this.addDirtyRange(range[0], range[1])
    }
  }

  findMutation(record: MutationRecord): [number, number] | null {
    const tile = this.wg.docTile.nearest(record.target)
    if (!tile || tile.ignoreMutations) return null
    tile.markDirty()
    if (record.type == 'attributes' || record.type == 'characterData') {
      if (tile == this.wg.docTile) {
        return null
      } else if (tile.dom == record.target) {
        return [tile.posBefore, tile.posAfter]
      } else {
        return childRange(tile, record)
      }
    } else if (record.type == 'childList') {
      return childRange(tile, record)
    } else {
      return null
    }
  }

  takeDirty() {
    this.processRecords(this.takeRecords())
    const { dirty } = this
    this.dirty = null
    return dirty
  }
}

function childRange(tile: Tile, record: MutationRecord): [number, number] {
  const childBefore = findChild(tile, record.previousSibling || record.target.previousSibling, -1)
  const childAfter = findChild(tile, record.nextSibling || record.target.nextSibling, 1)
  return [
    childBefore ? tile.posBeforeChild(childBefore) + childBefore.length : tile.posAtStart,
    childAfter ? tile.posBeforeChild(childAfter) : tile.posAtEnd
  ]
}

function findChild(elt: Tile, dom: Node | null, dir: number): Tile | null {
  while (dom) {
    const cur = Tile.get(dom)
    if (cur && cur.parent == elt) return cur
    const parent = dom.parentNode
    dom = parent != elt.dom ? parent : dir > 0 ? dom.nextSibling : dom.previousSibling
  }
  return null
}

function buildSelectionRangeFromRange(wg: Wordgard, range: StaticRange) {
  let anchorNode = range.startContainer,
    anchorOffset = range.startOffset
  let focusNode = range.endContainer,
    focusOffset = range.endOffset
  const curAnchor = wg.docTile.resolve(wg.state.selection.anchor, -1)
  // Since such a range doesn't distinguish between anchor and head,
  // use a heuristic that flips it around if its end matches the
  // current anchor.
  if (isEquivalentPosition(curAnchor.dom, curAnchor.offset, focusNode, focusOffset)) {
    ;[anchorNode, anchorOffset, focusNode, focusOffset] = [focusNode, focusOffset, anchorNode, anchorOffset]
  }
  return { anchorNode, anchorOffset, focusNode, focusOffset }
}
