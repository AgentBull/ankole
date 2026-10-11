import { Plot, Node, Leaf } from './node'
import { Slice, Token } from './slice'
import { Mark } from './mark'
import { Elt, Attributes } from './shape'

class SerializeContext {
  readonly emitNewlines: boolean
  readonly override: ((tag: Node.Tag) => Elt | null) | undefined
  constructor(
    options: serialize.Options,
    readonly openAttr?: string
  ) {
    this.emitNewlines = options.emitNewlines !== false
    this.override = options.override
  }
}

/**
 * Serialize a document to an array of {@link Elt elements} and
 * strings. These can be converted to a DOM structure with {@link
 * Elt.Fragment.toDOM} or an HTML string with {@link
 * Elt.Fragment.toHTML}. Will use the shapes specified in the {@link
 * Node.Spec.shape node specs}, unless {@link
 * serialize.Options.override overridden}.
 */
export function serialize(doc: Plot.Doc, options: serialize.Options = {}): Elt.Fragment {
  return Elt.Fragment.create(serializeChildren(doc.content, new SerializeContext(options)))
}

export namespace serialize {
  /** The options passed to serializer functions. */
  export interface Options {
    /**
     * Set this to true to replace nodes with the {@link
     * Node.Role.LineBreak `LineBreak`} role with newline characters.
     */
    emitNewlines?: boolean
    /**
     * Override the shape used for some tags. Return null to fall
     * back to the node's default shape.
     */
    override?: (tag: Node.Tag) => Elt | null
  }

  /** Serialize a single node. */
  export function node(node: Node, options: serialize.Options): Elt | string {
    return serializeChildren([node], new SerializeContext(options))[0]!
  }

  /** Serialize a slice. */
  export function slice(slice: Slice, options: slice.Options): Elt.Fragment {
    return Elt.Fragment.create(
      serializeChildren(
        flattenSlice(slice.content, options.context || [], options.includeContext || 0, !!options.openAttr),
        new SerializeContext(options, options.openAttr)
      )
    )
  }

  export namespace slice {
    /** Options passed to {@link serialize.slice}. */
    export interface Options extends serialize.Options {
      /**
       * If given, the serializer will set this attribute to
       * `"start"`, `"end"`, or `"start end"` for nodes that are open
       * at the start and/or end of the slice.
       */
      openAttr?: string
      /**
       * The slice's context. Will be used to determine the type of
       * open nodes at the start of the slice.
       */
      context?: readonly Plot.Tag[]
      /**
       * The amount of context nodes to include in the output.
       * Defaults to 0, meaning only use those that are open at the
       * start of the slice.
       */
      includeContext?: number
    }
  }
}

const genericTag = Plot.define('generic', {
  blockContent: Node.Group.All,
  shape: { element: 'div' }
})

const openMark = Mark.Type.define<'start' | 'end' | 'start end'>('Open', {
  shape: { attribute: 'wg-open', value: 0 },
  target: Node.Group.All
})

function flattenSlice(
  content: readonly Token[],
  context: readonly Plot.Tag[],
  includeContext: number,
  markOpen: boolean
): readonly Node[] {
  let depth = 0
  let i = 0
  const scan = (inner: boolean): readonly Node[] => {
    let result: Node[] = []
    for (; i < content.length;) {
      const tok = content[i++]!
      if (tok.tokenType == Token.Type.Close) {
        if (inner) break
        let tag = depth < context.length ? context[depth++] : genericTag
        if (markOpen) tag = tag!.withMarks(openMark.of('start').addToSet(tag!.marks))
        result = [tag!.create(result)]
      } else if (tok.tokenType == Token.Type.Open) {
        const content = scan(true)
        let tag = tok
        if (markOpen) tag = tag!.withMarks(openMark.of('end').addToSet(tag!.marks))
        result.push(tag!.create(content))
      } else {
        result.push(tok)
      }
    }
    return result
  }
  let result = scan(false)
  while (depth < includeContext && depth < context.length) {
    let tag = context[depth++]
    if (markOpen) tag = tag!.withMarks(openMark.of('start end').addToSet(tag!.marks))
    result = [tag!.create(result)]
  }
  return result
}

function serializeNodeInner(node: Node, cx: SerializeContext): Elt | string {
  let markAttrs: Attributes = Attributes.none,
    targeted: { attrs: Attributes; target: Elt.Selector }[] | undefined
  for (const mark of node.tag.marks) {
    if (mark.type.attribute) {
      if (mark.type == openMark) {
        markAttrs = Attributes.merge(markAttrs, [cx.openAttr!, mark.value as string])
      } else {
        const { target, get } = mark.type.attribute,
          attrs = get(mark.value)
        if (target && !node.isText) {
          ;(targeted || (targeted = [])).push({ attrs, target })
        } else if (!node.isText || mark.spanning) {
          markAttrs = Attributes.merge(markAttrs, attrs)
        }
      }
    }
  }
  if (node.is(Leaf.Text)) return markAttrs.length ? Elt.create('span', markAttrs, [node.param]) : node.param
  let children: readonly (string | Elt)[]
  if (node.isLeaf) {
    children = []
  } else {
    let { content } = node
    if (cx.emitNewlines && node.type.preserveWhitespace) content = lineBreaksToNewlines(content)
    children = serializeChildren(content, cx)
  }
  let elt = (cx.override && cx.override(node.tag)) || node.type.shape.create(node.tag.param)
  if (markAttrs.length) elt = elt.addAttrs(markAttrs)
  if (targeted) for (const { attrs, target } of targeted) elt = elt.addAttrs(attrs, target)
  return elt.hasContent ? withContent(elt, children) : elt
}

function withContent(elt: Elt, content: readonly (string | Elt)[]): Elt<string> {
  const children: (string | Elt)[] = []
  for (const ch of elt.children) {
    if (ch === 0) for (const inner of content) children.push(inner)
    else if (typeof ch == 'string') children.push(ch)
    else children.push(withContent(ch, content))
  }
  return Elt.create(elt.tagName, elt.attrs, children)
}

function lineBreaksToNewlines(nodes: readonly Node[]) {
  if (!nodes.some(n => n.type.hasRole(Node.Role.LineBreak))) return nodes
  const result: Node[] = []
  let lastText = false
  for (const node of nodes) {
    const next = node.type.hasRole(Node.Role.LineBreak) ? Leaf.text('\n', node.marks) : node
    if (lastText && next instanceof Plot) next.pushTo(result as Plot[])
    else result.push(next)
    lastText = next.isText
  }
  return result
}

class EltCx {
  children: (Elt | string)[] = []
  constructor(
    readonly tagName: string,
    readonly attrs: Attributes,
    readonly parent: EltCx | null
  ) {}
  pop() {
    const repr = Elt.create(this.tagName, this.attrs, this.children)
    const parent = this.parent!
    parent.children.push(repr)
    return parent
  }
}

function serializeChildren(children: readonly Node[], cx: SerializeContext): readonly (string | Elt)[] {
  const active: Mark[] = []
  let top = new EltCx('', Attributes.none, null)
  for (const child of children) {
    if (active.length || child.marks.some(p => p.type.element)) {
      let keep = 0
      let rendered = 0
      const eltMarks = []
      for (const mark of child.marks) if (mark.type.element) eltMarks.push(mark)
      while (keep < active.length && rendered < eltMarks.length) {
        const next = eltMarks[rendered]!
        if (!next.eq(active[keep]!) || !next.type.spanning) break
        keep++
        rendered++
      }
      while (keep < active.length) {
        top = top.pop()
        active.pop()
      }
      while (rendered < eltMarks.length) {
        const add = eltMarks[rendered++]!
        const repr = add.type.element!
        top = new EltCx(repr.name, repr.attrs(add.value), top)
        active.push(add)
      }
    }
    top.children.push(serializeNodeInner(child, cx))
  }
  for (let i = 0; i < active.length; i++) top = top.pop()
  return top.children
}
