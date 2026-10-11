import { Slice, Leaf, Plot, Node, Pos, serialize, parse, Token } from '../doc'
import { GardState } from '../state'
import browser from './browser'

/** Clipboard content: a slice and the tags of the plots that are open at its start, innermost first. */
export type ClipboardContent = { slice: Slice; context: readonly Plot.Tag[] }

export const clipboardOutputFilter =
  GardState.Facet.define<(content: ClipboardContent, state: GardState) => ClipboardContent>()
export const clipboardOutputHTMLFilter = GardState.Facet.define<(html: string, state: GardState) => string>()
export const clipboardTextSerializer =
  GardState.Facet.define<(slice: Slice, context: readonly Plot.Tag[], state: GardState) => string | null>()
export const clipboardOutputTextFilter = GardState.Facet.define<(html: string, state: GardState) => string>()

export const clipboardInputFilter =
  GardState.Facet.define<(content: ClipboardContent, state: GardState) => ClipboardContent>()
export const clipboardInputHTMLFilter = GardState.Facet.define<(html: string, state: GardState) => string>()
export const clipboardTextParser = GardState.Facet.define<(text: string, state: GardState) => Slice | null>()
export const clipboardInputTextFilter = GardState.Facet.define<(html: string, state: GardState) => string>()

export function writeClipboard(state: GardState, slice: Slice, context: readonly Plot.Tag[], data: DataTransfer) {
  for (const filter of state.facet(clipboardOutputFilter)) ({ slice, context } = filter({ slice, context }, state))

  let includeContext = 0
  for (let i = 0; i < context.length; i++) {
    const next = context[i]!
    if (next.type.defining && (!includeContext || next.type != context[includeContext - 1]!.type)) {
      includeContext = i + 1
    } else if (next.type.defining || !next.isTextblock) break
  }
  const doc = detachedDoc(),
    dom = serialize
      .slice(slice, {
        context,
        includeContext,
        openAttr: 'wg-open'
      })
      .toDOM()

  let wrappers = 0
  for (;;) {
    const first = dom.firstChild
    const needsWrap = first?.nodeType == 1 ? wrapMap[first.nodeName.toLowerCase()] : undefined
    if (!needsWrap) break
    for (let i = needsWrap.length - 1; i >= 0; i--) {
      const wrapper = doc.createElement(needsWrap[i]!)
      wrapper.setAttribute('wg-wrap', 'true')
      while (dom.firstChild) wrapper.appendChild(dom.firstChild)
      dom.appendChild(wrapper)
      wrappers++
    }
  }

  // The first element carries the markers, so inline content that starts
  // with text gets a wrapping span.
  if (dom.firstChild && dom.firstChild.nodeType != 1) {
    const span = doc.createElement('span')
    span.appendChild(dom)
    dom.appendChild(span)
  }
  if (dom.firstChild) {
    const first = dom.firstChild as Element
    first.setAttribute('wg-content', 'true')
    // The exact slice, so that a paste into an editor with the same
    // schema does not depend on the HTML shapes. It holds the context
    // that the HTML holds: the closed plots and the included context.
    let open = 0,
      closed = 0
    for (const tok of slice.content) {
      if (tok.tokenType == Token.Type.Open) open++
      else if (tok.tokenType == Token.Type.Close) open ? open-- : closed++
    }
    const depth = Math.max(closed, includeContext)
    first.setAttribute(
      'wg-slice',
      JSON.stringify({ slice: slice.toJSON(), context: context.slice(0, depth).map(tag => tag.toJSON()) })
    )
  }

  const wrap = doc.createElement('div')
  wrap.appendChild(dom)

  let html = wrap.innerHTML
  for (const filter of state.facet(clipboardOutputHTMLFilter)) html = filter(html, state)
  data.setData('text/html', html)

  let text: string | undefined | null
  for (const serialize of state.facet(clipboardTextSerializer)) {
    text = serialize(slice, context, state)
    if (text != null) break
  }
  if (text == null) text = slice.textContent({ blockSeparator: '\n\n' })
  for (const filter of state.facet(clipboardOutputTextFilter)) text = filter(text, state)
  data.setData('text/plain', text)
}

function isOpen(elt: Element) {
  return (elt.getAttribute('wg-open') || null) as 'start' | 'end' | 'start end' | null
}

export function readClipboard(state: GardState, data: DataTransfer, targetContext: Pos, plain: boolean) {
  let html = data.getData('text/html')
  let text = data.getData('text/plain') || data.getData('Text') || data.getData('text/uri-list').replace(/\r?\n/g, ' ')
  let slice: Slice,
    context: readonly Plot.Tag[] = []
  const inCode = targetContext.parent.node.type.hasRole(Node.Role.Code)
  if (text && (inCode || !html || plain)) {
    for (const filter of state.facet(clipboardInputTextFilter)) text = filter(text, state)
    slice = readClipboardText(state, text, targetContext, plain)
  } else if (!html) {
    return null
  } else {
    for (const filter of state.facet(clipboardInputHTMLFilter)) html = filter(html, state)
    const dom = readHTML(html)
    if (browser.webkit) restoreReplacedSpaces(dom)

    const fromWordgard = dom.querySelector('[wg-content=true]')
    const exact = fromWordgard && readSliceData(state, fromWordgard.getAttribute('wg-slice'))
    if (exact) ({ slice, context } = exact)
    else {
      ;({ slice, context } = parse.slice(state.schema, dom, {
        collapseWhiteSpace: !fromWordgard,
        isOpen: fromWordgard ? isOpen : undefined
      }))
    }
    // Code takes text only. Without a text form, use the text of the HTML, one line for each block.
    if (inCode) {
      text = slice.textContent({ blockSeparator: '\n' })
      for (const filter of state.facet(clipboardInputTextFilter)) text = filter(text, state)
      slice = readClipboardText(state, text, targetContext, plain)
      context = []
    }
  }
  for (const filter of state.facet(clipboardInputFilter)) ({ slice, context } = filter({ slice, context }, state))
  return { slice, context }
}

// Read the slice that `writeClipboard` stores in `wg-slice`. Returns
// null when it is missing or does not fit the schema, so that the HTML
// is parsed instead.
function readSliceData(state: GardState, value: string | null): ClipboardContent | null {
  if (!value) return null
  const { schema } = state
  try {
    const data = JSON.parse(value)
    const slice = Slice.fromJSON(schema, data.slice)
    const context = (data.context as Node.JSON[]).map(json => schema.tagFromJSON(json))
    for (const tag of context) {
      if (!tag.isPlot) return null
      schema.validateTag(tag)
    }
    for (const tok of slice.content) {
      if (tok.tokenType == Token.Type.Node) schema.validate(tok)
      else if (tok.tokenType == Token.Type.Open) schema.validateTag(tok)
    }
    return { slice, context: context as Plot.Tag[] }
  } catch {
    return null
  }
}

function readClipboardText(state: GardState, text: string, context: Pos, plain: boolean) {
  const marks = plain ? [] : context.marks()
  // Text in code is literal. Line breaks become line break nodes.
  if (context.parent.node.type.hasRole(Node.Role.Code)) {
    const { lineBreak } = state.schema
    if (!lineBreak) return Slice.of([Leaf.text(text.replace(/\r?\n|\r/g, '\n'), marks)])
    const content: Token[] = []
    text.split(/\r\n?|\n/).forEach((line, i) => {
      if (i) content.push(lineBreak)
      if (line) content.push(Leaf.text(line, marks))
    })
    return Slice.of(content)
  }

  if (!plain) {
    for (const parser of state.facet(clipboardTextParser)) {
      const slice = parser(text, state)
      if (slice) return slice
    }
  }

  const lines = text.split(/(?:\r\n?|\n)+/)
  const content: Token[] = lines[0] ? [Leaf.text(lines[0], marks)] : []
  if (lines.length == 1) return Slice.of(content)
  const parent = (context.parent.node.inlineContent ? context.parent.parent || context.parent : context.parent).node.tag
  const wrapping = state.schema.findWrapping(parent.type, Leaf.Text)
  if (!wrapping || !wrapping.length) return Slice.of([Leaf.text(text.replace(/\r?\n|\r/g, ' '), marks)])
  const wrapper = wrapping[wrapping.length - 1]!
  content.push(Plot.End)
  for (let i = 1; i < lines.length - 1; i++) content.push(wrapper.create(lines[i] ? [Leaf.text(lines[i]!, marks)] : []))
  content.push(wrapper)
  const last = lines[lines.length - 1]
  if (last) content.push(Leaf.text(last, marks))
  return Slice.of(content)
}

// Trick from jQuery -- some elements must be wrapped in other
// elements for innerHTML to work. I.e. if you do `div.innerHTML =
// "<td>..</td>"` the table cells are ignored.
const wrapMap: { [node: string]: string[] } = {
  thead: ['table'],
  tbody: ['table'],
  tfoot: ['table'],
  caption: ['table'],
  colgroup: ['table'],
  col: ['table', 'colgroup'],
  tr: ['table', 'tbody'],
  td: ['table', 'tbody', 'tr'],
  th: ['table', 'tbody', 'tr']
}

let _detachedDoc: Document | null = null
function detachedDoc() {
  return _detachedDoc || (_detachedDoc = document.implementation.createHTMLDocument('title'))
}

function maybeWrapTrusted(html: string): string {
  const trustedTypes = (window as any).trustedTypes
  if (!trustedTypes) return html
  // With the require-trusted-types-for CSP, Chrome will block
  // innerHTML, even on a detached document. This wraps the string in
  // a way that makes the browser allow us to use its parser again.
  return trustedTypes.createPolicy('detachedDocument', { createHTML: (s: string) => s }).createHTML(html)
}

function readHTML(html: string) {
  const metas = /^(\s*<meta [^>]*>)*/.exec(html)
  if (metas) html = html.slice(metas[0].length)
  let elt: HTMLElement = detachedDoc().createElement('div')
  const firstTag = /<([a-z][^>\s]+)/i.exec(html)
  const wrap = firstTag ? wrapMap[firstTag[1]!.toLowerCase()] : undefined
  if (wrap) {
    const open = wrap.map(name => `<${name}>`).join('')
    const close = wrap
      .map(name => `</${name}>`)
      .reverse()
      .join('')
    html = open + html + close
  }
  elt.innerHTML = maybeWrapTrusted(html)
  if (wrap) for (let i = 0; i < wrap.length; i++) elt = elt.querySelector<HTMLElement>(wrap[i]!) || elt
  return elt
}

// Webkit browsers do some hard-to-predict replacement of regular
// spaces with non-breaking spaces when putting content on the
// clipboard. This tries to convert such non-breaking spaces (which
// will be wrapped in a plain span on Chrome, a span with class
// Apple-converted-space on Safari) back to regular spaces.
function restoreReplacedSpaces(dom: HTMLElement) {
  const nodes = dom.querySelectorAll(browser.chrome ? 'span:not([class]):not([style])' : 'span.Apple-converted-space')
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i]!
    if (node.childNodes.length == 1 && node.textContent == '\u00a0' && node.parentNode) {
      node.parentNode.replaceChild(dom.ownerDocument.createTextNode(' '), node)
    }
  }
}
