import { Elt, parse, Plot, Leaf, Node, Mark, ValidationError } from '../doc'

const G = Node.Group

/**
 * A hard line break. Renders as `<br>` and has the {@link
 * Node.Role.LineBreak | `LineBreak`} role.
 */
export const LineBreak = Leaf.define('LineBreak', {
  inline: true,
  role: Node.Role.LineBreak,
  toText: () => '\n',
  shape: { element: 'br' }
})

/**
 * A paragraph. Part of the {@link Node.Group.Content | `Content`}
 * group, allowing inline content, rendered as `<p>`.
 */
export const Paragraph = Plot.define('Paragraph', {
  inlineContent: true,
  group: G.Content,
  defaultBlock: true,
  shape: { element: 'p' }
})

/**
 * Heading plot. Its parameter indicates the heading level. In the
 * {@link Node.Group.Content | `Content`} group, allows inline
 * content, rendered as `<h1>` to `<h6>`.
 */
export const Heading = Plot.Type.define('Heading', {
  defaultParam: 1,
  validate: value => {
    if (typeof value != 'number' || Math.floor(value) != value || value < 1 || value > 6) {
      throw new ValidationError(`Invalid heading level: ${value}`)
    }
  },
  inlineContent: true,
  group: G.Content,
  shape: { structure: level => Elt.mk(`h${level}`, [0]), atom: false },
  defining: true,
  parseRules: [
    { selector: 'h1', param: 1 },
    { selector: 'h2', param: 2 },
    { selector: 'h3', param: 3 },
    { selector: 'h4', param: 4 },
    { selector: 'h5', param: 5 },
    { selector: 'h6', param: 6 }
  ]
})

/**
 * A code block. Part of the {@link Node.Group.Content | `Content`}
 * group, with the {@link Node.Role.Code | `Code`} role. Rendered
 * as `<pre>`.
 */
export const CodeBlock = Plot.define('CodeBlock', {
  inlineContent: [Leaf.Text, LineBreak],
  group: G.Content,
  role: Node.Role.Code,
  shape: { element: 'pre' }
})

/**
 * A mark that assigns a language identifier (any string) to a code
 * block. Stored in the `data-language` attribute.
 */
export const CodeBlockLanguage = Mark.Type.define<string>('CodeBlockLanguage', {
  target: CodeBlock,
  keepOnSplit: true,
  validate: 'string',
  shape: { attribute: 'data-language', value: 0 }
})

/**
 * Block list item. Allows any {@link Node.Group.Content | `Content`}
 * blocks as content. Rendered as `<li>`.
 */
export const ListItem = Plot.define('ListItem', {
  blockContent: G.Content,
  shape: { element: 'li' },
  defining: true
})

/**
 * List item with inline content. You'll want to have either this
 * plot type or {@link ListItem} in your schema, not both. Rendered
 * as `<li>`.
 */
export const InlineListItem = Plot.define('ListItem', {
  inlineContent: true,
  shape: { element: 'li' },
  defining: true
})

/**
 * Ordered list plot. Part of the {@link Node.Group.Content |
 * `Content`} group, allows either {@link ListItem} or {@link
 * InlineListItem} as content. Rendered as `<ol>`, with the parameter
 * providing the `start` attribute.
 */
export const OrderedList = Plot.Type.define('OrderedList', {
  defaultParam: 1,
  validate: 'number',
  blockContent: [ListItem, InlineListItem],
  group: G.Content,
  role: Node.Role.List,
  defining: true,
  shape: {
    element: 'ol',
    attributes: start => (start == 1 ? ({} as Record<string, string>) : { start: String(start) }),
    readElement: elt => Number(elt.getAttribute('start') || '1')
  },
  autoJoin: (_a, b) => b.param == 1
})

/**
 * An unordered list. Defaults to the {@link Node.Group.Content |
 * `Content`} group. Allows {@link ListItem} or {@link
 * InlineListItem} as content. Rendered as `<ul>`.
 */
export const BulletList = Plot.define('BulletList', {
  blockContent: [ListItem, InlineListItem],
  group: G.Content,
  role: Node.Role.List,
  defining: true,
  shape: { element: 'ul' },
  autoJoin: true
})

/**
 * A horizontal separator. Part of the {@link Node.Group.Content |
 * `Content`} group. Renders as `<hr>`.
 */
export const HorizontalRule = Leaf.define('HorizontalRule', {
  group: G.Content,
  shape: { element: 'hr' },
  toText: () => '---',
  selectable: true
})

function validatePosInt(value: any) {
  if (typeof value != 'number' || Math.round(value) != value || value < 1) {
    throw new RangeError(`${value} is not a positive integer`)
  }
}

function readPosInt(value: string) {
  const num = Number.parseInt(value)
  if (Number.isNaN(num) || num < 1) return parse.Reject
  return num
}

/**
 * Table cell column span. Rendered with the `colspan` attribute.
 * Must hold a positive integer. Is assumed
 * to be 1 when missing.
 */
export const ColSpan = Mark.Type.define<number>('ColSpan', {
  target: G.TableCell,
  validate: validatePosInt,
  shape: { attribute: 'colspan', value: span => String(span), readAttribute: readPosInt }
})

/**
 * Table cell row span. Rendered with the `rowspan` attribute.
 * Is assumed to be 1 when missing.
 */
export const RowSpan = Mark.Type.define<number>('RowSpan', {
  target: G.TableCell,
  validate: validatePosInt,
  shape: { attribute: 'rowspan', value: span => String(span), readAttribute: readPosInt }
})

/**
 * An inline image leaf. The string parameter is the image's source
 * URI. Rendered as `<img>`.
 */
export const Image = Leaf.Type.define<string>('Image', {
  inline: true,
  validate: 'string',
  shape: { element: 'img', attributes: src => ({ src }) },
  selectable: true,
  parseRules: [
    {
      selector: 'img[src]',
      readElement: elt => (elt as HTMLImageElement).src
    }
  ]
})

/**
 * A block image leaf. Renders as a `<figure>` element with an
 * `<img>` in it. The parameter holds the image URI.
 */
export const Figure = Leaf.Type.define<string>('Figure', {
  validate: 'string',
  shape: { structure: src => Elt.mk('figure', [Elt.mk('img', { src })]) },
  selectable: true,
  group: G.Content,
  parseRules: [
    {
      selector: 'figure:has(img[src])',
      marksFrom: 'img[src]',
      readElement: elt => (elt.querySelector('img[src]') as HTMLImageElement).src,
      precedence: 2
    }
  ]
})

/**
 * A textblock plot representing a captioned image. The image URI is
 * the plot's parameter, and the caption the content (inline).
 * Assigned to the {@link Node.Group.Content | `Content`} group by
 * default. Renders as a `<figure>` element with `<img>` and
 * `<figcaption>` elements as children.
 */
export const CaptionedFigure = Plot.Type.define<string>('CaptionedFigure', {
  inlineContent: true,
  validate: 'string',
  shape: { structure: src => Elt.mk('figure', [Elt.mk('img', { src }), Elt.mk('figcaption', [0])]), atom: false },
  group: G.Content,
  parseRules: [
    {
      selector: 'figure:has(img[src]):has(figcaption)',
      marksFrom: 'img[src]',
      readElement: elt => (elt.querySelector('img[src]') as HTMLImageElement).src,
      contentElement: 'figcaption',
      precedence: 4
    }
  ]
})

/** Image alt text. Renders as an `alt` attribute. */
export const ImageAlt = Mark.Type.define<string>('ImageAlt', {
  target: [Image, Figure, CaptionedFigure],
  validate: 'string',
  shape: { attribute: 'alt', value: 0, preferTarget: 'img' }
})

/**
 * Text alignment. Applies to any textblock or figure. Not having
 * this mark implies aligning to the start of the block. Renders as a
 * `text-align` style.
 */
export const Alignment = Mark.Type.define<'end' | 'center'>('Alignment', {
  target: [G.Textblock, Figure],
  keepOnSplit: true,
  keepOnTypeChange: true,
  shape: { attribute: 'style', value: align => `text-align: ${align}` },
  parseRules: [
    {
      attribute: 'style/text-align',
      readAttribute: value => (/^(end|center)$/.test(value) ? (value as any) : parse.Reject)
    }
  ]
})

/**
 * The text direction for a textblock. Not having this mark means the
 * document's base direction is used. `"auto"` means the direction is
 * derived from the first character in the block that has a strong
 * direction. Rendered using the `dir` attribute.
 */
export const Direction = Mark.Type.define<'ltr' | 'rtl' | 'auto'>('Direction', {
  target: G.Textblock,
  keepOnSplit: true,
  keepOnTypeChange: true,
  validate: val => {
    if (val != 'ltr' && val != 'rtl' && val != 'auto') throw new ValidationError(`Invalid direction value: ${val}`)
  },
  shape: { attribute: 'dir', value: 0 }
})

/** Emphasis mark. Rendered using the `<em>` element. */
export const Emphasis = Mark.define('Emphasis', {
  rank: 50,
  shape: { element: 'em' },
  parseRules: [
    { selector: 'i' },
    { attribute: 'style/font-style', value: 'italic' },
    { attribute: 'style/font-style', value: 'normal', clearMark: p => p.name == 'Emphasis' }
  ]
})

/** Strong emphasis mark. Rendered using the `<strong>` element. */
export const Strong = Mark.define('Strong', {
  rank: 60,
  shape: { element: 'strong' },
  parseRules: [
    // Google Docs wraps copied content in `<b style="font-weight: normal">`.
    { selector: 'b', readElement: elt => ((elt as HTMLElement).style.fontWeight == 'normal' ? parse.Reject : null) },
    // Only `bold` and 700 are bold. Lighter weights such as 500 and 600 are not.
    {
      attribute: 'style/font-weight',
      readAttribute: value => (/^(bold|700)$/.test(value) ? null : parse.Reject)
    },
    {
      attribute: 'style/font-weight',
      readAttribute: value => (/^(normal|lighter|[1-4]\d{2})$/.test(value) ? null : parse.Reject),
      clearMark: p => p.name == 'Strong'
    }
  ]
})

/** Underline mark. Rendered using `<u>`. */
export const Underline = Mark.define('Underline', {
  rank: 40,
  shape: { element: 'u' },
  parseRules: [textDecoration('underline')]
})

/** Strikethrough mark. Rendered as an `<s>` element. */
export const Strikethrough = Mark.define('Strikethrough', {
  rank: 42,
  shape: { element: 's' },
  parseRules: [{ selector: 'del' }, { selector: 'strike' }, textDecoration('line-through')]
})

// `text-decoration` may hold several lines, such as `underline line-through`.
function textDecoration(line: string): parse.Rule.Attribute<null> {
  return {
    attribute: 'style/text-decoration',
    readAttribute: value => (value.split(/\s+/).includes(line) ? null : parse.Reject),
    consuming: false
  }
}

/** Superscript text. Rendered using `<sup>`. */
export const Superscript = Mark.define('Superscript', {
  rank: 45,
  shape: { element: 'sup' },
  parseRules: [{ attribute: 'style/vertical-align', value: 'super' }]
})

/** Subscript text. Rendered using `<sub>`. */
export const Subscript = Mark.define('Subscript', {
  rank: 47,
  shape: { element: 'sub' },
  parseRules: [{ attribute: 'style/vertical-align', value: 'sub' }]
})

/** Code font text. Rendered as `<code>`. */
export const Code = Mark.define('Code', {
  rank: 80,
  shape: { element: 'code' }
})
