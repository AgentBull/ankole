import { Plot, Node, Mark, Leaf, Slice, type Token, ChangeSet, Schema } from '../../src/core/doc'
import { Paragraph, Blockquote, CodeBlock, CodeBlockLanguage, Emphasis, Strong, Code, Link } from '../../src/core/types'
import { builder, basicBuilders, basicSchema } from './schema'
const { p, h1, pre, ul, ol, li, blockquote, img, br } = basicBuilders

export const Comment = Mark.Type.define<readonly number[]>('Comment', {
  target: Node.Group.Inline,
  set: { compare: (a, b) => a - b },
  shape: {
    attribute: 'data-comment',
    value: ids => ids.join(' '),
    readAttribute: value => value.split(' ').map(v => Number(v))
  }
})

export const schema = Schema.define(basicSchema.elements.concat(Comment))

const doc = builder(schema)

export function open(node: Plot) {
  return node.tag
}
export const close = Plot.End

export function slice(...tokens: (Token | string)[]) {
  return Slice.of(tokens.map(t => (typeof t == 'string' ? Leaf.text(t) : t)))
}

export function permute<T>(array: readonly T[]): readonly (readonly T[])[] {
  if (array.length < 2) return [array]
  const result: T[][] = []
  for (const [i, item] of array.entries()) {
    for (const other of permute(array.slice(0, i).concat(array.slice(i + 1)))) result.push([item, ...other])
  }
  return result
}

export function r(n: number) {
  return Math.floor(Math.random() * n)
}

export function rLetter() {
  return String.fromCharCode(97 + r(26))
}

export function rWord(len = 2 + r(5)) {
  let word = ''
  for (let i = 0; i < len; i++) word += rLetter()
  return word
}

export function randomImage() {
  return `data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"><text x="0" y="30">${rWord()}</text></svg>`
}

export function rDoc(minLength: number) {
  const stack: { tag: Plot.Tag; children: Node[] }[] = [{ tag: schema.docTag, children: [] }]
  let len = 0
  function open() {
    while (!r(5)) {
      for (const type of r(1) ? [blockquote()] : [r(1) ? ul() : ol(), li()]) {
        stack.push({ tag: type.tag, children: [] })
        len++
      }
    }
    stack.push({ tag: (r(5) ? p() : r(2) ? pre() : h1()).tag, children: [] })
    len++
  }
  function closeOne() {
    const top = stack.pop()!
    stack[stack.length - 1]!.children.push(top.tag.create(top.children))
    len++
  }
  function close() {
    closeOne()
    while (stack.length > 1 && (!schema.canContain(stack[stack.length - 1]!.tag.type, Paragraph.type) || r(3))) {
      closeOne()
    }
  }
  do {
    open()
    let marks = Mark.none
    for (let i = 0, elements = r(7); i < elements * 2 - 1; i++) {
      let node: Node
      if (i % 2) {
        if (marks.length && !r(3)) marks = marks[r(marks.length)]!.removeFromSet(marks)
        node = Leaf.text(' ', marks)
      } else {
        if (!r(5)) {
          const mark = r(2) ? (r(2) ? Emphasis : Strong) : r(2) ? Code : Link.of(`/${rWord()}`)
          marks = mark.addToSet(marks)
        }
        node = r(5) ? Leaf.text(rWord()) : r(2) ? br : img(randomImage())
        node = node.withMarks(marks)
      }
      len += node.length
      const { children } = stack[stack.length - 1]!,
        last = children.length ? children[children.length - 1] : null
      if (node.is(Leaf.Text) && last && last.is(Leaf.Text) && Mark.sameSet(last.marks, node.marks)) {
        children[children.length - 1] = Leaf.text(last.param + node.param, node.tag.marks)
      } else if (schema.canContain(stack[stack.length - 1]!.tag.type, node.type)) children.push(node)
    }
    close()
  } while (len < minLength)
  while (stack.length > 1) closeOne()
  return doc(stack[0]!.children)
}

export function rChangeSpec(doc: Plot.Doc) {
  for (let i = 0; i < 100; i++) {
    const change = generators[r(generators.length)]!(doc)
    if (change) return change
  }
  throw new Error(`Failed to generate a change for document ${doc}`)
}

const generators: ((doc: Plot.Doc) => ChangeSet.Spec | null)[] = [
  // Insert a few characters
  doc => {
    const pos = doc.resolve(r(doc.length))
    return pos.parent.node.inlineContent ? { from: pos.pos, insert: slice(rWord(1 + r(3))) } : null
  },
  // Delete some inline content
  doc => {
    const pos = r(doc.length),
      cx = doc.resolve(pos).parent
    if (!cx.node.inlineContent || cx.start == cx.end) return null
    const from = pos > cx.start ? pos - 1 : pos
    return { from, to: pos < cx.end && (from == pos || r(2)) ? pos + 1 : pos }
  },
  // Join two adjacent blocks
  doc =>
    scanBlocks(doc, (node, pos, parent, index) => {
      const prev = parent.content[index - 1]
      if (index && prev!.isPlot && node.content.every(ch => doc.schema.canContain((prev as Plot).type, ch.type))) {
        return { from: pos - 1, to: pos + 1 }
      }
    }),
  // Lift a block's content out to its parent
  doc =>
    scanBlocks(doc, (node, pos, parent) => {
      if (doc.schema.sharesContent(parent.type, node.tag.type)) {
        return [
          { from: pos, to: pos + 1 },
          { from: pos + node.length - 1, to: pos + node.length }
        ]
      }
    }),
  // Wrap a block in a blockquote
  doc =>
    scanBlocks(doc, (node, pos, parent) => {
      if (schema.canContain(parent.type, Blockquote.type) && schema.canContain(Blockquote.type, node.tag.type)) {
        return [
          { from: pos, insert: slice(open(blockquote())) },
          { from: pos + node.length, insert: slice(close) }
        ]
      }
    }),
  // Delete an entire node
  doc =>
    scanBlocks(doc, (node, pos, parent) => {
      if (parent.content.length > 1) return { from: pos, to: pos + node.length }
    }),
  // Mark some inline content
  doc => {
    const len = 2 + r(6),
      from = r(doc.length - len)
    return {
      from,
      to: from + len,
      add: !r(4) ? Comment.of([r(100)]) : !r(3) ? Emphasis : r(2) ? Strong : Link.of(`/${rWord()}`)
    }
  },
  // Remove a mark from some textblock
  doc =>
    scanBlocks(doc, (node, pos) => {
      if (node.isTextblock) {
        for (let i = 0; i < node.content.length; i++) {
          const marks = node.content[i]!.tag.marks
          if (marks.length) {
            return { from: pos, to: pos + node.length, remove: marks[r(marks.length)] }
          }
        }
      }
    }),
  // Change a mark on some list or code block
  doc =>
    scanBlocks(doc, (node, pos) => {
      if (node.tag == CodeBlock) return { from: pos, add: CodeBlockLanguage.of(rWord()) }
    })
]

function scanBlocks<T>(
  doc: Plot.Doc,
  f: (node: Plot, pos: number, parent: Plot, index: number) => T | null | undefined
): T | null {
  const found: T[] = []
  function explore(node: Plot, off: number) {
    for (let i = 0, pos = off; i < node.content.length; i++) {
      const child = node.content[i]!
      if (child.isLeaf) continue
      const val = f(child, pos, node, i)
      if (val != null) found.push(val)
      if (!child.inlineContent) explore(child, pos + 1)
      pos += child.length
    }
  }
  explore(doc, 0)
  return found.length ? found[r(found.length)]! : null
}

export function rChange(doc: Plot.Doc, parts = 1) {
  const specs: ChangeSet.Spec[] = []
  for (let i = 0; i < parts; i++) specs.push(rChangeSpec(doc))
  return ChangeSet.create(doc, { correct: specs })
}
