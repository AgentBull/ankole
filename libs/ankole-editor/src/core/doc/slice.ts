import type { Plot, Node, Leaf } from './node'
import { TextOutput } from './text'
import type { Schema } from './schema'
import { ValidationError } from './error'

/**
 * The type of tokens in a slice. A plot tag represents the point
 * where a plot is opened, {@link Plot.End} the point where a plot is
 * closed, and nodes just represent the insertion of that node.
 */
export type Token = Node | Plot.Tag | typeof Plot.End

export namespace Token {
  /** Tokens have a `tokenType` property holding oneof these values. */
  export enum Type {
    Open,
    Close,
    Node
  }

  /** @internal */
  export const End = {
    tokenType: Token.Type.Close,
    /** @internal */
    toString() {
      return '[end]'
    },
    toJSON() {
      return '.'
    }
  } as { tokenType: Token.Type.Close; toJSON(): '.' }

  /** A token's JSON representation. */
  export type JSON = Node.JSON | '.'

  /** Read a token from its JSON representation. */
  export function fromJSON(schema: Schema, value: JSON) {
    if (value === '.') return Token.End
    if (!value || typeof value.type != 'string') throw new ValidationError('Invalid slice JSON')
    const type = schema.getNode(value.type)
    return type?.isLeaf || 'content' in value ? schema.nodeFromJSON(value) : schema.tagFromJSON(value)
  }
}

/**
 * A slice represents a part of a document, as an array of tokens
 * plus a context. It is used to represent things like clipboard
 * content and insertions given when building a {@link ChangeSet
 * change set}.
 */
export class Slice {
  /** The length of the slice's content. */
  readonly length: number

  private constructor(
    /** The tokens contained in this slice. */
    readonly content: readonly Token[],
    /**
     * This slice's context, an array of tags that can be used as a
     * hint when the slice's content needs to be wrapped in
     * additional content to fit somewhere, ordered with the
     * innermost nodes in front. May be empty when there
     * is no context available.
     */
    readonly context: readonly Plot.Tag[]
  ) {
    this.length = content.reduce((l, e) => l + (e.tokenType == Token.Type.Node ? e.length : 1), 0)
  }

  /** Create a slice. */
  static of(content: readonly Token[], context?: readonly Plot.Tag[]) {
    return content.length || (context && context.length)
      ? new Slice(content, context || Slice.empty.context)
      : Slice.empty
  }

  /** Compare this slice to another one. */
  eq(other: Slice) {
    return (
      this.context.length == other.context.length &&
      this.context.every((tag, i) => tag.eq(other.context[i]!)) &&
      Slice.eq(this.content, other.content)
    )
  }

  /** Concatenate this slice to another slice. */
  concat(other: Slice) {
    return new Slice(Slice.concat(this.content, other.content), this.context)
  }

  /** Get the text content of the slice's tokens. */
  textContent(
    options: {
      blockSeparator?: string
      leafText?: string | ((node: Leaf) => string)
    } = {}
  ) {
    const { blockSeparator = '\n', leafText } = options
    const out = new TextOutput(
      blockSeparator,
      leafText == null ? undefined : typeof leafText == 'string' ? () => leafText : leafText
    )
    for (const tok of this.content) {
      if (tok.tokenType == Token.Type.Open) {
        if (tok.isTextblock) out.openBlock()
      } else if (tok.tokenType == Token.Type.Node) {
        if (tok.isLeaf) out.serialize(tok)
        else tok.iterate(node => !out.serialize(node))
      }
    }
    return out.text
  }

  /** The empty slice. */
  static empty = new Slice([], [])

  /** @internal */
  toString() {
    return `<${this.content.join()}>`
  }

  /**
   * Create a slice (with context) from the given range of document
   * content. `to` defaults to the end of the document.
   */
  static get(doc: Plot.Doc, from: number, to?: number) {
    return new Slice(doc.slice(from, to), doc.contextAt(from))
  }

  /** Convert this slice's tokens to a JSON-serializeable representation. */
  toJSON(): readonly Token.JSON[] {
    return this.content.map(e => e.toJSON())
  }

  /** Build a slice from its JSON representation. The context is empty. */
  static fromJSON(schema: Schema, json: readonly Token.JSON[]) {
    if (!Array.isArray(json)) throw new ValidationError('Invalid slice JSON')
    return Slice.of(json.map(value => Token.fromJSON(schema, value)))
  }

  /** @internal */
  static run(tokens: readonly Token[], track: SliceWalker, startPos = 0) {
    let pos = startPos
    for (const elt of tokens) {
      if (elt.tokenType == Token.Type.Open) track.open(elt, pos++)
      else if (elt.tokenType == Token.Type.Node) {
        track.node(elt, pos)
        pos += elt.length
      } else track.close(pos++)
    }
  }

  /** @internal */
  static concat(a: readonly Token[], b: readonly Token[]) {
    const tokens = a.slice()
    let i = 0
    if (a.length && b.length && b[0]!.tokenType == Token.Type.Node && a[a.length - 1]!.tokenType == Token.Type.Node) {
      b[0]!.pushTo(tokens as Node[])
      i = 1
    }
    for (; i < b.length; i++) tokens.push(b[i]!)
    return tokens
  }

  /** @internal */
  static slice(tokens: readonly Token[], from: number, to: number = 1e9) {
    if (from == to) return Slice.empty.content
    const result: Token[] = []
    let off = 0
    for (const elt of tokens) {
      const start = off
      off += elt.tokenType == Token.Type.Node ? elt.length : 1
      if (off <= from) continue
      if (start < from || off > to) {
        const inner = (elt as Node).sliceInner(Math.max(0, from - start), Math.min((elt as Plot).length, to - start))
        for (const token of inner) result.push(token)
      } else {
        result.push(elt)
      }
      if (off >= to) break
    }
    return result
  }

  /** @internal */
  static eq(a: readonly Token[], b: readonly Token[]) {
    if (a.length != b.length) return false
    for (let i = 0; i < a.length; i++) {
      const tA = a[i]!,
        tB = b[i]!
      if (tA.tokenType != tB.tokenType || (tA.tokenType != Token.Type.Close && !tA.eq(tB as any))) return false
    }
    return true
  }
}

export interface SliceWalker {
  node(node: Node, pos: number): void
  open(tag: Plot.Tag, pos: number): void
  close(pos: number): void
}
