// This module provides a collection of basic schema elements. It is
// possible to define your own custom elements, but often convenient
// to use the ones provided here, which come with support extensions
// in the [wordgard/schema](#schema) module.

// This module depends on only on [wordgard/doc](#doc) and is kept
// separate from [wordgard/schema](#schema) so that you can access
// the types without loading the editor code, when appropriate.

// ### Block Structure

// Nodes and marks for structuring documents on the block level.

export {
  Paragraph,
  Heading,
  CodeBlock,
  CodeBlockLanguage,
  Blockquote,
  ListItem,
  InlineListItem,
  OrderedList,
  BulletList,
  HorizontalRule,
  Alignment,
  Direction,
  Doc,
  InlineDoc
} from './schema'

// ### Inline Structure

// Marks and nodes for inline content.

export {
  LineBreak,
  Emphasis,
  Strong,
  Underline,
  Strikethrough,
  Superscript,
  Subscript,
  Link,
  Code,
  Color,
  BackgroundColor
} from './schema'

// ### Images

// Image types and their marks.

export { Image, Figure, CaptionedFigure, ImageAlt, ImageSize } from './schema'

// ### Tables

// Nodes and marks used to define tables. See
// [wordgard/table](#table) for the supporting extensions that make
// table editing possible.

export { Cell, HeaderCell, BlockCell, BlockHeaderCell, TableRow, Table, ColSpan, RowSpan } from './schema'
