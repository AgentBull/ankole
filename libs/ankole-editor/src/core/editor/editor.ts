import { GardState, Transaction, GardSelection } from '../state'
import { ChangeSet, Node, Attributes } from '../doc'
import { PhraseSet } from '../phrases'
import { StyleModule, StyleSpec } from 'style-mod'

import { DocTile, updateAttributes } from './tile'
import { coordsAtPos } from './coords'
import { addUpdated } from './changes'
import {
  clipboardOutputFilter,
  clipboardOutputHTMLFilter,
  clipboardOutputTextFilter,
  clipboardInputFilter,
  clipboardInputHTMLFilter,
  clipboardInputTextFilter,
  clipboardTextParser,
  clipboardTextSerializer
} from './clipboard'
import { theme, colorScheme, buildTheme, styleID, baseLightID, baseDarkID, lightDarkIDs, baseStyles } from './theme'
import { DOMObserver } from './domobserver'
import {
  InputState,
  isFocusChange,
  mouseSelectionStyle,
  dragBehavior,
  pasteHandler,
  dropHandler,
  eventHandler,
  eventObserver
} from './input'
import { ViewState, scrollIntoView, ScrollTarget } from './viewstate'
import browser from './browser'
import { DOMNode, getRoot, clearScratchRange, scrollRectIntoView } from './dom'
import { setDOMSelection, moveVertically, moveToLineBoundary } from './selection'
import { cursorBlinkRate, CursorLayer } from './drawcursor'
import { exceptionSink, logException, logException as reportException } from './util'

const dirCompartment = GardState.Compartment.define()

enum Flush {
  No,
  Yes,
  Read
}

/**
 * This class implements the editor's user interface. It wraps the
 * editable DOM surface and possibly other elements such as panels.
 */
export class Wordgard {
  /**
   * Construct a new editor. You'll want to either provide a `parent`
   * option, or put the editor's {@link Wordgard.dom DOM element}
   * into your document after creating an editor, so that the user
   * can see it.
   */
  static create(spec: Wordgard.Spec) {
    return new Wordgard(spec)
  }

  /** The current editor state. */
  get state() {
    return this.viewState.state
  }

  /** @internal */
  get flushedState() {
    return this.viewState.flushedState
  }

  /**
   * Indicates whether the user is currently composing text via
   * [IME](https://en.wikipedia.org/wiki/Input_method), and at least
   * one change has been made in the current composition.
   */
  get composing() {
    return !!this.inputState.composing
  }

  /**
   * Indicates whether the user is currently in composing state. Note
   * that on some platforms, like Android, this will be the case a
   * lot, since just putting the cursor on a word starts a
   * composition there.
   */
  get compositionStarted() {
    return this.inputState.composing && this.inputState.composing.changes > 0
  }

  /**
   * Queries whether the editor's DOM is {@link Wordgard#editable
   * editable}.
   */
  get editable() {
    return this.state.facet(Wordgard.editable)
  }

  /**
   * Returns true if the editor can be focused (is {@link
   * Wordgard.editable editable} or has a tabindex).
   */
  get focusable() {
    return this.editable || this.contentDOM.tabIndex > -1
  }

  /** The document or shadow root that the editor lives in. */
  root: DocumentOrShadowRoot = document

  /** @internal */
  get win() {
    return this.dom.ownerDocument.defaultView || window
  }

  /** The outer DOM element that represents the editor. */
  readonly dom: HTMLElement

  /**
   * The DOM element that can be styled to scroll. (Note that it may
   * not have been, so you can't assume this is scrollable.)
   */
  readonly scrollDOM: HTMLElement

  /**
   * The editable DOM element holding the editor content. You should
   * not, usually, interact with this content directly though the
   * DOM, since the editor will immediately undo most of the changes
   * you make. Instead, {@link Wordgard.dispatch dispatch} {@link
   * Transaction transactions} to modify content, and {@link
   * Decoration decorations} to style it.
   */
  readonly contentDOM: HTMLElement

  private announceDOM: HTMLElement

  private id = `wordgard-${Math.floor(Math.random() * 0xffffff).toString(16)}`

  /** @internal */
  inputState!: InputState
  /** @internal */
  viewState: ViewState
  /** @internal */
  docTile!: DocTile

  /** @internal */
  plugins: PluginInstance[] = []
  private pluginMap: Map<Wordgard.Plugin<any>, PluginInstance | null> = new Map()
  private editorAttrs: Attributes = Attributes.none
  private contentAttrs: Attributes = Attributes.none
  private styleModules!: readonly StyleModule[]

  /** True when the editor is connected to a DOM document. */
  connected = false
  private flushing = Flush.No
  private willFlush = false
  private flushFunc: () => void
  /** @internal */
  lastFlush = Date.now()
  private autoColorScheme: 'light' | 'dark' = 'light'

  /** @internal */
  observer: DOMObserver

  private domReaders: ((wg: Wordgard) => void)[] = []
  private domWriters: ((wg: Wordgard) => void)[] = []
  private pendingTransactionListeners = new Map<
    (trs: readonly Transaction[], wg: Wordgard) => void,
    readonly Transaction[]
  >()

  private constructor(spec: Wordgard.Spec) {
    this.flushFunc = () => {
      // The browser applies the change of a beforeinput event in the
      // task of that event. A change that is still pending in a new
      // frame did not happen.
      this.inputState.pendingInputEvent = null
      if (this.willFlush) this.flush()
    }
    this.dispatch = this.dispatch.bind(this)

    this.dom = createWrapElement(this)

    this.contentDOM = document.createElement('wg-content')

    this.scrollDOM = document.createElement('wg-scroller')
    this.scrollDOM.tabIndex = -1
    this.scrollDOM.appendChild(this.contentDOM)

    this.announceDOM = document.createElement('wg-announced')
    this.announceDOM.setAttribute('aria-live', 'polite')

    this.dom.appendChild(this.announceDOM)
    this.dom.appendChild(this.scrollDOM)

    this.viewState = new ViewState(spec.state || GardState.create(spec as GardState.Spec))
    if (spec.scrollTo && spec.scrollTo.is(scrollIntoView)) {
      this.viewState.scrollTarget = spec.scrollTo.value.clip(this.viewState.state)
    }
    this.plugins = [cursorPlugin, ...this.state.facet(editorPlugin)].map(spec => new PluginInstance(spec))
    for (const plugin of this.plugins) plugin.update(this)
    this.inputState = new InputState(this)
    this.docTile = DocTile.create(this.state, this.contentDOM, this)
    this.updateAttrs()
    this.observer = new DOMObserver(this)

    if (spec.parent) spec.parent.appendChild(this.dom)
  }

  /** @internal */
  setConnected(value: boolean) {
    if (value == this.connected) return
    this.connected = value
    if (value) {
      this.root = getRoot(this.dom.parentNode!) || document
      this.mountStyles()
      this.inputState.connect()
      if (!this.viewState.initialized) this.viewState.initialMeasure(this)
      for (const plugin of this.plugins) plugin.connect(this)
      this.observer.connect()
      if (this.viewState.pending.length || this.domReaders.length || this.domWriters.length) this.scheduleFlush()
      this.docTile.connect()
    } else {
      this.root = document
      this.observer.disconnect()
      for (const plugin of this.plugins) plugin.disconnect(this)
      this.inputState.disconnect()
      this.docTile.disconnect()
      clearScratchRange()
    }
  }

  /**
   * All editor state updates go through this. It takes a transaction
   * or transaction spec and updates the editor to show the new state
   * produced by that transaction. This function is bound to the editor
   * instance, so it does not have to be called as a method.
   *
   * Will apply {@link Transaction.appender transaction appenders}
   * and include any extra transactions they produce in the editor's
   * state.
   *
   * Updates will be immediately be reflected in the object's `state`
   * property, but updating the DOM will be deferred to the next
   * display update.
   */
  dispatch(tr: Transaction | Transaction.Spec): void {
    if (this.flushing != Flush.No) throw new Error('Cannot dispatch new updates during the editor flush phase')
    if (!(tr instanceof Transaction)) tr = this.state.update(tr)
    else if (tr.startState != this.state) throw new Error('Dispatching a transaction starting from the wrong state')
    const trs = Transaction.append(tr as Transaction)
    for (const t of trs) this.viewState.update(t)
    this.runTransactionListeners(trs)
    this.scheduleFlush()
  }

  /** @internal */
  scheduleFlush() {
    if (!this.willFlush && this.flushing == Flush.No && this.connected) {
      this.win.requestAnimationFrame(this.flushFunc)
      this.willFlush = true
    }
  }

  /**
   * Force a flush on the editor content, updating its DOM
   * representation for any pending changes.
   *
   * Between a beforeinput event and the change that the browser
   * applies for it, this does nothing: the change must apply to the DOM
   * that the event saw. Layout reads in that time, for example from a
   * {@link Wordgard.transactionListener transaction listener}, measure
   * the DOM as it was last drawn.
   */
  flush() {
    if (this.inputState.pendingInputEvent) return
    this.observer.readSelectionRange()
    if (!this.connected) return
    if (!this.observer.editorSelectionPending || this.inputState.composing) this.observer.pollSelection()
    const { flushedState, state } = this.viewState
    const update = Wordgard.Update.create(this, flushedState, state, this.viewState.pending)

    this.willFlush = false
    this.flushing = Flush.Yes
    this.lastFlush = Date.now()
    try {
      let domChanges = this.observer.takeDirty()
      this.observer.ignore(() => this.runUpdate(update, domChanges))
      this.viewState.flush()
      domChanges = null
      for (let i = 0; ; i++) {
        if (i > 5) {
          console.warn('Editor flush loop restarted more than 5 times')
          break
        }
        const write = this.domWriters
        this.domWriters = []
        for (const f of write) f(this)
        const flags = this.viewState.measure(this)
        const read = this.domReaders
        this.domReaders = []
        this.flushing = Flush.Read
        for (const f of read) f(this)
        this.flushing = Flush.Yes
        if (!flags && !this.domWriters.length) break
        update.flags |= flags
        if (flags) this.runUpdate(Wordgard.Update.create(this, state, state, [], flags), null)
      }
    } finally {
      this.flushing = Flush.No
    }
    if (this.viewState.scrollTarget) {
      this.scrollTo(this.viewState.scrollTarget)
      this.viewState.scrollTarget = null
    }
    if (!update.empty) {
      for (const listener of this.state.facet(Wordgard.updateListener)) {
        try {
          listener(update)
        } catch (e) {
          logException(this.state, e, 'update listener')
        }
      }
    }
    this.checkDir()
  }

  private scrollTo(target: ScrollTarget) {
    for (const handler of this.state.facet(Wordgard.scrollHandler)) {
      try {
        if (handler(this, target)) return true
      } catch (e) {
        logException(this.state, e, 'scroll handler')
      }
    }

    const { from, to, assoc } = target
    let rect = this.coordsAtPos(from, from == to ? assoc : 1)
    if (from != to) {
      const other = this.coordsAtPos(to, -1)
      const left = Math.min(rect.left, other.left),
        top = Math.min(rect.top, other.top)
      rect = new DOMRect(left, top, Math.max(rect.right, other.right) - left, Math.max(rect.bottom, other.bottom) - top)
    }

    const margins = this.getScrollMargins()
    const targetRect = new DOMRect(
      rect.left + margins.left,
      rect.top + margins.top,
      rect.width - margins.left - margins.right,
      rect.height - margins.top - margins.bottom
    )
    const { offsetWidth, offsetHeight } = this.scrollDOM
    scrollRectIntoView(
      this.scrollDOM,
      targetRect,
      assoc,
      target.spec.x,
      target.spec.y,
      Math.max(Math.min(target.spec.xMargin, offsetWidth), -offsetWidth),
      Math.max(Math.min(target.spec.yMargin, offsetHeight), -offsetHeight),
      this.state.textLTR
    )
  }

  private runUpdate(update: Wordgard.Update, domChanges: readonly number[] | null) {
    const composition = this.composing ? this.inputState.getCompositionInfo(this) : null
    if (this.composing && !composition) this.inputState.abortComposition()
    const changes = domChanges ? addUpdated(update.changes.sections, domChanges) : update.changes.sections
    const prevDocTile = this.docTile
    if (!update.empty) {
      this.updatePlugins(update)
      this.inputState.update(update)
      this.showAnnouncements(update.transactions)
      if (this.state.facet(Wordgard.styleModule) != this.styleModules) this.mountStyles()
      this.updateAttrs()
    }
    this.docTile = prevDocTile.update(update.state, changes, this, composition)

    if (
      (composition?.wrapCursor || (!composition && (prevDocTile != this.docTile || update.selectionSet))) &&
      this.hasFocus
    ) {
      setDOMSelection(this)
    }
    this.observer.clear()
    if (this.docTile != prevDocTile) for (const plugin of this.plugins) plugin.docUpdate(this)
  }

  private updatePlugins(update: Wordgard.Update) {
    const specs = update.state.facet(editorPlugin)
    const configChange = specs != update.startState.facet(editorPlugin)
    if (configChange) {
      const newPlugins: PluginInstance[] = []
      for (const spec of [cursorPlugin, ...specs]) {
        const found = this.plugins.findIndex(p => p.spec == spec)
        if (found < 0) {
          const plugin = new PluginInstance(spec)
          newPlugins.push(plugin)
          if (this.connected) plugin.connect(this)
        } else {
          const plugin = this.plugins[found]!
          plugin.mustUpdate = update
          newPlugins.push(plugin)
        }
      }
      for (const plugin of this.plugins) if (!newPlugins.includes(plugin)) plugin.remove(this)
      this.plugins = newPlugins
      this.pluginMap.clear()
    } else {
      for (const p of this.plugins) p.mustUpdate = update
    }
    for (let i = 0; i < this.plugins.length; i++) this.plugins[i]!.update(this)
    if (configChange) this.inputState.ensureHandlers(update.state)
  }

  private updateAttrs() {
    const editorAttrs = attrsFromFacet(this, Wordgard.editorAttributes, ['class', this.themeClasses])
    const contentAttrs = attrsFromFacet(this, Wordgard.contentAttributes, [
      'aria-multiline',
      'true',
      ...(this.state.readOnly ? ['aria-readonly', 'true'] : []),
      'contenteditable',
      String(this.state.facet(Wordgard.editable)),
      'role',
      'textbox',
      'translate',
      'no',
      'id',
      this.id
    ])

    const changedContent = updateAttributes(this.contentDOM, this.contentAttrs, contentAttrs)
    this.contentAttrs = contentAttrs
    const changedEditor = updateAttributes(this.dom, this.editorAttrs, editorAttrs)
    this.editorAttrs = editorAttrs
    return changedContent || changedEditor
  }

  private checkDir() {
    if (this.viewState.styleLTR != this.state.textLTR) {
      const value = GardState.textLTR.of(this.viewState.styleLTR)
      this.dispatch({
        effects:
          dirCompartment.get(this.state) == null
            ? GardState.appendConfig.of(GardState.prec.highest(dirCompartment.of(value)))
            : dirCompartment.reconfigure(value)
      })
    }
  }

  private showAnnouncements(trs: readonly Transaction[]) {
    let first = true
    for (const tr of trs) {
      for (const effect of tr.effects) {
        if (effect.is(Wordgard.announce)) {
          if (first) this.announceDOM.textContent = ''
          first = false
          const div = this.announceDOM.appendChild(document.createElement('div'))
          div.textContent = effect.value
        }
      }
    }
  }

  private mountStyles() {
    this.styleModules = this.state.facet(Wordgard.styleModule)
    const nonce = this.state.facet(Wordgard.cspNonce)
    StyleModule.mount(this.root, this.styleModules.concat(baseStyles).reverse(), nonce ? { nonce } : undefined)
  }

  /**
   * Schedule a function that needs to read from the (flushed) DOM.
   * During an editor update, when doing anything that needs to
   * access the DOM layout, it is important to schedule it with this
   * method, to avoid forcing unnecessary DOM layouts.
   */
  scheduleDOMRead(read: (wg: Wordgard) => void) {
    this.scheduleFlush()
    if (this.domReaders.indexOf(read) < 0) this.domReaders.push(read)
  }

  /**
   * Schedule a function that needs to modify the DOM. When doing any
   * kind of DOM mutation that depends on a {@link
   * Wordgard.scheduleDOMRead | DOM read}, use this method, so that
   * read and write phases remain separate.
   */
  scheduleDOMWrite(write: (wg: Wordgard) => void) {
    this.scheduleFlush()
    if (this.domWriters.indexOf(write) < 0) this.domWriters.push(write)
  }

  /**
   * Get the value of a specific plugin, if present. Note that
   * plugins that crash can be dropped from an editor, so even when
   * you know you registered a given plugin, it is recommended to
   * check the return value of this method.
   */
  plugin<T extends Wordgard.Plugin.Value>(plugin: Wordgard.Plugin<T>): T | null {
    let known = this.pluginMap.get(plugin)
    if (known === undefined || (known && known.spec != plugin)) {
      this.pluginMap.set(plugin, (known = this.plugins.find(p => p.spec == plugin && !p.deactivated) || null))
    }
    return known && (known.update(this).value as T)
  }

  private ensureFlushed() {
    if (!this.connected) throw new Error('Editor is not connected to the DOM')
    if (this.willFlush && (this.viewState.pending.some(tr => tr.docChanged) || this.observer.dirty)) {
      if (this.flushing == Flush.Yes) throw new Error('Trying to read from unflushed editor during flush')
      if (this.flushing == Flush.No) this.flush()
    }
  }

  /**
   * Find the position at the end or start of the (wrapped) line. If
   * the given position isn't in a textblock, this will return null.
   */
  moveToLineBoundary(start: GardSelection, forward: boolean) {
    this.ensureFlushed()
    return moveToLineBoundary(this, start, forward)
  }

  /**
   * Move a cursor position vertically. When `distance` isn't given,
   * it defaults to moving to the vertical element below or above the
   * start position. Otherwise, `distance` should provide a positive
   * distance in pixels.
   *
   * When `start` has a
   * {@link GardSelection.goalColumn `goalColumn`}, the vertical
   * motion will use that as a target horizontal position. Otherwise,
   * the cursor's own horizontal position is used. The returned
   * cursor will have its goal column set to whichever column was
   * used. If `allowNode` is true, this may return a node selection
   * on a block node.
   */
  moveVertically(start: GardSelection, forward: boolean, distance?: number, allowNode?: boolean) {
    this.ensureFlushed()
    return moveVertically(this, start, forward, distance, allowNode)
  }

  /**
   * Find the DOM parent node and offset (child offset if `node` is
   * an element, character offset when it is a text node) at the
   * given document position.
   */
  domAtPos(pos: number, assoc: -1 | 1 = -1): { node: DOMNode; offset: number } {
    this.ensureFlushed()
    const tilePos = this.docTile.resolve(pos, assoc)
    return { node: tilePos.tile.dom, offset: tilePos.offset }
  }

  /** Get the DOM element for the node at the given position, if any. */
  nodeDOM(pos: number): Element | null {
    this.ensureFlushed()
    const tile = this.docTile.nodeTile(pos)
    if (!tile || tile.dom.nodeType != 1) return null
    return tile.dom as Element
  }

  /**
   * Find the document position at the given DOM node. Can be useful
   * for associating positions with DOM events. Will raise an error
   * when `node` isn't part of the editor content.
   */
  posAtDOM(node: DOMNode, offset: number = 0) {
    return this.inputState.posAtDOM(node, offset, 1)
  }

  /**
   * Find the Wordgard node represented by the given DOM node, or one
   * of its parent nodes, if any. Will not return the outer document node.
   */
  nodeFromDOM(node: Element): { pos: number; node: Node } | null {
    const tile = this.docTile.nearest(node, true)
    if (!tile || tile == this.docTile) return null
    const pos = tile.posBefore
    const n = this.state.doc.nodeAt(pos)
    return n && { pos, node: n }
  }

  /** Get the document position at the given screen coordinates. */
  posAtCoords(coords: { x: number; y: number }): { pos: number; side: -1 | 1; target: number | null } {
    const elt = ((this.root as any).elementFromPoint ? this.root : this.dom.ownerDocument).elementFromPoint(
      coords.x,
      coords.y
    )
    const tile = (elt && this.docTile.nearest(elt)) || this.docTile
    let result = tile.posAtCoords(this.state, coords.x, coords.y)
    // The result maps through pending transactions, but not through DOM changes that the editor has not read yet.
    for (const tr of this.viewState.pending) result = result.map(tr.changes)
    return result
  }

  /**
   * Get the screen coordinates at the given document position.
   * `side` determines whether the coordinates are based on the
   * element before (-1) or after (1) the position (if no element is
   * available on the given side, the method will transparently use
   * another strategy to get reasonable coordinates).
   */
  coordsAtPos(pos: number, assoc: -1 | 1 = -1): DOMRect {
    this.ensureFlushed()
    return coordsAtPos(this, pos, assoc).rect
  }

  /**
   * Return the rectangle around a given node or character. If there
   * is no element directly after `pos`, this will return null. For
   * space characters that are a line wrap point, this will return
   * the position before the line break.
   */
  coordsForElement(pos: number) {
    this.ensureFlushed()
    return this.docTile.coordsForElement(pos)
  }

  /** Check whether the editor has focus. */
  get hasFocus(): boolean {
    // Safari return false for hasFocus when the context menu is open
    // or closing, which leads us to ignore selection changes from the
    // context menu because it looks like the editor isn't focused.
    // This kludges around that.
    return (
      (this.dom.ownerDocument.hasFocus() || (browser.safari && this.inputState?.lastContextMenu > Date.now() - 3e4)) &&
      this.root.activeElement == this.contentDOM
    )
  }

  /** Put focus on the editor. */
  focus() {
    // While the browser has a change to apply (see `flush`), the editor
    // has focus, and the DOM selection must stay where the change goes.
    if (this.connected && !this.inputState.pendingInputEvent) {
      this.observer.ignore(() => {
        this.contentDOM.focus({ preventScroll: true })
        if (this.willFlush && this.flushing == Flush.No && this.viewState.pending.some(tr => tr.docChanged)) {
          this.flush()
        }
        setDOMSelection(this)
      })
    }
  }

  /** Get the CSS classes for the currently active editor themes. */
  get themeClasses() {
    let scheme = this.state.facet(colorScheme)
    if (scheme == 'auto') scheme = this.autoColorScheme
    return `${styleID} ${scheme == 'dark' ? baseDarkID : baseLightID} ${this.state.facet(theme)}`
  }

  /**
   * Returns an effect that can be {@link Transaction.Spec.effects
   * added} to a transaction to cause it to scroll the given position
   * or range into view.
   */
  static scrollIntoView(pos: number | GardSelection, options: Wordgard.ScrollSpec = {}): Transaction.Effect<unknown> {
    const [from, to, assoc]: [number, number, -1 | 1] =
      typeof pos == 'number'
        ? [pos, pos, -1]
        : [pos.from, pos.to, pos.empty ? pos.headSide : pos.head < pos.anchor ? -1 : 1]
    return scrollIntoView.of(
      new ScrollTarget(from, to, assoc, {
        y: options.y || 'nearest',
        x: options.x || 'nearest',
        yMargin: options.yMargin ?? 5,
        xMargin: options.xMargin ?? 5
      })
    )
  }

  /**
   * Add an
   * [`aria-label`](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-label)
   * attribute to the editable element holding the given string or
   * phrase.
   */
  static label(label: string | PhraseSet.Ref) {
    return Wordgard.editorAttributes.of(
      typeof label == 'string' ? { 'aria-label': label } : wg => ({ 'aria-label': label(wg.state) })
    )
  }

  /**
   * Filter functions provided through this facet will be run on a
   * slice before it is serialized to the clipboard. The slice holds
   * its context. Copy, cut and drag pass the selection's content.
   */
  static clipboardOutputFilter = clipboardOutputFilter

  /**
   * Filter functions provided through this facet will be run on an
   * HTML string before it put onto the clipboard.
   */
  static clipboardOutputHTMLFilter = clipboardOutputHTMLFilter

  /**
   * This can be used to provide a function that converts a document
   * slice to a string that is put onto the plain-text clipboard.
   * Serializers are tried in order of precedence until one returns
   * a string.
   */
  static clipboardTextSerializer = clipboardTextSerializer

  /**
   * Filter to run on the plain text representation of content put
   * onto the clipboard.
   */
  static clipboardOutputTextFilter = clipboardOutputTextFilter

  /**
   * Filter functions provided through this facet will be run on a
   * slice after it is read from the clipboard. The slice holds its
   * context.
   */
  static clipboardInputFilter = clipboardInputFilter

  /**
   * Filter functions to run on HTML text that is read from the
   * clipboard.
   */
  static clipboardInputHTMLFilter = clipboardInputHTMLFilter

  /**
   * When the editor reads plain text from the clipboard, this facet
   * can be used to provide a custom parser. Each provided function
   * is tried in order of precedence, until one returns a slice.
   */
  static clipboardTextParser = clipboardTextParser

  /** Filter to run on plain text read from the clipboard. */
  static clipboardInputTextFilter = clipboardInputTextFilter

  /**
   * Facet that allows you to register handlers to override paste
   * behavior.
   */
  static pasteHandler = pasteHandler

  /**
   * Facet for custom drop handlers. When the drop is done inside the
   * editor and should move an existing range, the `move` parameter
   * will hold the origin range.
   */
  static dropHandler = dropHandler

  /**
   * This annotation is added to transactions created because the
   * editor's focused status changed. It holds `true` when the editor
   * gained focus, `false` when it lost focus.
   */
  static isFocusChange = isFocusChange

  /**
   * Facet to add a [style
   * module](https://github.com/marijnh/style-mod#documentation) to
   * an editor. The editor will ensure that the module is mounted in
   * its {@link Wordgard.root document root}.
   */
  static styleModule = GardState.Facet.define<StyleModule>()

  /**
   * Returns an extension that can be used to add a DOM event handler
   * to the editor. For any given event, such functions are ordered
   * by extension precedence, and the first handler to return true
   * will be assumed to have handled that event, and no other
   * handlers or built-in behavior will be activated for it. These
   * are registered on the {@link Wordgard.contentDOM content
   * element}, except for `scroll` handlers, which will be called any
   * time the editor's {@link Wordgard.scrollDOM scroll element} or
   * one of its parent nodes is scrolled.
   */
  static domEventHandler<Event extends keyof HTMLElementEventMap>(
    event: Event,
    handler: (event: HTMLElementEventMap[Event], wg: Wordgard) => boolean | void
  ): GardState.Extension {
    return eventHandler.of({ event, handler: handler as any })
  }

  /**
   * Create an extension that registers a DOM event observers. Contrary
   * to event {@link Wordgard.domEventHandler handlers},
   * observers can't be prevented from running by a higher-precedence
   * handler returning true. They also don't prevent other handlers
   * and observers from running when they return true, and should not
   * call `preventDefault`.
   */
  static domEventObserver<Event extends keyof HTMLElementEventMap>(
    event: Event,
    observer: (event: HTMLElementEventMap[Event], wg: Wordgard) => void
  ): GardState.Extension {
    return eventObserver.of({ event, observer: observer as any })
  }

  /**
   * Scroll handlers can override how editor content is scrolled into
   * view. If they return `true`, no further handling happens for the
   * scrolling. If they return false, the default scroll behavior is
   * applied. Scroll handlers should never initiate editor updates.
   */
  static scrollHandler =
    GardState.Facet.define<(wg: Wordgard, target: { from: number; to: number } & Wordgard.ScrollSpec) => boolean>()

  /**
   * Allows you to provide a function that should be called when the
   * library catches an exception from an extension (mostly from
   * plugins, but may be used by other extensions to route exceptions
   * from user-code-provided callbacks). This is mostly useful for
   * debugging and logging. See {@link Wordgard.logException}.
   */
  static exceptionSink = exceptionSink

  /**
   * Registers a listener function to be called whenever a set of
   * transactions is applied to the editor. This function may
   * dispatch additional transactions, if needed.
   */
  static transactionListener = GardState.Facet.define<(trs: readonly Transaction[], wg: Wordgard) => void>()

  private runTransactionListeners(trs: readonly Transaction[]) {
    for (const l of this.state.facet(Wordgard.transactionListener)) {
      const has = this.pendingTransactionListeners.get(l)
      this.pendingTransactionListeners.set(l, has ? has.concat(trs) : trs)
    }
    for (;;) {
      const next = this.pendingTransactionListeners.keys().next()
      if (next.done) break
      const trs = this.pendingTransactionListeners.get(next.value)!
      this.pendingTransactionListeners.delete(next.value)
      next.value(trs, this)
    }
  }

  /**
   * A facet that can be used to register a function to be called
   * after the editor flushes updates to the DOM. Dispatching
   * transactions from such a function is allowed, but will cause a
   * new, separate update to happen.
   */
  static updateListener = GardState.Facet.define<(update: Wordgard.Update) => void>()

  /**
   * Facet that controls whether the editor content DOM is editable.
   * When its highest-precedence value is `false`, the element will
   * not have its `contenteditable` attribute set. (Note that this
   * doesn't affect API calls that change the editor content, even
   * when those are bound to keys or buttons. See the {@link
   * GardState.readOnly `readOnly` facet} for that.)
   *
   * A non-editable editor will, by default, not be focusable. You
   * can set a {@link Wordgard.contentAttributes content attribute}
   * of `tabindex: 0` to make an uneditable Wordgard focusable.
   */
  static editable = GardState.Facet.define<boolean, boolean>({ combine: values => (values.length ? values[0]! : true) })

  /**
   * Controls the length of a full cursor blink cycle, in milliseconds.
   * Defaults to 1200. Can be set to 0 to disable blinking.
   */
  static cursorBlinkRate = cursorBlinkRate

  /**
   * Allows you to influence the way mouse selection happens. The
   * functions in this facet will be called for a `mousedown` event
   * on the editor, and can return an object that overrides the way a
   * selection is computed from that mouse click or drag.
   */
  static mouseSelectionStyle = mouseSelectionStyle

  /**
   * Facet used to configure whether a given selection drag event
   * should move or copy the selection. The given predicate will be
   * called with the `mousedown` event, and can return `true` when
   * the drag should move the content. The default behavior is to
   * copy when holding Alt on Mac and Control on other platforms, and
   * move otherwise.
   */
  static dragMovesSelection = dragBehavior

  /** @internal */
  getScrollMargins() {
    let left = 0,
      right = 0,
      top = 0,
      bottom = 0
    for (const source of this.state.facet(Wordgard.coveredMargins)) {
      const m = source(this)
      if (m) {
        if (m.left != null) left = Math.max(left, m.left)
        if (m.right != null) right = Math.max(right, m.right)
        if (m.top != null) top = Math.max(top, m.top)
        if (m.bottom != null) bottom = Math.max(bottom, m.bottom)
      }
    }
    return { left, right, top, bottom }
  }

  /**
   * Create a theme extension. The first argument can be a
   * [`style-mod`](https://github.com/marijnh/style-mod#documentation)
   * style spec providing the styles for the theme. These will be
   * prefixed with a generated scope class.
   *
   * Because the selectors are prefixed, rules that directly match
   * the editor's {@link Wordgard.dom wrapper element} (to which the
   * scope class will be added) need to be explicitly differentiated
   * by adding an `&` to the selector for that element—for example
   * `&:has(wg-content:focus)`.
   */
  static theme(spec: Record<string, StyleSpec>): GardState.Extension {
    const prefix = StyleModule.newName()
    return [
      theme.of(prefix),
      Wordgard.styleModule.of(
        buildTheme(`.${prefix}`, spec, {
          '&dark': `.${prefix}.${baseDarkID}`,
          '&light': `.${prefix}.${baseLightID}`
        })
      )
    ]
  }

  /**
   * This facet controls whether a dark or light color scheme is
   * active, which determines whether style rules with a `&dark` or
   * `&light` selector are applied. Defaults to `"light"`. If set to
   * `"auto"`, the editor uses a CSS `prefers-color-scheme: dark`
   * query to determine whether to enable light or dark mode.
   *
   * Note that setting this to dark will not automatically make the
   * editor look dark. The default styling does not override the
   * inherited background and color of the editor. In case of a
   * page-wide `prefers-color-scheme` selection, those might already
   * be dark. But when setting an editor on a light background to
   * explicitly to use a dark theme, you'll need to make sure you
   * also load styles for that.
   */
  static colorScheme = colorScheme

  /** @internal */
  configureColorScheme(scheme: 'light' | 'dark') {
    if (this.autoColorScheme == scheme) return
    this.autoColorScheme = scheme
    if (!this.state.facet(colorScheme)) this.observer.ignore(() => this.updateAttrs())
  }

  /**
   * Create an extension that loads a set of style rules. Like
   * with {@link Wordgard.theme `theme`}, use `&` to indicate the
   * place of the editor wrapper element when directly targeting
   * that. You can also use `&dark` or `&light` instead to only
   * target editors with a dark or light {@link Wordgard.colorScheme
   * color scheme}.
   */
  static styles(spec: Record<string, StyleSpec>): GardState.Extension {
    return GardState.prec.lowest(Wordgard.styleModule.of(buildTheme(`.${styleID}`, spec, lightDarkIDs)))
  }

  /**
   * Creates a simple theme that sets a height (given in pixels or,
   * if a string, a CSS number + unit) and automatic overflow
   * scrolling on the editor. (The default styling makes the editor
   * height fit its content.)
   */
  static scrolling(height: number | string) {
    return Wordgard.theme({
      '&': {
        height: typeof height == 'number' ? `${height}px` : height
      },
      'wg-scroller': {
        overflowY: 'auto'
      }
    })
  }

  /**
   * Provides a Content Security Policy nonce to use when creating
   * the style sheets for the editor. Holds the empty string when no
   * nonce has been provided.
   */
  static cspNonce = GardState.Facet.define<string, string>({ combine: values => (values.length ? values[0]! : '') })

  /**
   * Facet that provides additional DOM attributes for the editor's
   * editable DOM element, either directly, or as a function from the
   * editor state.
   */
  static contentAttributes = GardState.Facet.define<AttrSource>()

  /**
   * Facet that provides DOM attributes for the editor's outer
   * element.
   */
  static editorAttributes = GardState.Facet.define<AttrSource>()

  /**
   * State effect used to include screen reader announcements in a
   * transaction. These will be added to the DOM in a visually hidden
   * element with `aria-live="polite"` set, and should be used to
   * describe effects that are visually obvious but may not be
   * noticed by screen reader users (such as moving to the next
   * search match).
   */
  static announce = Transaction.Effect.define<string>()

  /** @internal for testing */
  static DocTile = DocTile

  /**
   * Facet that allows extensions to indicate that some amount of
   * space around the sides of the scrolling element should be
   * considered blocked from view when scrolling something into view.
   * This is only used by plugins that introduce elements that cover
   * part of the editor (for example a gutter).
   */
  static coveredMargins = GardState.Facet.define<(wg: Wordgard) => Partial<DOMRect> | null>()
}

let _wrapElement: { new (wg: Wordgard): HTMLElement } | null = null

function wrapElementConstructor() {
  const ctor = class extends HTMLElement {
    constructor(readonly wg: Wordgard) {
      super()
    }
    connectedCallback() {
      this.wg && this.wg.setConnected(true)
    }
    disconnectedCallback() {
      this.wg && this.wg.setConnected(false)
    }
  }
  // Need to register a name before browsers let you instantiate a
  // custom element. Try multiple names in case multiple versions of
  // the library are loaded.
  for (let i = 0; ; i++) {
    const name = i ? `wordgard-editor-${i}` : 'wordgard-editor'
    if (!customElements.get(name)) {
      customElements.define(name, ctor)
      break
    }
  }
  return ctor
}

function createWrapElement(wg: Wordgard) {
  if (!_wrapElement) _wrapElement = wrapElementConstructor()
  return new _wrapElement(wg)
}

function attrsFromFacet(wg: Wordgard, facet: GardState.Facet<AttrSource>, base: string[]): Attributes {
  for (let sources = wg.state.facet(facet), i = sources.length - 1; i >= 0; i--) {
    const source = sources[i],
      value = typeof source == 'function' ? source(wg) : source
    for (const attr in value) {
      const attrVal = value[attr]
      if (attrVal != null) Attributes.push(base, attr, attrVal)
    }
  }
  return base
}

export namespace Wordgard {
  /** The type of object given to {@link Wordgard.create}. */
  export interface Spec extends Partial<GardState.Spec> {
    /**
     * The editor's initial state. If not given, a new state is
     * created by passing this configuration object to {@link
     * GardState.create}, using its `doc`, `selection`, and
     * `config` fields (if provided).
     */
    state?: GardState
    /**
     * When present, the editor is immediately appended to the given
     * element on creation. (Otherwise, you'll have to place the
     * editor {@link Wordgard.dom element} in the document yourself.)
     */
    parent?: Element | DocumentFragment
    /**
     * Pass an effect created with {@link Wordgard.scrollIntoView}
     * here to set an initial scroll position.
     */
    scrollTo?: Transaction.Effect<any>
  }

  /** Options passed to {@link Wordgard.scrollIntoView}. */
  export type ScrollSpec = {
    /**
     * By default (`"nearest"`) the position will be vertically
     * scrolled only the minimal amount required to move the given
     * position into view. You can set this to `"start"` to move it
     * to the top of the editor, `"end"` to move it to the bottom, or
     * `"center"` to move it to the center.
     */
    y?: 'nearest' | 'start' | 'end' | 'center'
    /** Effect similar to `y`, but for the horizontal scroll position. */
    x?: 'nearest' | 'start' | 'end' | 'center'
    /**
     * Extra vertical distance to add when moving something into
     * view. Not used with the `"center"` strategy. Defaults to 5.
     * Must be less than the height of the editor.
     */
    yMargin?: number
    /**
     * Extra horizontal distance to add. Not used with the `"center"`
     * strategy. Defaults to 5. Must be less than the width of the
     * editor.
     */
    xMargin?: number
  }

  /**
   * The interface that objects registered with {@link
   * Wordgard.mouseSelectionStyle} must conform to.
   */
  export interface MouseSelectionStyle {
    /**
     * Return a new selection for the mouse gesture that starts with
     * the event that was originally given to the constructor, and ends
     * with the event passed here. In case of a plain click, those may
     * both be the `mousedown` event, in case of a drag gesture, the
     * latest `mousemove` event will be passed.
     *
     * When `extend` is true, that means the new selection should, if
     * possible, extend the start selection.
     */
    get: (curEvent: MouseEvent, extend: boolean) => GardSelection
    /**
     * Called when the editor is updated while the gesture is in
     * progress. When the document changes, it may be necessary to map
     * some data (like the original selection or start position)
     * through the changes.
     *
     * This may return `true` to indicate that the `get` method should
     * get queried again after the update, because something in the
     * update could change its result. Be wary of infinite loops when
     * using this (where `get` returns a new selection, which will
     * trigger `update`, which schedules another `get` in response).
     */
    update: (update: Wordgard.Update) => boolean | void
  }

  /**
   * Log or report an unhandled exception in client code. Should
   * probably only be used by extension code that allows client code to
   * provide functions, and calls those functions in a context where an
   * exception can't be propagated to calling code in a reasonable way
   * (for example when in an event handler).
   *
   * Either calls a handler registered with {@link
   * Wordgard.exceptionSink}, `window.onerror`, if defined, or
   * `console.error` (in which case it'll pass `context`, when given,
   * as first argument).
   */
  export function logException(state: GardState, exception: any, context?: string) {
    // Inside this namespace, `logException` is this function.
    reportException(state, exception, context)
  }

  /**
   * Plugins associate stateful values with an editor. They can be
   * useful for displaying interface elements, or keeping ephemeral
   * interface state.
   */
  export class Plugin<V extends Wordgard.Plugin.Value> {
    /** Instances of this class act as extensions. */
    extension: GardState.Extension

    private constructor(
      /** @internal */
      readonly create: (wg: Wordgard) => V,
      buildExtensions: (plugin: Wordgard.Plugin<V>) => GardState.Extension
    ) {
      this.extension = buildExtensions(this)
    }

    /**
     * Define a plugin from a constructor function that creates the
     * plugin's value, given an editor.
     */
    static define<V extends Wordgard.Plugin.Value>(
      create: (wg: Wordgard) => V,
      provide?: (plugin: Wordgard.Plugin<V>) => GardState.Extension
    ) {
      return new Wordgard.Plugin<V>(create, plugin => {
        const ext = [editorPlugin.of(plugin)]
        if (provide) ext.push(provide(plugin))
        return ext
      })
    }

    /**
     * Create a plugin for a class whose constructor takes an editor
     * as only argument.
     */
    static fromClass<V extends Wordgard.Plugin.Value>(
      cls: { new (wg: Wordgard): V },
      provide?: (plugin: Wordgard.Plugin<V>) => GardState.Extension
    ) {
      return Wordgard.Plugin.define(wg => new cls(wg), provide)
    }

    /**
     * Create an {@link Wordgard.domEventHandler event handler} for this
     * plugin. Usually called from the plugin's `provide` function.
     */
    eventHandler<Event extends keyof HTMLElementEventMap>(
      event: Event,
      handler: (event: HTMLElementEventMap[Event], wg: Wordgard, value: V) => boolean | void
    ): GardState.Extension {
      return eventHandler.of({
        event,
        handler: (event, wg) => {
          const value = wg.plugin(this)
          return value ? handler(event as HTMLElementEventMap[Event], wg, value) : false
        }
      })
    }

    /**
     * Create an {@link Wordgard.domEventObserver event observer} for this
     * plugin.
     */
    eventObserver<Event extends keyof HTMLElementEventMap>(
      event: Event,
      observer: (event: HTMLElementEventMap[Event], wg: Wordgard, value: V) => void
    ): GardState.Extension {
      return eventObserver.of({
        event,
        observer: (event, wg) => {
          const value = wg.plugin(this)
          if (value) observer(event as HTMLElementEventMap[Event], wg, value)
        }
      })
    }
  }

  export namespace Plugin {
    /** This is the interface plugin objects must expose. */
    export interface Value {
      /**
       * Notifies the plugin of an update that happened in the
       * editor. This is called _before_ the editor updates its own
       * DOM. It is responsible for updating the plugin's internal
       * state (including any state that may be read by plugin
       * fields) and _writing_ to the DOM for the changes in the
       * update. To avoid unnecessary layout recomputations, it
       * should _not_ read the DOM layout—use {@link
       * Wordgard.scheduleDOMRead} to schedule your
       * code in a DOM reading phase if you need to.
       */
      update?(update: Wordgard.Update): void

      /**
       * When present, this will be called when an update causes any
       * changes in the DOM representation of the document.
       */
      docUpdate?(wg: Wordgard): void

      /**
       * Called when the editor is attached to the DOM. If the plugin
       * needs to allocate any resource that must be released, or modify
       * something outside the editor, it should do it in this method,
       * and make sure to release/undo it in its `disconnect` method.
       */
      connect?(wg: Wordgard): void

      /**
       * Called when the editor is removed from the DOM, or the
       * plugin is removed from the editor.
       */
      disconnect?(wg: Wordgard): void

      /**
       * Called when the plugin is removed from an editor. This
       * should clean up any changes it made to the editor itself. If
       * the editor was connected to a document, {@link
       * Wordgard.Plugin.Value.disconnect `disconnect`} will be called
       * before this.
       */
      remove?(wg: Wordgard): void
    }
  }

  /**
   * Editor {@link Wordgard.Plugin plugins} and {@link
   * Wordgard.updateListener update listeners} are given instances of
   * this class whenever the editor is updated.
   */
  export class Update {
    /** The changes made to the document by this update. */
    readonly changes: ChangeSet

    private constructor(
      /** The editor that the update is associated with. */
      readonly editor: Wordgard,
      /** The previous editor state. */
      readonly startState: GardState,
      /** The new editor state. */
      readonly state: GardState,
      /** The transactions involved in the update. May be empty. */
      readonly transactions: readonly Transaction[],
      /** @internal */
      public flags: number
    ) {
      if (transactions.length) {
        this.changes = transactions[0]!.changes
        for (let i = 1; i < transactions.length; i++) this.changes = this.changes.compose(transactions[i]!.changes)
      } else {
        this.changes = ChangeSet.empty(startState.doc.length)
      }
    }

    /** @internal */
    static create(
      wg: Wordgard,
      startState: GardState,
      state: GardState,
      transactions: readonly Transaction[],
      flags = 0
    ) {
      return new Wordgard.Update(wg, startState, state, transactions, flags)
    }

    /**
     * Returns true when the document was modified or when the size
     * of the editor, or elements within the editor, changed.
     */
    get geometryChanged() {
      return this.docChanged || (this.flags & UpdateFlag.Geometry) > 0
    }

    /** True when this update indicates a focus change. */
    get focusChanged() {
      return (this.flags & UpdateFlag.Focus) > 0
    }

    /** Whether the document changed in this update. */
    get docChanged() {
      return !this.changes.empty
    }

    /** Whether the selection was explicitly set in this update. */
    get selectionSet() {
      return this.transactions.some(tr => tr.selection)
    }

    /** @internal */
    get empty() {
      return this.flags == 0 && this.transactions.length == 0
    }
  }
}

export const editorPlugin = GardState.Facet.define<Wordgard.Plugin<Wordgard.Plugin.Value>>()

const cursorPlugin: Wordgard.Plugin<any> = Wordgard.Plugin.fromClass(CursorLayer)

class PluginInstance {
  // When starting an update, all plugins have this field set to the
  // update object, indicating they need to be updated. When finished
  // updating, it is set to `null`. Retrieving a plugin that needs to
  // be updated with `editor.plugin` forces an eager update.
  mustUpdate: Wordgard.Update | null = null
  // This is null when the plugin is initially created, but
  // initialized on the first update.
  value: Wordgard.Plugin.Value | null = null
  // Set when the plugin has crashed, and will no longer run.
  deactivated = false

  constructor(public spec: Wordgard.Plugin<any>) {}

  update(wg: Wordgard) {
    if (!this.value) {
      if (!this.deactivated) {
        try {
          this.value = this.spec.create(wg)
        } catch (e) {
          logException(wg.state, e, 'Wordgard plugin crashed')
          this.deactivate(null)
        }
      }
    } else if (this.mustUpdate) {
      const update = this.mustUpdate
      this.mustUpdate = null
      if (this.value.update) {
        try {
          this.value.update(update)
        } catch (e) {
          logException(update.state, e, 'Wordgard plugin crashed')
          if (wg.connected && this.value.disconnect) {
            try {
              this.value.disconnect(wg)
            } catch {}
          }
          this.deactivate(wg)
        }
      }
    }
    return this
  }

  docUpdate(wg: Wordgard) {
    if (this.value?.docUpdate) {
      try {
        this.value.docUpdate(wg)
      } catch (e) {
        logException(wg.state, e, 'doc update listener')
      }
    }
  }

  connect(wg: Wordgard) {
    if (this.value?.connect) {
      try {
        this.value.connect(wg)
      } catch (e) {
        logException(wg.state, e, 'Wordgard plugin crashed')
        this.deactivate(wg)
      }
    }
  }

  disconnect(wg: Wordgard) {
    if (!this.value?.disconnect) return
    try {
      this.value.disconnect(wg)
    } catch (e) {
      logException(wg.state, e, 'Wordgard plugin crashed')
      this.deactivate(wg)
    }
  }

  remove(wg: Wordgard) {
    if (wg.connected) this.disconnect(wg)
    if (this.value?.remove) {
      try {
        this.value.remove(wg)
      } catch (e) {
        logException(wg.state, e, 'Wordgard plugin crashed')
      }
    }
  }

  deactivate(remove: Wordgard | null) {
    if (remove && this.value?.remove) {
      try {
        this.value.remove(remove)
      } catch {}
    }
    this.deactivated = true
    this.value = null
  }
}

export type AttrSource = Record<string, string | null> | ((wg: Wordgard) => Record<string, string | null>)

export enum UpdateFlag {
  Focus = 1,
  Geometry = 2
}
