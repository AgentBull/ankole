import { GardSelection, GardState, Transaction } from '../state'
import { Plot, Leaf, ChangeSet, Mark, Slice, Pos, ValidationError } from '../doc'
import {
  Command,
  undo,
  redo,
  insertLineBreak,
  enter,
  insertText,
  deleteWord,
  deleteUnit,
  deleteToLineEnd,
  deleteLine,
  deleteCut,
  deleteRange,
  toggleEmphasis,
  toggleStrong,
  toggleUnderline,
  transposeChars,
  deleteSelection,
  setAlignment,
  setDirection
} from '../command'
import { findClusterBreak } from '@marijn/find-cluster-break'
import type { Wordgard } from './editor'
import { rangeForClick } from './selection'
import browser from './browser'
import { getSelection, scrollableParents, DOMNode, textNodeBefore, textNodeAfter, domIndex } from './dom'
import { readClipboard, writeClipboard } from './clipboard'
import { selectionFromDOM } from './domobserver'
import { eqArray, logException } from './util'
import { Tile, TextTile, WidgetTile, CoordPos } from './tile'
import { KeyBinding } from './keymap'

export const eventHandler = GardState.Facet.define<
  { event: string; handler: (event: Event, wg: Wordgard) => boolean | void },
  Record<string, ((event: Event, wg: Wordgard) => boolean | void)[]>
>({
  combine: handlers => {
    const result: Record<string, ((event: Event, wg: Wordgard) => boolean | void)[]> = Object.create(null)
    for (const { event, handler } of handlers) (result[event] || (result[event] = [])).push(handler)
    return result
  }
})

export const eventObserver = GardState.Facet.define<
  { event: string; observer: (event: Event, wg: Wordgard) => void },
  Record<string, ((event: Event, wg: Wordgard) => void)[]>
>({
  combine: observers => {
    const result: Record<string, ((event: Event, wg: Wordgard) => void)[]> = Object.create(null)
    for (const { event, observer } of observers) (result[event] || (result[event] = [])).push(observer)
    return result
  }
})

type InputEventData = {
  inputType: string
  data: string | null
  domRange: { from: number; to: number } | null
  // The browser applies this change, and the input handler reads it
  // from the DOM.
  readDOM: boolean
}

export class InputState {
  shiftKey = false
  lastKeyCode: number = 0
  lastKeyTime: number = 0
  lastTouchTime = 0
  lastTouchEvent: TouchEvent | null = null
  lastScrollTop = 0
  lastScrollLeft = 0

  lastContextMenu: number = 0
  scrollHandlers: ((event: Event) => boolean | void)[] = []

  handlers: {
    [event: string]: {
      observers: readonly HandlerFunction[]
      handlers: readonly HandlerFunction[]
    }
  } = Object.create(null)

  // Track the current composition. Count changes to determine whether
  // a given change is the first one, and track the text node that
  // composition is happening in.
  composing: null | { changes: number; target: Text | null } = null
  // End time of the previous composition
  compositionEndedAt = 0
  // Used in a kludge to detect when an Enter keypress should be
  // considered part of the composition on Safari, which fires events
  // in the wrong order
  compositionPendingKey = false
  wrappingComposition: Mark.Set | null = null

  mouseSelection: MouseSelection | null = null
  // When a drag from the editor is active, this points at the range
  // being dragged.
  draggedContent: GardSelection | null = null

  notifiedFocused: boolean
  suppressEvents = false

  // Between beforeinput and input events, this holds information
  // about the event (because input events no longer provide range
  // information).
  pendingInputEvent: InputEventData | null = null
  // When input events have changed the DOM, this holds the updated
  // document, which we need for the mapping done in `addDOMChange`.
  domDoc: Plot.Doc
  // Mapping between `domDoc` and `state.doc`. See getter.
  _domMapping: ChangeSet
  // Tracks up to which index of `viewState.pending` `_domMapping` has
  // been updated.
  domMappingIndex: number = 0
  // Mapping between the doc at the last flush and `domDoc`.
  domChanges: ChangeSet | null = null

  constructor(readonly wg: Wordgard) {
    this.handleEvent = this.handleEvent.bind(this)
    this.notifiedFocused = wg.hasFocus
    // On Safari adding an input event handler somehow prevents an
    // issue where the composition vanishes when you press enter.
    if (browser.safari) wg.contentDOM.addEventListener('input', () => null)
    this.domDoc = wg.state.doc
    this._domMapping = ChangeSet.empty(this.domDoc.length)
  }

  handleEvent(event: Event) {
    if (this.suppressEvents) return
    if (!eventBelongsToEditor(this.wg, event) || this.ignoreDuringComposition(event)) return
    if (event.type == 'keydown' && this.keydown(event as KeyboardEvent)) return
    if (event.type == 'keyup' && (event as KeyboardEvent).keyCode == 16) this.shiftKey = false
    if (event.type == 'beforeinput') {
      // The beforeinput handler sets this again when the browser applies the input.
      this.pendingInputEvent = null
      if (!this.composing && !/Composition/.test((event as InputEvent).inputType)) this.readNewSelection()
    }
    this.runHandlers(event.type, event)
  }

  // An event can arrive before the flush that reads a new DOM
  // selection (for example when Chromium sends a key before
  // `selectionchange`). Read the selection now, so that the event acts
  // on the visible caret.
  readNewSelection() {
    const { observer } = this.wg
    observer.readSelectionRange()
    // Do not flush: the event can refer to DOM that the browser has
    // just changed. A selection that the editor set and has not drawn
    // yet wins, as in a flush.
    if (!observer.editorSelectionPending) observer.pollSelection()
  }

  runHandlers(type: string, event: Event) {
    const handlers = this.handlers[type]
    if (handlers) {
      for (const observer of handlers.observers) observer(this.wg, event)
      for (const handler of handlers.handlers) {
        if (event.defaultPrevented) break
        if (handler(this.wg, event)) {
          event.preventDefault()
          break
        }
      }
    }
  }

  ensureHandlers(state: GardState) {
    const handlers = computeHandlers(state),
      prev = this.handlers,
      dom = this.wg.contentDOM
    for (const type in handlers) {
      if (type != 'scroll') {
        const passive = !handlers[type]!.handlers.length
        let exists: (typeof prev)['type'] | null = prev[type]!
        if (exists && passive != !exists.handlers.length) {
          dom.removeEventListener(type, this.handleEvent)
          exists = null
        }
        if (!exists) dom.addEventListener(type, this.handleEvent, { passive })
      }
    }
    for (const type in prev) if (type != 'scroll' && !handlers[type]) dom.removeEventListener(type, this.handleEvent)
    this.handlers = handlers
  }

  keydown(event: KeyboardEvent) {
    // Must always run, even if a custom handler handled the event
    this.lastKeyCode = event.keyCode
    this.lastKeyTime = Date.now()
    this.shiftKey = event.keyCode == 16 || event.shiftKey
    if (event.keyCode != 229) this.readNewSelection()
    return false
  }

  ignoreDuringComposition(event: Event): boolean {
    if (!event.type.startsWith('key')) return false
    if (this.composing && this.composing.changes) return true
    // See https://www.stum.de/2016/06/24/handling-ime-events-in-javascript/.
    // On some input method editors (IMEs), the Enter key is used to
    // confirm character selection. On Safari, when Enter is pressed,
    // compositionend and keydown events are sometimes emitted in the
    // wrong order. The key event should still be ignored, even when
    // it happens after the compositionend event.
    if (browser.safari && !browser.ios && this.compositionPendingKey && Date.now() - this.compositionEndedAt < 100) {
      this.compositionPendingKey = false
      return true
    }
    return false
  }

  startMouseSelection(mouseSelection: MouseSelection) {
    if (this.mouseSelection) this.mouseSelection.disconnect()
    this.mouseSelection = mouseSelection
  }

  update(update: Wordgard.Update) {
    if (this.mouseSelection) this.mouseSelection.update(update)
    if (this.draggedContent && update.docChanged) {
      this.draggedContent = this.draggedContent.map(update.changes, update.state)
    }
    if (update.transactions.length) this.lastKeyCode = 0
    this.domDoc = update.state.doc
    this._domMapping = ChangeSet.empty(this.domDoc.length)
    this.domMappingIndex = 0
    this.domChanges = null
  }

  // Create a position in `domDoc` from a DOM position. Needed in
  // order to interpret `beforeinput` event ranges and other DOM
  // positions when there are unflushed DOM changes.
  getDOMPos(node: Node, offset: number) {
    if (!this.domChanges) return this.wg.docTile.posFromDOM(node, offset)
    if (node.nodeType == 1 && offset && node.childNodes[offset - 1]!.nodeType == 3) {
      node = node.childNodes[offset - 1]!
      offset = node.nodeValue!.length
    }
    const inText = node.nodeType == 3 && !this.wg.docTile.nearest(node)?.isPoint
    let ref = this.wg.docTile.posFromDOM(node, inText ? 0 : offset)
    let dir: -1 | 1 = -1
    const textBefore = node.parentNode && textNodeBefore(node.parentNode, domIndex(node))
    const prev = textBefore && Tile.get(textBefore)
    if (prev instanceof TextTile && prev.length < prev.dom.nodeValue!.length) dir = 1
    if (this.domChanges) ref = this.domChanges.mapPos(ref, dir)
    return ref + (inText ? offset : 0)
  }

  // Get the current mapping from `domDoc` to `state.doc`. Updated
  // lazily so that `addDOMChange` gets a chance to notice when DOM
  // changes and transaction changes match.
  get domMapping() {
    const { pending } = this.wg.viewState
    while (this.domMappingIndex < pending.length) {
      this._domMapping = this._domMapping.compose(pending[this.domMappingIndex++]!.changes)
    }
    return this._domMapping
  }

  get unflushedSelection() {
    const { pending } = this.wg.viewState
    return pending.some(tr => tr.selection && !tr.isUserEvent('input') && !tr.annotation(selectionFromDOM))
  }

  // Assign a position (in `state.doc`) to the given DOM position.
  // Takes unflushed DOM changes into account.
  posAtDOM(node: Node, offset: number, assoc: -1 | 1 = -1) {
    if (this.domMapping.empty && !this.domChanges) return this.wg.docTile.posFromDOM(node, offset)
    return this.domMapping.mapPos(this.getDOMPos(node, offset), assoc)
  }

  // Update the editor state for a beforeinput event.
  beforeInput(event: InputEvent, data: InputEventData) {
    const type = event.inputType
    let range: { from: number; to: number } | undefined
    const { wg } = this
    const sel = wg.state.selection
    if (data.domRange) {
      range = { from: this.domMapping.mapPos(data.domRange.from), to: this.domMapping.mapPos(data.domRange.to) }
      if (!this.domMapping.empty && type == 'insertText' && !this.composing && range.from == range.to) {
        const fromMax = this.domMapping.mapPos(data.domRange.from, 1)
        if (range.from <= sel.from && fromMax >= sel.to) range = sel
      }
    }

    const command = inputTypeCommands[type]
    if (
      isDeletionInputEvent(type) &&
      range &&
      (!command ||
        (range.from != range.to && // Always run the command for empty ranges
          !this.unflushedSelection && // Or if there is a selection-setting pending transaction
          (sel.empty
            ? !isSingleChar(this.domDoc, data.domRange!.from, data.domRange!.to) ||
              sel.head != (type == 'deleteContentBackward' ? range.to : range.from)
            : sel.replacementRange.from != range.from || sel.replacementRange.to != range.to)))
    ) {
      // Cell selections draw their replacement range in the DOM, but the command deletes every
      // selected cell. Only a target outside that range is an explicit range deletion.
      // The browser gives an explicit target range for the deletion.
      Command.dispatch(wg, deleteRange, { ...range, userEvent: 'delete' })
    } else if (command) {
      Command.dispatch(wg, command)
    } else if (type == 'insertText') {
      const insert = event.data!.replace(/\r\n?|\n/g, ' ')
      // Typing follows the current caret, including its active marks. Chromium
      // can retain the previous target range after a programmatic caret move.
      const { from, to } = wg.state.selection
      Command.dispatch(wg, insertText, { from, to, insert, userEvent: 'input.type' })
    } else if (type == 'insertFromPaste') {
      const { from, to } = this.unflushedSelection ? wg.state.selection.replacementRange : range!
      pasteData(wg, event, event.dataTransfer!, from, to)
    } else if (type == 'insertReplacementText' || type == 'insertFromYank') {
      // The browser applies a replacement that cannot be canceled, such
      // as some spelling corrections. The input handler reads it from
      // the DOM.
      if (!event.cancelable) {
        data.readDOM = true
        return
      }
      const { from, to } = this.unflushedSelection || !range ? wg.state.selection.replacementRange : range
      const read = replacementContent(wg.state, event, from, to)
      const sel = wg.state.selection,
        touchesSel = from <= sel.to && to >= sel.from
      if (read) {
        wg.dispatch({
          changes: { from, to, insert: read, fit: true },
          selection: touchesSel
            ? (cx, changes) => {
                return GardSelection.near(cx, changes.mapPos(to, 1), -1)
              }
            : undefined,
          scrollIntoView: touchesSel,
          userEvent: 'insert.replacementText'
        })
      }
    } else if (type == 'insertCompositionText' || type == 'insertFromComposition') {
      // WebKit does not end a composition with a final
      // insertCompositionText event. It first fires a
      // deleteCompositionText event (handled below), then an
      // insertFromComposition event that holds the committed text.
      // That event is prevented (see the beforeinput handler), so its
      // text is only added to the document here, and drawn by the
      // flush that compositionend triggers.
      let compositionStart = true
      if (wg.inputState.composing) {
        compositionStart = !wg.inputState.composing!.changes
        wg.inputState.composing!.changes++
      }
      const sel = wg.observer.selectionRange
      if (!sel.focusNode) return false
      const userEvent = `input.type.compose${compositionStart ? '.start' : ''}`
      const { from, to } = range || wg.state.selection
      Command.dispatch(wg, insertText, { from, to, insert: event.data!, userEvent })
    } else if (type == 'deleteCompositionText') {
      // WebKit removes the composed text from the DOM when the
      // composition is committed or canceled. This event cannot be
      // canceled, so apply the same deletion to the document.
      if (range && range.from < range.to) {
        wg.dispatch({ changes: { from: range.from, to: range.to, fit: true }, userEvent: 'input.type.compose' })
      }
    } else if (type == 'formatSetBlockTextDirection') {
      if (event.data == 'ltr' || event.data == 'rtl') Command.dispatch(wg, setDirection, event.data)
    }
  }

  // Add a given DOM change (as made by an input event) to the tracked
  // DOM state. If there's a pending transaction that matches the
  // change, map `this._domMapping` and drop both. Otherwise, put the
  // inverse of this change at the start of `_domMapping`.
  addDOMChange(change: ChangeSet) {
    const { pending } = this.wg.viewState,
      { domDoc } = this
    try {
      this.domDoc = change.apply(domDoc)
    } catch (e) {
      if (!(e instanceof ValidationError)) throw e
      // Generated an invalid change from an input event. Force an
      // early flush.
      this.wg.flush()
      return
    }
    this.domChanges = this.domChanges ? this.domChanges.compose(change) : change
    while (this.domMappingIndex < pending.length) {
      const next = pending[this.domMappingIndex]!
      if (!next.docChanged) {
        this.domMappingIndex++
      } else {
        const { a: mapping, b: expected } = ChangeSet.transform(domDoc, this._domMapping, change)
        if (
          next.changes.sections.length != expected.sections.length ||
          next.changes.sections.some((v, i) => v != expected.sections[i])
        ) {
          break
        }
        this.domMappingIndex++
        this._domMapping = mapping
        return
      }
    }
    this._domMapping = change.invert(domDoc).compose(this._domMapping)
  }

  findComposition(prev: Text | null): Text | null {
    const { focusNode, focusOffset } = this.wg.observer.selectionRange
    if (!focusNode) return null
    const before = textNodeBefore(focusNode, focusOffset),
      after = textNodeAfter(focusNode, focusOffset)
    if (!before || !after || before == after) {
      return before || after
    } else {
      const tileBefore = Tile.get(before),
        tileAfter = Tile.get(after)
      if (tileBefore instanceof TextTile && tileBefore.text != before.nodeValue) return before
      if (tileAfter instanceof TextTile && tileAfter.text != after.nodeValue) return after
      return !tileBefore ? before : !tileAfter ? after : prev == after ? after : before
    }
  }

  getCompositionInfo(wg: Wordgard): CompositionInfo | null {
    const wrap = this.wrappingComposition
    if (wrap) {
      const sel = wg.state.selection.head
      return {
        fromB: sel,
        toB: sel,
        text: '',
        target: null,
        wrapCursor: wrap
      }
    }

    const comp = this.composing
    if (!comp) return null
    comp.target = this.findComposition(comp.target)
    if (!comp.target) return null
    let value = comp.target.nodeValue!
    const fromA = this.getDOMPos(comp.target, 0)
    const toA = fromA + value.length
    const fromB = this.domMapping.mapPos(fromA, -1)
    const toB = this.domMapping.mapPos(toA, 1)
    let changed = false
    let crossed = false
    this.domMapping.iterChanges((fA, tA) => {
      if (fA < toA && tA > fromA) {
        changed = true
        if (fA < fromA || tA > toA) crossed = true
      }
    })
    if (crossed) return null
    if (changed || toB - fromB != value.length) {
      const before = this.domDoc.resolve(fromA).nodeAfter
      const tokens = wg.state.doc.slice(fromB, toB)
      if (
        !before ||
        !tokens.length ||
        !tokens.every(token => token instanceof Leaf && token.isText && Mark.sameSet(token.marks, before.marks))
      ) {
        return null
      }
      // Reuse the composing Text node for remote text edits with the same marks.
      value = tokens.map(token => (token as Leaf<string>).param).join('')
    }
    return { fromB, toB, text: value, target: comp.target }
  }

  clearComposition() {
    const comp = this.composing!
    this.composing = null
    this.compositionPendingKey = true
    this.compositionEndedAt = Date.now()
    if (!comp.target) return false
    // WebKit can remove the composition's text node when it deletes
    // the composed text. The DOM observer has recorded that change.
    if (!this.wg.contentDOM.contains(comp.target)) return true
    const pos = this.posAtDOM(comp.target, 0, 1)
    this.wg.observer.addDirtyRange(pos, pos + comp.target.nodeValue!.length)
    return true
  }

  abortComposition() {
    if (!this.composing || !this.wg.hasFocus) return
    this.clearComposition()
    this.wg.win.setTimeout(() => {
      this.suppressEvents = true
      try {
        getSelection(this.wg.root)?.collapse(document.body, 0)
        const dummy = this.wg.win.document.body.appendChild(document.createElement('input'))
        dummy.focus()
        dummy.remove()
        this.wg.focus()
      } finally {
        this.suppressEvents = false
      }
    }, 0)
  }

  recordTouch(e: TouchEvent) {
    this.lastTouchTime = Date.now()
    this.lastTouchEvent = e
  }

  connect() {
    this.ensureHandlers(this.wg.state)
  }

  disconnect() {
    if (this.mouseSelection) this.mouseSelection.disconnect()
  }
}

function isSingleChar(doc: Plot.Doc, from: number, to: number) {
  if (to > from + 10) return false
  const after = doc.resolve(from).nodeAfter
  return !!after && after.is(Leaf.Text) && from + findClusterBreak(after.param, 0) == to
}

function inlineContext(doc: Plot.Doc, range: { from: number; to: number }) {
  const from = doc.resolve(range.from),
    to = doc.resolve(range.to)
  return from.parent.node.inlineContent && to.parent.start == from.parent.start
}

// The content of a text replacement or a yank, from the event's data
// transfer or its data. Text without line breaks keeps the marks of
// the text that it replaces.
function replacementContent(state: GardState, event: InputEvent, from: number, to: number) {
  let transfer = event.dataTransfer
  const text = transfer ? (transfer.types.includes('text/plain') ? transfer.getData('text/plain') : null) : event.data
  if (text != null && !/[\r\n]/.test(text)) {
    const start = state.doc.resolve(from),
      replaced = from < to ? start.nodeAfter : null
    const marks = replaced && replaced.is(Leaf.Text) ? replaced.marks : start.marks()
    return text ? Slice.of([Leaf.text(text, marks)]) : Slice.empty
  }
  if (!transfer) {
    if (text == null) return null
    transfer = new DataTransfer()
    transfer.setData('text/plain', text)
  }
  return readClipboard(state, transfer, state.doc.resolve(from), true)
}

// Read text that the browser changed in the DOM without a matching
// beforeinput event (for example a spelling correction that cannot be
// canceled) into the document. Only changes inside existing text
// nodes, made while the document matches the DOM, are read. The next
// flush draws any other DOM change from the document again.
function readDOMText(wg: Wordgard) {
  const { inputState, observer, state } = wg
  if (inputState.composing || inputState.domChanges || wg.viewState.pending.some(tr => tr.docChanged)) return
  const nodes: Text[] = []
  for (const record of observer.pendingRecords()) {
    const tile = Tile.get(record.target)
    if (record.type != 'characterData' || !(tile instanceof TextTile) || tile.dom != record.target) return
    if (!nodes.includes(tile.dom)) nodes.push(tile.dom)
  }
  const changes: ChangeSet.Change[] = []
  for (const node of nodes) {
    const tile = Tile.get(node) as TextTile,
      start = tile.posBefore
    const before = tile.text,
      after = node.nodeValue!
    if (before == after) continue
    const max = Math.min(before.length, after.length)
    let prefix = 0
    let suffix = 0
    while (prefix < max && before.charCodeAt(prefix) == after.charCodeAt(prefix)) prefix++
    if (prefix && isHighSurrogate(before.charCodeAt(prefix - 1))) prefix--
    while (
      suffix < max - prefix &&
      before.charCodeAt(before.length - 1 - suffix) == after.charCodeAt(after.length - 1 - suffix)
    ) {
      suffix++
    }
    if (suffix && isLowSurrogate(before.charCodeAt(before.length - suffix))) suffix--
    const inserted = after.slice(prefix, after.length - suffix),
      marks = state.doc.resolve(start).nodeAfter!.marks
    changes.push({
      from: start + prefix,
      to: start + before.length - suffix,
      insert: inserted ? [Leaf.text(inserted, marks)] : []
    })
  }
  if (!changes.length) return
  const changeSet = ChangeSet.create(state.doc, changes)
  wg.dispatch({ changes: changeSet, userEvent: 'insert.replacementText' })
  // The DOM already shows the change. Until the next flush, DOM
  // positions map through it, so that the DOM selection that the
  // browser left in the changed text is read correctly.
  inputState.addDOMChange(changeSet)
}

const isHighSurrogate = (code: number) => code >= 0xd800 && code < 0xdc00
const isLowSurrogate = (code: number) => code >= 0xdc00 && code < 0xe000

type HandlerFunction = (wg: Wordgard, event: Event) => boolean | void

function bindHandler(handler: (event: Event, wg: Wordgard) => boolean | void): HandlerFunction {
  return (wg, event) => {
    try {
      return handler(event, wg)
    } catch (e) {
      logException(wg.state, e)
    }
  }
}

function computeHandlers(state: GardState) {
  const result: {
    [event: string]: {
      observers: HandlerFunction[]
      handlers: HandlerFunction[]
    }
  } = Object.create(null)
  function record(type: string) {
    return result[type] || (result[type] = { observers: [], handlers: [] })
  }
  const h = state.facet(eventHandler),
    o = state.facet(eventObserver)
  for (const type in h) for (const handler of h[type]!) record(type).handlers.push(bindHandler(handler))
  for (const type in o) for (const observer of o[type]!) record(type).observers.push(bindHandler(observer))
  for (const type in baseHandlers) record(type).handlers.push((baseHandlers as any)[type])
  for (const type in baseObservers) record(type).observers.push((baseObservers as any)[type])
  return result
}

const dragScrollMargin = 6

export const mouseSelectionStyle = GardState.Facet.define<MakeSelectionStyle>()

export type MakeSelectionStyle = (wg: Wordgard, event: MouseEvent) => Wordgard.MouseSelectionStyle | null

function dragScrollSpeed(dist: number) {
  return Math.max(0, dist) * 0.7 + 8
}

function dist(a: MouseEvent, b: MouseEvent) {
  return Math.max(Math.abs(a.clientX - b.clientX), Math.abs(a.clientY - b.clientY))
}

class MouseSelection {
  dragging: null | boolean
  extend: boolean
  lastEvent: MouseEvent
  scrollParents: { x?: HTMLElement; y?: HTMLElement }
  scrollSpeed = { x: 0, y: 0 }
  scrolling = -1

  constructor(
    private wg: Wordgard,
    private startEvent: MouseEvent,
    private style: Wordgard.MouseSelectionStyle,
    private mustSelect: boolean
  ) {
    this.lastEvent = startEvent
    this.scrollParents = scrollableParents(wg.contentDOM)
    const doc = wg.contentDOM.ownerDocument!
    doc.addEventListener('mousemove', (this.move = this.move.bind(this)))
    doc.addEventListener('mouseup', (this.up = this.up.bind(this)))

    this.extend = startEvent.shiftKey
    this.dragging = isInPrimarySelection(wg, startEvent) && startEvent.detail == 1 ? null : false
  }

  start(event: MouseEvent) {
    // When clicking outside of the selection, immediately apply the
    // effect of starting the selection
    if (this.dragging === false) this.select(event)
  }

  move(event: MouseEvent) {
    if (event.buttons == 0) return this.disconnect()
    if (this.dragging || (this.dragging == null && dist(this.startEvent, event) < 10)) return
    this.select((this.lastEvent = event))

    let sx = 0,
      sy = 0
    let left = 0,
      top = 0,
      right = this.wg.win.innerWidth,
      bottom = this.wg.win.innerHeight
    if (this.scrollParents.x) ({ left, right } = this.scrollParents.x.getBoundingClientRect())
    if (this.scrollParents.y) ({ top, bottom } = this.scrollParents.y.getBoundingClientRect())
    const margins = this.wg.getScrollMargins()

    if (event.clientX - margins.left <= left + dragScrollMargin) sx = -dragScrollSpeed(left - event.clientX)
    else if (event.clientX + margins.right >= right - dragScrollMargin) sx = dragScrollSpeed(event.clientX - right)
    if (event.clientY - margins.top <= top + dragScrollMargin) sy = -dragScrollSpeed(top - event.clientY)
    else if (event.clientY + margins.bottom >= bottom - dragScrollMargin) sy = dragScrollSpeed(event.clientY - bottom)
    this.setScrollSpeed(sx, sy)
  }

  up(event: MouseEvent) {
    if (this.dragging == null) this.select(this.lastEvent)
    if (!this.dragging) event.preventDefault()
    this.disconnect()
  }

  disconnect() {
    this.setScrollSpeed(0, 0)
    const doc = this.wg.dom.ownerDocument
    doc.removeEventListener('mousemove', this.move)
    doc.removeEventListener('mouseup', this.up)
    this.wg.inputState.mouseSelection = this.wg.inputState.draggedContent = null
  }

  setScrollSpeed(sx: number, sy: number) {
    this.scrollSpeed = { x: sx, y: sy }
    if (sx || sy) {
      if (this.scrolling < 0) this.scrolling = window.setInterval(() => this.scroll(), 50)
    } else if (this.scrolling > -1) {
      clearInterval(this.scrolling)
      this.scrolling = -1
    }
  }

  scroll() {
    let { x, y } = this.scrollSpeed
    if (x && this.scrollParents.x) {
      this.scrollParents.x.scrollLeft += x
      x = 0
    }
    if (y && this.scrollParents.y) {
      this.scrollParents.y.scrollTop += y
      y = 0
    }
    if (x || y) this.wg.win.scrollBy(x, y)
    if (this.dragging === false) this.select(this.lastEvent)
  }

  select(event: MouseEvent) {
    const { wg } = this
    const selection = this.style.get(event, this.extend)
    if (this.mustSelect || !selection.eqPos(wg.state.selection)) {
      this.wg.dispatch({
        selection,
        userEvent: 'select.pointer'
      })
    }
    this.mustSelect = false
  }

  update(update: Wordgard.Update) {
    if (update.transactions.some(tr => tr.isUserEvent('input.type'))) this.disconnect()
    else if (this.style.update(update)) setTimeout(() => this.select(this.lastEvent), 20)
  }
}

export const dragBehavior = GardState.Facet.define<(event: MouseEvent) => boolean>()

function dragMovesSelection(wg: Wordgard, event: MouseEvent) {
  const facet = wg.state.facet(dragBehavior)
  return facet.length ? facet[0]!(event) : browser.mac ? !event.altKey : !event.ctrlKey
}

function isInPrimarySelection(wg: Wordgard, event: MouseEvent) {
  const { selection } = wg.state
  if (selection.empty) return false
  // On boundary clicks, check whether the coordinates are inside the
  // selection's client rectangles
  const sel = getSelection(wg.root)
  if (!sel || sel.rangeCount == 0) return true
  const rects = sel.getRangeAt(0).getClientRects()
  for (let i = 0; i < rects.length; i++) {
    const rect = rects[i]!
    if (
      rect.left <= event.clientX &&
      rect.right >= event.clientX &&
      rect.top <= event.clientY &&
      rect.bottom >= event.clientY
    ) {
      return true
    }
  }
  return false
}

const focusEvents = new Set(['input', 'beforeinput', 'keydown', 'keyup', 'keypress', 'copy', 'cut', 'paste'])

function eventBelongsToEditor(wg: Wordgard, event: Event): boolean {
  if (event.defaultPrevented) return false
  if (!event.bubbles) return true
  const active = wg.root.activeElement
  for (let node = event.target as DOMNode | null; node != wg.contentDOM; node = node.parentNode) {
    if (
      !node ||
      node.nodeType == 11 ||
      Tile.get(node)?.ignoreEvent(event) ||
      (node == active && focusEvents.has(event.type))
    ) {
      return false
    }
  }
  return true
}

function queryPos(wg: Wordgard, event: MouseEvent) {
  return wg.posAtCoords({ x: event.clientX, y: event.clientY }) as CoordPos
}

function basicMouseSelection(wg: Wordgard, event: MouseEvent): Wordgard.MouseSelectionStyle {
  let start = queryPos(wg, event)
  const type = event.detail
  let startSel = wg.state.selection
  return {
    update(update) {
      if (update.docChanged) {
        start = start.map(update.changes)
        startSel = startSel.map(update.changes, update.state)
      }
    },
    get(event, extend) {
      const cur = queryPos(wg, event)
      const range = rangeForClick(wg, cur, type),
        { from, to } = range
      if (extend) {
        const startAnchor =
          !(startSel instanceof GardSelection.Text) || startSel.directional
            ? startSel.anchor
            : from < startSel.from
              ? startSel.to
              : startSel.from
        if (from < startSel.anchor) return GardSelection.range(startAnchor, from, from < to ? 1 : cur.side)
        else return GardSelection.range(startAnchor, to, from < to ? -1 : cur.side)
      }
      let { anchor, head } = range
      if (start.pos != cur.pos) {
        const startRange = rangeForClick(wg, start, type)
        const from = Math.min(range.from, startRange.from),
          to = Math.max(range.to, startRange.to)
        if (startRange.from < range.from) {
          anchor = from
          head = to
        } else {
          anchor = to
          head = from
        }
      }
      return anchor == range.anchor && head == range.head
        ? range
        : GardSelection.range(anchor, head, head == cur.pos ? cur.side : undefined)
    }
  }
}

export const dropHandler =
  GardState.Facet.define<
    (wg: Wordgard, event: DragEvent, pos: number, move: { from: number; to: number } | null, slice: Slice) => boolean
  >()

export const pasteHandler =
  GardState.Facet.define<(wg: Wordgard, event: ClipboardEvent | InputEvent, slice: Slice) => boolean>()

// Paste clipboard data over a range. Paste handlers run only when the
// range is the selection's replacement range.
function pasteData(wg: Wordgard, event: ClipboardEvent | InputEvent, data: DataTransfer, from: number, to: number) {
  const slice = readClipboard(wg.state, data, wg.state.doc.resolve(from), wg.inputState.shiftKey)
  const isSel = from == wg.state.selection.replacementRange.from && to == wg.state.selection.replacementRange.to
  if (isSel && wg.state.facet(pasteHandler).some(h => h(wg, event, slice || Slice.empty))) {
    return
  }
  if (slice) {
    wg.dispatch({
      changes: { from, to, insert: slice, fit: true },
      selection: isSel ? (cx, changes) => GardSelection.near(cx, changes.mapPos(to, 1), -1) : undefined,
      userEvent: 'input.paste',
      scrollIntoView: isSel
    })
  }
}

function copy(wg: Wordgard, event: ClipboardEvent) {
  // Read a DOM selection change that has not been flushed yet.
  wg.flush()
  const { state } = wg
  if (!state.selection.empty && event.clipboardData) {
    writeClipboard(state, state.selection.toSlice(state.doc), event.clipboardData)
    if (event.type == 'cut') Command.dispatch(wg, deleteCut)
  }
  return true
}

export const isFocusChange = Transaction.Annotation.define<boolean>()

function updateForFocusChange(wg: Wordgard) {
  setTimeout(() => {
    const focus = wg.hasFocus
    if (focus != wg.inputState.notifiedFocused) {
      wg.inputState.notifiedFocused = focus
      wg.dispatch({ annotations: isFocusChange.of(focus) })
    }
  }, 10)
}

export type CompositionInfo = {
  fromB: number
  toB: number
  text: string
  target: Text | null
  wrapCursor?: Mark.Set | null
}

function compositionEnd(wg: Wordgard) {
  if (wg.inputState.composing && wg.inputState.clearComposition()) wg.flush()
}

function compositionUpdate(wg: Wordgard, event: CompositionEvent) {
  if (!wg.inputState.composing) {
    prepareComposition(wg)
    wg.inputState.composing = { changes: 0, target: null }

    let wrap: Mark.Set | null = null
    if (!event.data) {
      const sel = wg.state.selection,
        rSel = wg.state.sel
      if (
        (sel.empty &&
          ((sel instanceof GardSelection.Text && sel.marks) || (!rSel.head.inText && rSel.head.index)) &&
          !eqArray(rSel.head.nodeBefore?.tag.marks, rSel.activeMarks)) ||
        (sel.empty && inlineBoundNear(wg.state.sel.head)) ||
        !inEditableDOM(wg, wg.observer.selectionRange.focusNode)
      ) {
        wrap = rSel.activeMarks
      }
    }

    if (wrap) {
      try {
        wg.inputState.wrappingComposition = wrap
        wg.flush()
      } finally {
        wg.inputState.wrappingComposition = null
      }
    }
  }
}

// The browser composes text at the DOM selection. Before a composition
// starts, draw a selection that the editor set and has not drawn yet.
// When the cursor is between blocks, insert an empty textblock there
// first, so that the composed text goes into that textblock.
function prepareComposition(wg: Wordgard) {
  wg.inputState.readNewSelection()
  const { state } = wg
  if (state.selection.isCursor && !state.sel.head.parent.node.inlineContent) {
    const open = enter(wg, null)
    if (open) wg.dispatch({ ...open, userEvent: 'input.type' })
  }
  if (wg.observer.editorSelectionPending) wg.flush()
}

function inlineBoundNear(pos: Pos) {
  const { parent, index, inText } = pos
  if (inText || !parent.node.inlineContent) return false
  return (
    (index ? parent.node.content[index - 1]!.isPlot : parent.node.isInline) ||
    (index < parent.node.content.length ? parent.node.content[index]!.isPlot : parent.node.isInline)
  )
}

function inEditableDOM(wg: Wordgard, node: DOMNode | null) {
  if (!node) return false
  const tile = wg.docTile.nearest(node)
  return tile ? !(tile.isPoint || tile instanceof WidgetTile) : false
}

function isDeletionInputEvent(type: string) {
  return /^delete(Content|Word|ByComposition)/.test(type)
}

const inputTypeCommands: { [inputType: string]: Command.Bound | Command } = {
  historyUndo: undo,
  historyRedo: redo,
  insertLineBreak: insertLineBreak,
  insertParagraph: enter,
  deleteContentBackward: Command.bind(deleteUnit, 'backward'),
  deleteContentForward: Command.bind(deleteUnit, 'forward'),
  deleteWordBackward: Command.bind(deleteWord, 'backward'),
  deleteWordForward: Command.bind(deleteWord, 'forward'),
  deleteSoftLineBackward: Command.bind(deleteToLineEnd, 'backward'),
  deleteSoftLineForward: Command.bind(deleteToLineEnd, 'forward'),
  deleteHardLineBackward: Command.bind(deleteToLineEnd, 'backward'),
  deleteHardLineForward: Command.bind(deleteToLineEnd, 'forward'),
  deleteContent: wg => {
    const tr = deleteSelection(wg.state)
    if (tr) wg.dispatch(tr)
    return !!tr
  },
  insertTranspose: transposeChars,
  deleteEntireSoftLine: deleteLine,
  formatBold: toggleStrong,
  formatItalic: toggleEmphasis,
  formatUnderline: toggleUnderline,
  formatJustifyCenter: Command.bind(setAlignment, 'center'),
  formatJustifyLeft: Command.bind(setAlignment, 'left'),
  formatJustifyRight: Command.bind(setAlignment, 'right')
}

const baseHandlers: { [e in keyof HTMLElementEventMap]?: (wg: Wordgard, event: HTMLElementEventMap[e]) => boolean } = {
  keydown(wg, event) {
    if ((browser.ios || browser.android) && (event.key == 'Backspace' || event.key == 'Enter')) return false
    return KeyBinding.handle(wg, event)
  },

  mousedown(wg, event) {
    wg.inputState.shiftKey = event.shiftKey
    if (
      wg.inputState.lastTouchTime > Date.now() - 500 || // Ignore touch interaction
      !wg.focusable
    ) {
      return false
    }
    let style: Wordgard.MouseSelectionStyle | null = null
    for (const makeStyle of wg.state.facet(mouseSelectionStyle)) {
      style = makeStyle(wg, event)
      if (style) break
    }
    if (!style && event.button == 0) style = basicMouseSelection(wg, event)
    if (style) {
      const mustFocus = !wg.hasFocus
      wg.inputState.startMouseSelection(new MouseSelection(wg, event, style, mustFocus))
      if (mustFocus) {
        wg.observer.ignore(() => {
          // Firefox can leave the focus on another element. Remove it from there.
          wg.contentDOM.focus({ preventScroll: true })
          const active = wg.root.activeElement
          if (active && !active.contains(wg.contentDOM)) (active as HTMLElement).blur()
        })
      }
      const mouseSel = wg.inputState.mouseSelection
      if (mouseSel) {
        mouseSel.start(event)
        return mouseSel.dragging === false
      }
    }
    return false
  },

  dragstart(wg, event) {
    const { selection } = wg.state
    const { inputState } = wg
    if (inputState.mouseSelection) inputState.mouseSelection.dragging = true
    inputState.draggedContent = selection

    if (event.dataTransfer) {
      writeClipboard(wg.state, wg.state.selection.toSlice(wg.state.doc), event.dataTransfer)
      event.dataTransfer.effectAllowed = 'copyMove'
    }
    return false
  },

  dragend(wg) {
    wg.inputState.draggedContent = null
    return false
  },

  copy,
  cut: copy,

  // Browsers fire `paste` before the `insertFromPaste` input event, and
  // handling it here cancels that event. A paste event without an input
  // event, such as one created by a script, pastes as well.
  paste(wg, event) {
    if (wg.state.readOnly || !event.clipboardData) return true
    // Read a DOM selection change that has not been flushed yet.
    wg.flush()
    const { from, to } = wg.state.selection.replacementRange
    pasteData(wg, event, event.clipboardData, from, to)
    return true
  },

  drop(wg, event) {
    if (!event.dataTransfer || wg.state.readOnly) return true
    const slice = readClipboard(wg.state, event.dataTransfer, wg.state.sel.head, false)
    if (!slice) return false

    const dropPos = wg.posAtCoords({ x: event.clientX, y: event.clientY }).pos
    const { draggedContent } = wg.inputState
    const del =
      draggedContent && dragMovesSelection(wg, event) ? { from: draggedContent.from, to: draggedContent.to } : null
    if (wg.state.facet(dropHandler).some(f => f(wg, event, dropPos, del, slice))) return true
    const ins = { from: dropPos, insert: slice, fit: true }
    const changes = ChangeSet.create(wg.state.doc, del ? [del, ins] : ins)
    wg.focus()
    wg.dispatch({
      changes,
      selection: GardSelection.undirectionalRange(changes.mapPos(dropPos, -1), changes.mapPos(dropPos, 1)),
      userEvent: del ? 'move.drop' : 'input.drop'
    })
    wg.inputState.draggedContent = null
    return true
  },

  beforeinput(wg, event) {
    if (wg.state.readOnly) return true
    const type = event.inputType
    // Safari will occasionally forget to fire compositionend at the end of a dead-key composition
    if (browser.safari && type == 'insertText' && wg.inputState.composing) compositionEnd(wg)
    if (type == 'insertCompositionText' && !wg.inputState.composing) {
      wg.inputState.composing = { changes: 0, target: null }
    }

    const data: InputEventData = {
      inputType: type,
      data: event.data,
      domRange: null,
      readDOM: false
    }
    const ranges = event.getTargetRanges()
    let editable = true
    if (ranges.length) {
      const r = ranges[0]!,
        empty = r.collapsed
      const from = wg.inputState.getDOMPos(r.startContainer, r.startOffset)
      data.domRange = { from, to: empty ? from : wg.inputState.getDOMPos(r.endContainer, r.endOffset) }
      editable = inEditableDOM(wg, r.startContainer) && (empty || inEditableDOM(wg, r.endContainer))
    }
    // Composition cannot be canceled. Also let through simple
    // insertion and deletion to avoid confusing virtual keyboards and
    // Safari autocapitalize. (WebKit's insertFromComposition can be
    // canceled, and is, because `beforeInput` adds its text.)
    const allow =
      type == 'insertCompositionText' ||
      type == 'deleteCompositionText' ||
      (editable &&
        (type == 'insertText' ||
          (isDeletionInputEvent(type) && data.domRange && inlineContext(wg.inputState.domDoc, data.domRange))))
    // The input event after a change that the browser applies refers to
    // this event. Set it before `beforeInput` dispatches, because the
    // editor does not redraw while it is set (see `Wordgard.flush`).
    if (allow || !event.cancelable) wg.inputState.pendingInputEvent = data
    wg.inputState.beforeInput(event, data)
    wg.scheduleFlush()
    return !allow
  },

  input(wg, event) {
    const pending = wg.inputState.pendingInputEvent
    wg.inputState.pendingInputEvent = null
    if (wg.state.readOnly) {
      wg.scheduleFlush()
      return false
    }
    if (!pending || pending.inputType != event.inputType || pending.readDOM) {
      readDOMText(wg)
      return false
    }
    if (!pending.domRange) return false
    let change: ChangeSet.Change | undefined
    if (event.inputType == 'insertCompositionText' || event.inputType == 'insertText') {
      change = { from: pending.domRange.from, to: pending.domRange.to, insert: [Leaf.text(pending.data!)] }
    } else if (isDeletionInputEvent(event.inputType) || event.inputType == 'deleteCompositionText') {
      change = { from: pending.domRange.from, to: pending.domRange.to }
    } else {
      return false
    }
    wg.inputState.addDOMChange(ChangeSet.create(wg.inputState.domDoc, change))
    return false
  }
}

const baseObservers: { [e in keyof HTMLElementEventMap]?: (wg: Wordgard, event: HTMLElementEventMap[e]) => void } = {
  scroll(wg) {
    wg.inputState.lastScrollTop = wg.scrollDOM.scrollTop
    wg.inputState.lastScrollLeft = wg.scrollDOM.scrollLeft
  },

  touchstart(wg, e) {
    wg.inputState.recordTouch(e)
  },
  touchmove(wg, e) {
    wg.inputState.recordTouch(e)
  },

  focus(wg) {
    // When focusing reset the scroll position, move it back to where it was
    if (!wg.scrollDOM.scrollTop && (wg.inputState.lastScrollTop || wg.inputState.lastScrollLeft)) {
      wg.scrollDOM.scrollTop = wg.inputState.lastScrollTop
      wg.scrollDOM.scrollLeft = wg.inputState.lastScrollLeft
    }
    updateForFocusChange(wg)
  },

  blur(wg) {
    updateForFocusChange(wg)
  },

  compositionstart: compositionUpdate,
  compositionupdate: compositionUpdate,

  compositionend(wg) {
    // Desktop Safari fires the keydown of the key that ends a
    // composition (for example Enter) after compositionend. Let
    // `ignoreDuringComposition` skip that key event.
    wg.inputState.compositionPendingKey = true
    compositionEnd(wg)
  },

  contextmenu(wg) {
    wg.inputState.lastContextMenu = Date.now()
  }
}
