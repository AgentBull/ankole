import { Leaf, Node, parse } from '../../core/doc'

/**
 * `math`: a display formula. The node parameter is the LaTeX source. The block is a leaf, so it has
 * no editable text of its own; the formula editor writes a new leaf in its place.
 */
export const MathBlock = Leaf.Type.define<string>('Math', {
  group: Node.Group.Content,
  selectable: true,
  validate: 'string',
  toText: leaf => leaf.param as string,
  shape: {
    element: 'div',
    selector: 'div.math-block[data-math]',
    attributes: source => ({ class: 'math-block', contenteditable: 'false', 'data-math': source }),
    readElement: element => element.getAttribute('data-math') ?? parse.Reject
  }
})

/**
 * `inline-math`: an inline formula inside a paragraph or heading. Carries surrounding text formats,
 * style, link, discussion anchors, and extension attributes as marks.
 */
export const InlineMath = Leaf.Type.define<string>('InlineMath', {
  inline: true,
  selectable: true,
  validate: 'string',
  toText: leaf => leaf.param as string,
  shape: {
    element: 'span',
    selector: 'span[data-inline-math]',
    attributes: source => ({ class: 'math-inline', contenteditable: 'false', 'data-inline-math': source }),
    readElement: element => element.getAttribute('data-inline-math') ?? parse.Reject
  }
})
