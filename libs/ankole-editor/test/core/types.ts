// Schemas used only by the generic document-engine tests.
// Schemas used only by the generic document-engine tests.
import { Elt, Plot, Node, Mark } from '../../src/core/doc'
import { Image, Figure, CaptionedFigure } from '../../src/core/types/schema'
const G = Node.Group

export const Blockquote = Plot.define('Blockquote', {
  blockContent: G.Content,
  group: G.Content,
  shape: { element: 'blockquote' },
  autoJoin: true
})

export const Cell = Plot.define('Cell', {
  inlineContent: true,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: false,
  shape: { element: 'td' }
})

export const HeaderCell = Plot.define('HeaderCell', {
  inlineContent: true,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: false,
  shape: { element: 'th' }
})

export const BlockCell = Plot.define('Cell', {
  blockContent: G.Content,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: false,
  shape: { element: 'td' }
})

export const BlockHeaderCell = Plot.define('HeaderCell', {
  blockContent: G.Content,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: false,
  shape: { element: 'th' }
})

export const TableRow = Plot.define('TableRow', {
  blockContent: G.TableCell,
  canBeEmpty: true,
  orientation: 'row',
  role: Node.Role.TableRow,
  shape: { element: 'tr' }
})

export const Table = Plot.define('Table', {
  blockContent: TableRow,
  isolating: true,
  role: Node.Role.Table,
  group: G.Content,
  shape: { structure: Elt.mk('table', [Elt.mk('tbody', [0])]) },
  parseRules: [{ selector: 'table' }]
})

export const ImageSize = Mark.Type.define<number>('ImageSize', {
  target: [Image, Figure, CaptionedFigure],
  validate: 'number',
  shape: { attribute: 'style', value: size => `width: ${size}px`, preferTarget: 'img' }
})

export const Link = Mark.Type.define<string>('Link', {
  rank: 20,
  validate: 'string',
  inclusive: false,
  shape: {
    element: 'a',
    preferTarget: 'a[href]',
    attributes: href => ({ href }),
    readElement: dom => (dom as HTMLLinkElement).href
  }
})

export const Color = Mark.Type.define<string>('Color', {
  rank: 30,
  shape: { attribute: 'style/color', value: 0 },
  spanning: true
})

export const BackgroundColor = Mark.Type.define<string>('BackgroundColor', {
  rank: 35,
  shape: { attribute: 'style/background-color', value: 0 },
  spanning: true
})

export const Doc = Plot.defineDoc({
  blockContent: G.Content
})

export const InlineDoc = Plot.defineDoc({
  inlineContent: true
})
