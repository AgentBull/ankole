import { DOMElement } from './helper'
import { type parse } from './parse'

const noChildren: readonly any[] = []

/**
 * This class describes a DOM element, its attributes, and its
 * children. It is used in describing the structure of {@link
 * Node.Spec.shape nodes} and {@link editor.Decoration decorations}.
 *
 * Elements can provide a wrapping structure by having a content hole
 * somewhere in their children, which indicates where the structure
 * they wrap (typically a node's content) goes.
 *
 * The type parameter indicates the set of additional leaf types. By
 * default, it holds only `string` (as a shorthand for text nodes),
 * but elements used in decorations also support {@link editor.Widget
 * custom widgets}.
 */
export class Elt<T = string> {
  private constructor(
    /**
     * The element's tag name. May be prefixed with `"svg:"` or
     * `"math:"` to indicate an SVG or MathML element.
     */
    readonly tagName: string,
    /**
     * The set of attributes, as an {@link Attributes array of
     * strings}.
     */
    readonly attrs: Attributes,
    /** The element's children. */
    readonly children: readonly (T | Elt<T> | 0)[]
  ) {}

  /**
   * Create an element. See also {@link Elt.mk} for a more ergonomic
   * creation function.
   */
  static create<T = string>(
    tagName: string,
    attrs: Attributes,
    children: readonly (T | Elt<T> | 0)[]
  ): Elt<Exclude<T, Elt<any> | 0>> {
    return new Elt(tagName, attrs, children as any)
  }

  /**
   * Create an element, specifying the attributes as an object. Both
   * the set of attributesand the array of children are optional. The
   * literal number 0 is used to indicate a content hole in the
   * array of children.
   */
  static mk<T = string>(name: string, children?: (T | 0 | Elt<T>)[]): Elt<Exclude<T, Elt<any> | 0>>
  static mk<T = string>(
    name: string,
    attrs: Record<string, string>,
    children?: readonly (T | 0 | Elt<T>)[]
  ): Elt<Exclude<T, Elt<any> | 0>>
  static mk<T>(
    name: string,
    arg1?: Record<string, string> | readonly (T | Elt<T> | 0)[],
    arg2?: readonly (T | Elt<T> | 0)[]
  ) {
    const [attrs, children] = arg2
      ? [Attributes.read(arg1 as Record<string, string>), arg2]
      : !arg1
        ? [Attributes.none, noChildren]
        : Array.isArray(arg1)
          ? [Attributes.none, arg1 as readonly (T | Elt<T> | 0)[]]
          : [Attributes.read(arg1 as Record<string, string>), noChildren]
    return new Elt<T>(name, attrs, children.length == 1 && children[0] === 0 ? Elt.hole : children)
  }

  /** True if this element or one of its children has a content hole. */
  get hasContent(): boolean {
    return this.children.some(ch => ch === 0 || (ch instanceof Elt && ch.hasContent))
  }

  /**
   * Compare this element's tag name and attributes (not its
   * children) to another element.
   */
  eqTag(elt: Elt<any>) {
    return elt.tagName == this.tagName && Attributes.eq(this.attrs, elt.attrs)
  }

  /** @internal */
  eqChildren(elt: Elt<T>) {
    if (elt.children == this.children) return true
    if (this.children.length != elt.children.length) return false
    for (let i = 0; i < this.children.length; i++) {
      const a = this.children[i],
        b = elt.children[i]
      if (
        a !== b &&
        (!a ||
          !b ||
          typeof a != 'object' ||
          typeof b != 'object' ||
          (a as any).constructor != (b as any).constructor ||
          !(a as any).eq ||
          !(a as any).eq(b))
      ) {
        return false
      }
    }
    return true
  }

  /**
   * Compare this element (including its children) to another
   * element.
   */
  eq(other: any) {
    return other instanceof Elt && this.eqTag(other) && this.eqChildren(other)
  }

  /** @internal */
  outerDOM(doc = document) {
    const { tagName: name, attrs } = this
    const dom = name.startsWith('svg:')
      ? doc.createElementNS('http://www.w3.org/2000/svg', name.slice(4))
      : name.startsWith('math:')
        ? doc.createElementNS('http://www.w3.org/1998/Math/MathML', name.slice(5))
        : doc.createElement(name)
    for (let i = 0; i < attrs.length;) dom.setAttribute(attrs[i++]!, attrs[i++]!)
    return dom
  }

  /** @internal */
  wrap(wrapper: Elt<T>, target?: Elt.Selector) {
    if (target) {
      const added = this.modifyBySelector(wrapper, target)
      if (added) return added
    }
    return wrapper.fill([this])
  }

  /** @internal */
  addAttrs(attrs: Attributes, target?: Elt.Selector) {
    if (target) {
      const added = this.modifyBySelector(attrs, target)
      if (added) return added
    }
    return Elt.create(this.tagName, Attributes.merge(this.attrs, attrs), this.children)
  }

  /** @internal */
  fill(content: readonly (0 | T | Elt<T>)[]) {
    const children: (0 | T | Elt<T>)[] = []
    for (const ch of this.children) {
      if (ch === 0) {
        for (const c of content) children.push(c)
      } else if (ch instanceof Elt && ch.hasContent) {
        children.push(ch.fill(content))
      } else {
        children.push(ch)
      }
    }
    return new Elt(this.tagName, this.attrs, children)
  }

  private modifyBySelector(mod: Attributes | Elt<T>, target: Elt.Selector): Elt<T> | null {
    if (target.match(this)) return mod instanceof Elt ? mod.fill([this]) : this.addAttrs(mod)
    for (let i = 0; i < this.children.length; i++) {
      const ch = this.children[i]
      const matched = ch instanceof Elt ? ch.modifyBySelector(mod, target) : null
      if (matched) {
        const copy = this.children.slice()
        copy[i] = matched
        return Elt.create(this.tagName, this.attrs, copy)
      }
    }
    return null
  }

  /** Convert an element with string content to an HTML string. */
  toHTML(this: Elt<string>) {
    return toHTML(this)
  }

  /** Convert an element (with only string content) to a DOM tree. */
  toDOM(this: Elt<string>, doc?: Document) {
    return toDOM(this, doc) as Element
  }

  /** @internal */
  static empty: readonly any[] = []

  /** @internal */
  static hole: readonly [0] = [0]
}

const selfClosing = new Set([
  'area',
  'base',
  'br',
  'col',
  'command',
  'embed',
  'frame',
  'hr',
  'img',
  'input',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
  'menuitem'
])

export namespace Elt {
  /** A collection of elements or other content values. */
  export class Fragment<T = string> {
    private constructor(readonly content: readonly (T | Elt<T>)[]) {}

    /** Create a fragment. */
    static create<T = string>(content: readonly (T | Elt<T>)[]) {
      return new Fragment(content)
    }

    /** Convert this fragment to an HTML string. */
    toHTML(this: Fragment<string>) {
      return toHTML(this)
    }

    /** Convert this fragment to a DOM fragment. */
    toDOM(this: Fragment<string>, doc?: Document): DocumentFragment {
      const frag = getDoc(doc).createDocumentFragment()
      for (const ch of this.content) frag.appendChild(toDOM(ch, doc))
      return frag
    }
  }

  /** @internal */
  export class Selector {
    private constructor(
      readonly tag: string | null,
      readonly classes: readonly string[]
    ) {}

    eq(other: Elt.Selector) {
      return (
        other.tag == this.tag &&
        this.classes.length == other.classes.length &&
        this.classes.every((c, i) => c == other.classes[i])
      )
    }

    match(elt: Elt<any>) {
      if (this.tag && elt.tagName != this.tag) return false
      if (this.classes.length) {
        const tagCls = Attributes.get(elt.attrs, 'class')
        if (!tagCls) return false
        const pieces = tagCls.split(/ +/)
        for (const cls of this.classes) if (!pieces.includes(cls)) return false
      }
      return true
    }

    static parse(selector: string) {
      const name = /^[\w\d\-_\u0c00-\uffff]+/.exec(selector)
      const tag = name ? name[0] : null
      const classes: string[] = []
      let txt = name ? selector.slice(name[0].length) : selector
      for (;;) {
        const cls = /^\.[\w\d\-_\u0c00-\uffff]+/.exec(txt)
        if (!cls) break
        classes.push(cls[0].slice(1))
        txt = txt.slice(cls[0].length)
      }
      if (txt) throw new Error(`Invalid element selector ${selector}`)
      return new Selector(tag, classes)
    }
  }
}

function toHTML(content: Elt | Elt.Fragment): string {
  let html = ''
  function scan(elt: Elt<string> | string | 0) {
    if (typeof elt == 'string') {
      html += elt.replace(/[<&]/g, ch => (ch == '<' ? '&lt;' : '&amp;'))
      return
    } else if (elt === 0) {
      return
    }
    const { attrs } = elt
    let name = elt.tagName
    const svg = name.startsWith('svg:')
    if (svg) name = name.slice(4)
    const math = name.startsWith('math:')
    if (math) name = name.slice(5)
    if (svg && name == 'svg') html += `<svg xmlns="http://www.w3.org/2000/svg"`
    if (math && name == 'math') html += `<math xmlns="http://www.w3.org/1998/Math/MathML"`
    else html += `<${name}`
    for (let i = 0; i < attrs.length;) {
      const name = attrs[i++],
        val = attrs[i++]!
      html += ` ${name}="${val.replace(/["&]/g, ch => (ch == '"' ? '&quot;' : '&amp;'))}"`
    }
    if ((math || svg) && !elt.children.length) {
      html += '/>'
    } else if (!math && !svg && selfClosing.has(name)) {
      html += '>'
    } else {
      html += '>'
      for (const ch of elt.children) scan(ch)
      html += `</${name}>`
    }
  }
  if (content instanceof Elt.Fragment) for (const elt of content.content) scan(elt)
  else scan(content)
  return html
}

function getDoc(doc?: Document) {
  if (doc) return doc
  if (typeof document != 'object' || !document.createElement) throw new Error('No document available')
  return document
}

function toDOM(elt: Elt | string, doc?: Document): Element | Text {
  doc = getDoc(doc)
  if (typeof elt == 'string') {
    return doc.createTextNode(elt)
  } else {
    const dom = elt.outerDOM(doc)
    for (const ch of elt.children) if (ch !== 0) dom.appendChild(toDOM(ch as any, doc))
    return dom
  }
}

/**
 * Sets of attributes are stored in arrays of strings, with the even
 * indices holding attribute names, the odd ones attribute values. The
 * attributes are sorted by name.
 */
export type Attributes = readonly string[]

export namespace Attributes {
  /** The empty set of attributes. */
  export const none: Attributes = []

  /** Compare two attribute sets. */
  export function eq(a: Attributes, b: Attributes) {
    if (a == b) return true
    if (a.length != b.length) return false
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false
    return true
  }

  /** @internal */
  export function compare(a: Attributes, b: Attributes) {
    for (let iA = 0, iB = 0, score = 0; ;) {
      if (iA < a.length && iB < b.length && a[iA] == b[iB]) {
        if (a[iA + 1] != b[iB + 1]) score--
        iA += 2
        iB += 2
      } else if (iA < a.length && (iB == b.length || a[iA]! < b[iB]!)) {
        score--
        iA += 2
      } else if (iB < b.length && iA == a.length) {
        score--
        iB += 2
      } else {
        return score
      }
    }
  }

  /**
   * Combine two attribute sets, with b having higher precedence when
   * they set the same attribute.
   */
  export function merge(a: Attributes, b: Attributes) {
    if (!a.length) return b
    if (!b.length) return a
    const result: string[] = []
    for (let iA = 0, iB = 0; ;) {
      const kA = iA < a.length ? a[iA] : null,
        kB = iB < b.length ? b[iB] : null
      if (kA == kB) {
        if (kA == null) return result
        let value = b[iB + 1]
        if (kA == 'class') value = `${a[iA + 1]} ${value}`
        else if (kA == 'style') value = `${a[iA + 1]};${value}`
        result.push(kA, value!)
        iA += 2
        iB += 2
      } else if (kA != null && (kB == null || kA < kB)) {
        result.push(kA, a[iA + 1]!)
        iA += 2
      } else {
        result.push(kB!, b[iB + 1]!)
        iB += 2
      }
    }
  }

  /** @internal */
  export function push(a: string[], name: string, value: string) {
    let i = 0
    while (i < a.length && a[i]! < name) i += 2
    if (i < a.length && a[i] == name) {
      if (name == 'class') a[i + 1] += ` ${value}`
      else if (name == 'style') a[i + 1] += `;${value}`
      else a[i + 1] = value
    } else {
      a.splice(i, 0, name, value)
    }
  }

  /** Convert an attribute object into a set. */
  export function read(obj: Record<string, string | null>) {
    const result: string[] = []
    for (let prop in obj) {
      if (prop != '_') {
        let value = obj[prop]
        if (value != null) {
          if (prop.startsWith('style/')) {
            value = `${prop.slice(6)}: ${value}`
            prop = 'style'
          }
          Attributes.push(result, prop, value)
        }
      }
    }
    return result.length ? result : Attributes.none
  }

  /** Get the value of the given attribute. */
  export function get(attrs: Attributes, name: string) {
    for (let i = 0; i < attrs.length; i += 2) if (attrs[i] == name) return attrs[i + 1]
    return null
  }
}

export namespace Shape {
  /**
   * Declares the shape of a node or mark to be a simple element. A
   * parse rule can automatically be derived for it if the node or mark
   * has a default parameter or a `read` function is defined to
   * determine the parameter.
   */
  export type Element<Param> = {
    /** The element name to use. */
    element: string
    /**
     * A selector to use in the parse rule. Defaults to the element
     * name.
     */
    selector?: string
    /** Attributes to add to the element. */
    attributes?: Record<string, string> | ((param: Param) => Record<string, string>)
    /**
     * A helper to read a parameter value from the element. If this
     * returns {@link parse.Reject}, the parse rule will not apply.
     */
    readElement?: (element: DOMElement) => Param | typeof parse.Reject
    /**
     * When specifying the shape of a plot, this indicates whether this
     * node is an atom, meaning its content isn't editable through the
     * editor.
     */
    atom?: boolean
  }

  /**
   * Declares the shape of a node in a way that allows a more
   * complicated shape than {@link Shape.Element}. This will not
   * automatically create a parse rule, so you'll want to define
   * those yourself.
   */
  export type Structure<Param> = {
    /**
     * The structure as a tree of {@link Elt}s. If this is for a plot
     * that is not to be rendered as an atom, the structure should
     * contain a hole for the content.
     */
    structure: Elt<string> | ((param: Param) => Elt<string>)
    /**
     * If `structure` is a function, and the target node is a plot, use
     * this to specify whether the plot should be rendered as an atom
     * or with content.
     */
    atom?: boolean
  }

  /**
   * Declares that a mark is represented with a specific DOM attribute.
   * This allows a matching parse rule to be derived automatically in
   * most situations.
   */
  export type Attribute<Param> = {
    /** The name of the attribute. */
    attribute: string
    /**
     * Its value. When given as 0, which is ony valid when the
     * `Param` type is `string`, the value of the mark's parameter is
     * used directly.
     */
    value: (Param extends string ? 0 : never) | string | ((param: Param) => string | null)
    /**
     * An optional function that converts the value of the attribute
     * back into a parameter value. Used in the parse rule.
     */
    readAttribute?: (value: string) => Param | typeof parse.Reject
    /**
     * If the target node may be a composite shape (rather than a
     * single DOM element), you can provide a limited form of selector
     * here to target a specific element in that shape. Node names and
     * class names are supported, as in `"img"`, `"img.my-class"`, or
     * `".class1.class2"`. If no matching element is found, the
     * attributes will be added to the node's outer element, as normal.
     */
    preferTarget?: string
  }

  /**
   * Declares that a dynamic attribute or set of attributes should be
   * added to nodes with this mark. Will not produce an implicit parse
   * rule.
   */
  export type Attributes<Param> = {
    /**
     * The attributes to add, either directly or as a function of the
     * mark's parameter.
     */
    attributes: Record<string, string> | ((param: Param) => Record<string, string>)
    /**
     * A selector for the {@link Shape.Attribute.preferTarget
     * preferred target} element.
     */
    preferTarget?: string
  }
}

export class NodeShape {
  constructor(
    readonly atom: boolean,
    // Param type set to any to avoid variance issues.
    readonly create: (param: any) => Elt<string>
  ) {}

  static from<Param>(name: string, leaf: boolean, spec: Shape.Element<Param> | Shape.Structure<Param>) {
    let atom = spec.atom,
      create: (param: Param) => Elt<string>
    if ('element' in spec) {
      if (atom == null) atom = leaf
      const { element, attributes } = spec
      if (typeof attributes == 'function') {
        create = (param: Param) => Elt.create(element, Attributes.read(attributes(param)), atom ? Elt.empty : Elt.hole)
      } else {
        const elt = Elt.create(
          element,
          attributes ? Attributes.read(attributes) : Attributes.none,
          atom ? Elt.empty : Elt.hole
        )
        create = () => elt
      }
    } else {
      if (leaf) atom = true
      const { structure } = spec
      if (typeof structure == 'function') {
        if (atom == null) throw new Error(`Dynamic structure for tag ${name} must define an \`atom\` field`)
        create = structure
      } else {
        if (atom == null) atom = !structure.hasContent
        else if (atom != !structure.hasContent) {
          throw new Error(`Disagreement between \`atom\` field and structure for tag ${name}`)
        }
        create = () => structure
      }
    }
    if (atom == false && leaf) throw new Error(`Leaf tag ${name}'s shape must be atomic`)
    return new NodeShape(atom, create)
  }
}
