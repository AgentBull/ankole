import { Plot, Node, Leaf, BaseType, BaseTag } from './node'
import { Mark } from './mark'
import { none, validate } from './helper'
import { SchemaError, ValidationError } from './error'

/**
 * A schema is a collection of node and mark types, including exactly
 * one document type, plus an optional set of {@link Schema.Override
 * overrides} that modify the relations between those elements. It
 * determines what kind of elements may occur in documents that
 * follow this schema, and where they can show up.
 */
export class Schema {
  private nodesByName: { [name: string]: Node.Type } = Object.create(null)
  private marksByName: { [name: string]: Mark.Type } = Object.create(null)
  private wrappingCache: { [key: string]: readonly Plot.Tag[] | null } = Object.create(null)
  private validated: WeakSet<Node> = new WeakSet()

  private constructor(
    /**
     * All the schema elements that make up this schema. Useful if you
     * want to base another schema on this one.
     */
    readonly elements: readonly Schema.Element[],
    /** The node types that are part of this schema. */
    readonly nodes: readonly Node.Type[],
    /** Mark types used in this schema. */
    readonly marks: readonly Mark.Type[],
    private plotContent: Map<Plot.Type, Node.Query>,
    private markTarget: Map<Mark.Type, Node.Query>,
    private nodeGroup: Map<Node.Type, Set<Node.Group>>,
    /** The plot tag used by documents in this schema. */
    readonly docTag: Plot.Tag<null>,
    /**
     * The {@link Node.Role.LineBreak line break} node defined in
     * this schema, if any.
     */
    readonly lineBreak: Leaf | null
  ) {
    for (const tag of nodes) this.nodesByName[tag.name] = tag
    for (const mark of marks) this.marksByName[mark.name] = mark
  }

  /** Create a document in this schema. */
  doc(children: readonly Node[]) {
    return Plot.Doc.new(this, children)
  }

  /**
   * Validate that a node and its content conform to this schema.
   * Will run automatically when creating a document.
   */
  validate(node: Node) {
    if (this.validated.has(node)) return
    if (node.isLeaf) {
      this.validateTag(node)
    } else {
      this.validateTag(node.tag)
      if (!node.type.canBeEmpty && node.content.length == 0) {
        throw new ValidationError(`Node ${node.name} with block content may not be empty`)
      }
      for (const ch of node.content) {
        if (!this.canContain(node.type, ch.type) || node.inlineContent != ch.isInline) {
          throw new ValidationError(`Node type ${node.name} cannot contain child ${ch.name}`)
        }
        this.validate(ch)
      }
    }
    this.validated.add(node)
  }

  /** @internal */
  validateTag(tag: Node | Plot.Tag) {
    if (this.nodesByName[tag.name] != tag.type) throw new ValidationError(`Tag type ${tag.name} not in schema`)
    for (const mark of tag.marks) this.validateMark(mark, tag.type)
  }

  /** @internal */
  validateMark(mark: Mark<any>, node: Node.Type) {
    if (this.marksByName[mark.name] != mark.type) throw new ValidationError(`Mark type ${mark.name} not in schema`)
    if (!this.markAllowed(mark.type, node)) {
      throw new ValidationError(`Mark type ${mark.name} cannot target node ${node.name}`)
    }
  }

  /**
   * Test whether the given mark or tag type is included in this
   * schema.
   */
  has(elt: Mark<any> | Mark.Type | Node.Type.Ref<any>) {
    if (elt instanceof Mark || elt instanceof BaseTag) elt = elt.type
    return (elt instanceof Mark.Type ? this.marksByName : this.nodesByName)[elt.name] == elt
  }

  /**
   * Test whether a node type matches the given {@link Node.Query
   * node query}.
   */
  matchNode(node: Node.Type, q: Node.Query): boolean {
    if (q instanceof Node.Group) {
      const groups = this.nodeGroup.get(node)
      return groups ? groups.has(q) : false
    }
    if (q instanceof BaseType) return q == node
    if (q instanceof BaseTag) return q.type == node
    if ('and' in q) return q.and.every(q => this.matchNode(node, q))
    return (q as readonly Node.Query[]).some(q => this.matchNode(node, q))
  }

  /** Test whether the given mark is allowed on the given node type. */
  markAllowed(mark: Mark.Type, node: Node.Type) {
    const target = this.markTarget.get(mark)
    return target ? this.matchNode(node, target) : false
  }

  /**
   * Returns true if there's at least one node type in the schema
   * that may occur in both `a` and `b`.
   */
  sharesContent(a: Plot.Type, b: Plot.Type) {
    for (const tp of this.nodes) if (this.canContain(a, tp) && this.canContain(b, tp)) return true
    return false
  }

  /**
   * Returns a copy of `to` with all the marks from `from` that it
   * doesn't already have, and that aren't dropped by the mark's
   * {@link Mark.Spec.keepOnTypeChange} configuration.
   */
  withMarksFrom<T extends Node.Tag>(from: Node.Tag, to: T): T {
    if (!from.marks.length) return to
    let marks = to.marks
    for (const mark of from.marks) {
      if (this.markAllowed(mark.type, to.type) && (mark.type.set || !mark.isInSet(marks))) {
        const { keepOnTypeChange } = mark.type.spec
        if (keepOnTypeChange && (keepOnTypeChange === true || keepOnTypeChange(from, to))) marks = mark.addToSet(marks)
      }
    }
    return to.withMarks(marks) as T
  }

  /** Check whether a given plot type can contain a given node type. */
  canContain(parent: Plot.Type, child: Node.Type) {
    if (child.isPlot && child.isDoc) return false
    const content = this.plotContent.get(parent)
    return content ? this.matchNode(child, content) : false
  }

  /**
   * Return the first {@link Leaf.Type.default defaultable} node tag that
   * can occur as a child of `parent`.
   */
  defaultContentTag(parent: Plot.Type): Node.Tag | null {
    for (const tag of this.nodes) if (tag.default && this.canContain(parent, tag)) return tag.default
    return null
  }

  /**
   * Return the first {@link Plot.Type.default defaultable} plot tag
   * that can be a child of `parent`.
   */
  defaultContentPlot(parent: Plot.Type): Plot.Tag | null {
    for (const tag of this.nodes) if (tag.default && tag.isPlot && this.canContain(parent, tag)) return tag.default
    return null
  }

  /** @internal */
  createDefault(parent: Plot.Type): Node {
    const child = this.defaultContentTag(parent)
    if (!child) throw new Error(`No defaultable child node for ${parent.name}`)
    return this.createAndFill(child)
  }

  /**
   * Create a node from a tag, optionally adding a default child if
   * this is a plot that cannot be empty.
   */
  createAndFill(parent: Node.Tag): Node {
    if (parent.isLeaf) return parent
    return parent.create(parent.type.canBeEmpty ? [] : [this.createDefault(parent.type)])
  }

  /**
   * Find a set of tags that `child` must be wrapped in to be able to
   * occur in `parent`. Will return the empty array if it fits
   * directly, and `null` if it cannot occur at all.
   */
  findWrapping(parent: Plot.Type, child: Node.Type): readonly Plot.Tag[] | null {
    const key = `${parent.name}-${child.name}`,
      cached = this.wrappingCache[key]
    if (cached !== undefined) return cached
    return (this.wrappingCache[key] = this.findWrappingInner(parent, child))
  }

  private findWrappingInner(parent: Plot.Type, child: Node.Type): readonly Plot.Tag[] | null {
    const seen: Set<Node.Type> = new Set(),
      work: Plot.Tag[][] = [[]]
    for (let i = 0; i < work.length; i++) {
      const path = work[i]!,
        at = path.length ? path[path.length - 1]!.type : parent
      for (const tag of this.nodes) {
        if (this.canContain(at, tag)) {
          if (tag == child) return path
          if (!seen.has(tag) && !tag.isLeaf && tag.default) {
            seen.add(tag)
            work.push(path.concat(tag.default))
          }
        }
      }
    }
    return null
  }

  /** Get the mark type with the given name in this schema. */
  getMark(name: string): Mark.Type | undefined {
    return this.marksByName[name]
  }

  /** Get the node type with the given name. */
  getNode(name: string): Node.Type | undefined {
    return this.nodesByName[name]
  }

  /**
   * Define a schema from a set of schema elements. The set must
   * contain precisely one document type, and no conflicting node or
   * mark names.
   */
  static define(spec: readonly Schema.Element[]) {
    const cached = findCachedSchema(spec)
    if (cached) return cached

    const tags: Node.Type[] = [Leaf.Text],
      marks: Mark.Type[] = []
    let defaultI = 0
    const tagNames: Set<string> = new Set(),
      markNames: Set<string> = new Set()
    const plotContent = new Map<Plot.Type, Node.Query>()
    const markTarget = new Map<Mark.Type, Node.Query>()
    const nodeGroup = new Map<Node.Type, Set<Node.Group>>()
    nodeGroup.set(Leaf.Text, new Set([Node.Group.Inline, Node.Group.Leaf, Node.Group.All]))
    const overrides: Schema.Override[] = spec.filter(e => e instanceof Schema.Override).reverse()
    const elements: (Node.Type | Mark.Type | Schema.Override)[] = []

    for (const e of spec) {
      const elt = normalizeElt(e)
      elements.push(elt)
      if (elt instanceof Plot.Type || elt instanceof Leaf.Type) {
        if (tags.includes(elt)) continue
        if (tagNames.has(elt.name)) throw new SchemaError(`Duplicate use of tag name ${elt.name} in schema`)
        tagNames.add(elt.name)
        if (elt.isPlot) {
          let content =
            elt.spec.inlineContent === true ? Node.Group.Inline : elt.spec.inlineContent || elt.spec.blockContent!
          for (const o of overrides) if (o.type == elt && o.content) content = o.content(content)
          plotContent.set(elt, content)
        }
        if (elt.isPlot && elt.spec.defaultBlock) tags.splice(defaultI++, 0, elt)
        else tags.push(elt)

        const groups = new Set<Node.Group>()
        groups.add(Node.Group.All)
        groups.add(elt.isInline ? Node.Group.Inline : Node.Group.Block)
        groups.add(elt.isLeaf ? Node.Group.Leaf : Node.Group.Plot)
        if (elt.isPlot && elt.isBlock && elt.inlineContent) groups.add(Node.Group.Textblock)
        let given = elt.spec.group instanceof Node.Group ? [elt.spec.group] : elt.spec.group
        for (const o of overrides) if (o.type == elt && o.group) given = o.group
        if (given) {
          for (const g of given) {
            for (let cur: Node.Group | undefined = g; cur; cur = cur.parent) {
              if (!Node.Group.builtin.includes(cur)) groups.add(cur)
            }
          }
        }
        nodeGroup.set(elt, groups)
      } else if (elt instanceof Mark.Type) {
        if (marks.includes(elt)) continue
        if (markNames.has(elt.name)) throw new SchemaError(`Duplicate use of mark name ${elt.name} in schema`)
        let target = elt.spec.target || { and: [Node.Group.Inline, Node.Group.Leaf] }
        for (const o of overrides) if (o.type == elt && o.target) target = o.target(target)
        markTarget.set(elt, target)
        markNames.add(elt.name)
        marks.push(elt as any)
      } else if (!(elt instanceof Schema.Override)) {
        throw new SchemaError('Unexpected schema element type. You may have multiple versions of @wordgard/doc loaded')
      }
    }
    let docType: Plot.Type<null> | null = null
    let lineBreak: Leaf | null = null
    for (const tag of tags) {
      if (tag.isLeaf) {
        if (tag.hasRole(Node.Role.LineBreak)) {
          if (tag.isBlock || !tag.default) {
            throw new SchemaError('Line break tags must be inline leaves with a default param')
          }
          if (lineBreak) throw new SchemaError('Multiple line break tags provided')
          lineBreak = tag.default
        }
      } else {
        if (tag.isDoc) {
          if (docType) throw new SchemaError('Multiple document types specified')
          docType = tag as Plot.Type<null>
        }
      }
    }
    if (!docType) throw new SchemaError('A schema must define a document type')
    const schema = new Schema(
      elements,
      tags,
      marks,
      plotContent,
      markTarget,
      nodeGroup,
      docType.default!,
      lineBreak as Leaf | null
    )
    for (const tag of tags) {
      if (tag.isPlot) {
        let sawDefaultable = false
        for (const child of tags) {
          if (schema.canContain(tag, child)) {
            if (child.default) sawDefaultable = true
            if (child.isInline != tag.inlineContent) {
              throw new SchemaError(
                `Node type ${tag.name} has ${
                  tag.inlineContent ? 'block' : 'inline'
                } content, but allows ${child.name} as a child`
              )
            }
          }
        }
        if (!tag.canBeEmpty && !sawDefaultable) {
          throw new SchemaError(
            `Node ${tag.name} has required content, but all possible children require non-default parameters`
          )
        }
      }
    }
    schemaCache.set(spec, new WeakRef(schema))
    return schema
  }

  /** Deserialize a node from its JSON representation. */
  nodeFromJSON(json: Node.JSON): Node {
    const tag = this.tagFromJSON(json)
    let children = none
    if (tag.isLeaf) return tag
    if (json.content && Array.isArray(json.content)) children = json.content.map(c => this.nodeFromJSON(c))
    if (tag.type.isDoc) return this.doc(children)
    return tag.create(children)
  }

  /** Deserialize a tag from its JSON representation. */
  tagFromJSON(json: Node.JSON) {
    if (!json || typeof json != 'object' || !(json.type in this.nodesByName)) {
      throw new ValidationError('Invalid tag JSON')
    }
    const type = this.nodesByName[json.type]!
    const marks = json.marks ? this.marksFromJSON(json.marks) : none
    const tag =
      'param' in json
        ? type.of(validate(type.spec.validate, json.param), marks)
        : !type.default
          ? null
          : marks.length
            ? type.of(type.default.param, marks)
            : type.default
    if (!tag) throw new ValidationError(`Missing param for tag type ${type.name}`)
    return tag
  }

  /** Read a set of marks from their JSON representation. */
  marksFromJSON(json: Record<string, any>): Mark.Set {
    if (!json || typeof json != 'object') throw new ValidationError('Invalid mark JSON')
    let marks = none
    for (const name in json) {
      const mark = this.marksByName[name]
      if (!mark) throw new ValidationError(`Unrecognized mark ${name} in JSON`)
      marks = mark.of(validate(mark.spec.validate, json[name])).addToSet(marks)
    }
    return marks
  }

  /** Read a document from JSON. */
  docFromJSON(json: Node.JSON) {
    if (!json || json.type != this.docTag.name) throw new ValidationError('Invalid document JSON')
    return this.nodeFromJSON(json) as Plot.Doc
  }
}

const schemaCache = new Map<readonly Schema.Element[], WeakRef<Schema>>()

function findCachedSchema(spec: readonly Schema.Element[]) {
  search: for (const [elts, ref] of schemaCache) {
    const active = ref.deref()
    if (!active) {
      schemaCache.delete(elts)
    } else if (elts.length == spec.length) {
      for (let i = 0; i < spec.length; i++) {
        const a = normalizeElt(spec[i]!),
          b = normalizeElt(elts[i]!)
        if (a != b && !(a instanceof Schema.Override && b instanceof Schema.Override && a.eq(b))) continue search
      }
      return active
    }
  }
}

function normalizeElt(elt: Schema.Element): Node.Type | Mark.Type | Schema.Override {
  return elt instanceof Plot.Tag || elt instanceof Leaf || elt instanceof Mark ? elt.type : (elt as any)
}

export namespace Schema {
  /**
   * A schema element is any node tag or type, mark or mark type, or
   * override.
   */
  export type Element = Node.Tag | Node.Type | Mark | Mark.Type | Schema.Override

  /**
   * Though nodes and marks are mostly self-contained, a few of their
   * aspects can be overridden per schema.
   */
  export class Override {
    private constructor(
      /** @internal */
      readonly type: Mark.Type | Node.Type,
      /** @internal */
      readonly target?: (query: Node.Query) => Node.Query,
      /** @internal */
      readonly content?: (query: Node.Query) => Node.Query,
      /** @internal */
      readonly group?: readonly Node.Group[]
    ) {}

    /** @internal */
    eq(other: Schema.Override) {
      return (
        this == other ||
        (this.type == other.type &&
          this.target == other.target &&
          this.content == other.content &&
          this.group == other.group)
      )
    }

    /** @hidden */
    declare tag: 'schema.override'

    /**
     * Create a schema override that changes the target nodes for a
     * mark.
     */
    static markTarget(mark: Mark.Type | Mark, target: Node.Query | ((target: Node.Query) => Node.Query)) {
      return new Schema.Override(
        mark instanceof Mark.Type ? mark : mark.type,
        typeof target == 'function' ? target : () => target
      )
    }

    /**
     * Create a schema override that changes the content specification
     * for a given node. Note that this can not change a node with
     * inline content to block content or vice versa.
     */
    static plotContent(plot: Plot.Type | Plot.Tag, content: Node.Query | ((content: Node.Query) => Node.Query)) {
      return new Schema.Override(
        plot instanceof Plot.Tag ? plot.type : plot,
        undefined,
        typeof content == 'function' ? content : () => content
      )
    }

    /** Override the set of groups that a node may be part of. */
    static nodeGroup(node: Node.Type | Node.Tag, group: Node.Group | readonly Node.Group[]) {
      return new Schema.Override(
        node instanceof BaseTag ? node.type : (node as Node.Type),
        undefined,
        undefined,
        group instanceof Node.Group ? [group] : group
      )
    }
  }
}
